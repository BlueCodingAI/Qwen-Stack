# DIRECT mode: rent one ordinary instance yourself, run the model on it, destroy
# it when you are done. No endpoint, no workergroup, no autoscaler.
# (Windows twin of start-qwen-direct.sh)
#
#   Claude Code --/v1/messages--> LiteLLM :4000
#                --/v1/chat/completions--> normalize_proxy :8100
#                --> SSH tunnel :18000 --> llama-server on YOUR instance
#
# Why you might prefer this to start-qwen.ps1 (serverless):
#   * one thing to reason about - an instance either exists and bills, or does
#     not exist and bills nothing. No 15-minute idle timeout deciding for you,
#     no cold_workers, no router.
#   * the instance is yours until you destroy it, so it cannot be scaled away
#     mid-session, and the weights stay in page cache between requests.
#   * .\stop-qwen-direct.ps1 destroys it, so credit burn goes to exactly $0.
#
# What you give up: nothing wakes the GPU for you. Destroy it and the next start
# re-rents and re-downloads (~2-3 min).
#
# The container comes from the same template hash the serverless endpoint uses,
# so the image, the llama-server flags and the :18000 port are identical - the
# only difference is who owns the machine.
#
#   .\start-qwen-direct.ps1 -DryRun      # show what it would rent, bill nothing
#   .\start-qwen-direct.ps1              # rent it and bring the stack up
#   .\start-qwen-direct.ps1 -Offer 1234  # rent one specific offer id
#   .\stop-qwen-direct.ps1               # destroy it
param(
    [switch]$DryRun,
    [int]$Offer = 0
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$TEMPLATE = "ad7f44ce435d59f8dfd2a16af201ff37"   # Qwen3.8-27B Heretic BF16
$LABEL    = "qwen-direct"                        # how the stop script recognises our instance
$DISK     = 160                                  # GB; the weights are ~51 GB
$SEARCH   = "gpu_ram>=90 num_gpus=1 inet_down>=4000 disk_space>=160 rentable=true verified=true dph_total<=1.20"

$RUN = Join-Path $here ".run"
if (-not (Test-Path $RUN)) { New-Item -ItemType Directory $RUN | Out-Null }
$ID_FILE   = Join-Path $RUN "instance_id"
$MODE_FILE = Join-Path $RUN "supervisor.mode"

$env:VAST_API_KEY  = (Get-Content "$HOME\.config\vastai\vast_api_key" -Raw).Trim()
$env:SHIM_MODEL_ID = "qwen38-27b-heretic"
$env:VAST_SSH_KEY  = "$HOME\.ssh\runpod_key"
$env:VAST_MODE     = "direct"

# Windows PowerShell 5.1 quirk: ConvertFrom-Json emits a JSON array as ONE
# pipeline object, so @(cmd | ConvertFrom-Json) is a 1-element array holding the
# whole array - and a Where-Object placed after it filters nothing. Assigning
# first and then wrapping gives a flat array for empty, single and many.
function Get-Instances {
    try {
        $data = & vastai show instances --raw --full 2>$null | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    } catch { return @() }
}

# Our instance is the one in .run\instance_id, and failing that the one carrying
# our label, so a lost id file neither orphans a billing GPU nor makes us rent a
# second one.
function Get-Ours {
    $want = $null
    if (Test-Path $ID_FILE) { $want = (Get-Content $ID_FILE -Raw).Trim() }
    $all = @(Get-Instances)
    if ($want) {
        $hit = $all | Where-Object { "$($_.id)" -eq $want } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return ($all | Where-Object { $_.label -eq $LABEL } | Select-Object -First 1)
}

function Wait-Url($url, $label, $minutes, $progress) {
    $deadline = (Get-Date).AddMinutes($minutes)
    $next     = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Seconds 4
        $ok = $false
        try { $ok = (Invoke-WebRequest $url -TimeoutSec 4 -UseBasicParsing).StatusCode -eq 200 } catch {}
        if ((-not $ok) -and $progress -and (Get-Date) -gt $next) {
            & $progress
            $next = (Get-Date).AddSeconds(30)
        }
    } until ($ok -or (Get-Date) -gt $deadline)
    if (-not $ok) { Write-Error "$label never came up"; exit 1 }
    Write-Host "     $label ok" -ForegroundColor Green
}

# 1. make sure exactly one instance of ours exists and is running
Write-Host "1/4  instance ..." -ForegroundColor Cyan
$fresh = $false
$ours  = Get-Ours

if ($ours) {
    Write-Host "     found ours: $($ours.id)  $($ours.actual_status)  $($ours.gpu_name)  `$$($ours.dph_total)/hr" -ForegroundColor DarkGray
    if ($ours.actual_status -eq "running") {
        Write-Host "     already running, reusing (no new charge)" -ForegroundColor Green
    } elseif ($DryRun) {
        Write-Host "     -DryRun: would restart $($ours.id) (disk kept, ~24s)" -ForegroundColor Yellow
        exit 0
    } else {
        Write-Host "     restarting $($ours.id) (GPU billing resumes)" -ForegroundColor Yellow
        & vastai start instance $ours.id | Out-Null
    }
    $INSTANCE_ID = $ours.id
} else {
    if ($Offer -gt 0) {
        $offerId = $Offer; $offerDph = "?"; $offerGpu = "(-Offer)"; $offerGeo = "?"
    } else {
        $offers = @()
        try {
            $data = & vastai search offers $SEARCH -o dph_total --raw 2>$null | ConvertFrom-Json
            if ($null -ne $data) { $offers = @($data) }
        } catch {}
        if ($offers.Count -eq 0) {
            Write-Error "no offer matched: $SEARCH`nLoosen `$SEARCH (raise dph_total, drop inet_down) and try again."
            exit 1
        }
        $offerId  = $offers[0].id;          $offerDph = $offers[0].dph_total
        $offerGpu = $offers[0].gpu_name;    $offerGeo = $offers[0].geolocation
    }
    Write-Host "     cheapest match: offer $offerId  $offerGpu  `$$offerDph/hr  $offerGeo" -ForegroundColor DarkGray

    $others = @(@(Get-Instances) | Where-Object { $_.label -ne $LABEL })
    if ($others.Count -gt 0) {
        $list = ($others | ForEach-Object { "$($_.id)($($_.actual_status))" }) -join " "
        Write-Host "     note: these instances are NOT ours and are left alone: $list" -ForegroundColor Yellow
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "-DryRun: nothing rented, nothing billed." -ForegroundColor Yellow
        Write-Host "Run without -DryRun to rent offer $offerId at `$$offerDph/hr with $DISK GB disk."
        exit 0
    }

    Write-Host "     renting offer $offerId (billing starts now, ~`$$offerDph/hr)" -ForegroundColor Yellow
    $raw = & vastai create instance $offerId --template_hash $TEMPLATE --disk $DISK `
                --label $LABEL --cancel-unavail --raw 2>&1 | Out-String
    $res = $null
    try { $res = $raw | ConvertFrom-Json } catch {}
    if (-not $res -or -not $res.new_contract) {
        Write-Error "create failed: $raw"; exit 1
    }
    $INSTANCE_ID = $res.new_contract
    Write-Host "     rented instance $INSTANCE_ID" -ForegroundColor Green
    $fresh = $true
}

Set-Content -Path $ID_FILE -Value "$INSTANCE_ID" -Encoding ascii
$env:VAST_INSTANCE_ID = "$INSTANCE_ID"

# 2. supervisor, pinned to that instance. In direct mode it never calls the
#    serverless router and never creates anything, so it cannot start billing
#    behind your back - it only tunnels, and restarts the instance if stopped.
#
#    A supervisor left over from serverless mode would ignore the pin, so any
#    existing one that is not already ours is replaced.
Write-Host "2/4  tunnel supervisor -> instance $INSTANCE_ID ..." -ForegroundColor Cyan
$existingMode = ""
if (Test-Path $MODE_FILE) { $existingMode = (Get-Content $MODE_FILE -Raw).Trim() }
$sup = @(Get-CimInstance Win32_Process -Filter "Name like '%python%'" |
         Where-Object { $_.CommandLine -match 'tunnel_supervisor' })
if ($sup.Count -gt 0 -and $existingMode -ne "direct:$INSTANCE_ID") {
    Write-Host "     replacing supervisor from a previous mode ($existingMode)" -ForegroundColor Yellow
    $sup | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
    Start-Sleep -Seconds 2
    $sup = @()
}
if ($sup.Count -eq 0) {
    Start-Process -WindowStyle Minimized python -ArgumentList "-u","tunnel_supervisor.py" -WorkingDirectory $here
    Set-Content -Path $MODE_FILE -Value "direct:$INSTANCE_ID" -Encoding ascii
} else {
    Write-Host "     reusing supervisor pid $($sup[0].ProcessId)" -ForegroundColor DarkGray
}

$progress = {
    $o = Get-Ours
    $st = "?"
    if ($o) { $st = $o.actual_status }
    Write-Host "     ... $INSTANCE_ID is $st" -ForegroundColor DarkGray
}
if ($fresh) {
    Write-Host "     a fresh instance pulls the image and 51 GB of weights first - up to ~15 min" -ForegroundColor Yellow
    Wait-Url "http://127.0.0.1:18000/health" "tunnel :18000" 20 $progress
} else {
    Wait-Url "http://127.0.0.1:18000/health" "tunnel :18000" 10 $progress
}

Write-Host "3/4  normalization proxy ..." -ForegroundColor Cyan
Start-Process -WindowStyle Minimized python `
  -ArgumentList "-m","uvicorn","normalize_proxy:app","--host","127.0.0.1","--port","8100","--log-level","warning" `
  -WorkingDirectory $here
Wait-Url "http://127.0.0.1:8100/health" "proxy :8100" 2 $null

Write-Host "4/4  LiteLLM ..." -ForegroundColor Cyan
Start-Process -WindowStyle Minimized litellm `
  -ArgumentList "--config","litellm_config.yaml","--port","4000" -WorkingDirectory $here
Wait-Url "http://127.0.0.1:4000/health/liveliness" "litellm :4000" 3 $null

Write-Host ""
Write-Host "Ready. In the terminal where you want Qwen:" -ForegroundColor Green
Write-Host "  . .\use-qwen.ps1 ; claude"
Write-Host ""
Write-Host "Instance $INSTANCE_ID is yours and bills until you remove it:" -ForegroundColor Yellow
Write-Host "  .\stop-qwen-direct.ps1             # destroy it - back to `$0"
Write-Host "  .\stop-qwen-direct.ps1 -KeepDisk   # only stop it (disk still bills, ~24s restart)"
