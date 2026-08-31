# Removes the instance that start-qwen-direct.ps1 rented, so credit burn stops
# completely. This is the point of direct mode: no endpoint left behind, no
# workergroup, no standby disk. (Windows twin of stop-qwen-direct.sh)
#
#   .\stop-qwen-direct.ps1             # destroy the instance  -> $0.00/hr, $0/mo
#   .\stop-qwen-direct.ps1 -KeepDisk   # only stop it          -> $0.00/hr, ~$21/mo
#   .\stop-qwen-direct.ps1 -DryRun     # say what it would do, touch nothing
#
# -KeepDisk keeps the 51 GB of weights on the instance's disk, so the next start
# is a ~24s restart instead of a ~2-3 min re-download. It is the same trade-off
# stop-qwen.ps1 makes; the default here is the opposite, because an instance you
# rented yourself is yours to pay for until it is gone.
#
# It only ever touches OUR instance - the one in .run\instance_id, or one
# labelled qwen-direct. Anything else on the account is reported and left alone.
# (stop-qwen-full.ps1, by contrast, destroys every instance on the account.)
param(
    [switch]$KeepDisk,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$LABEL     = "qwen-direct"
$RUN       = Join-Path $here ".run"
$ID_FILE   = Join-Path $RUN "instance_id"
$MODE_FILE = Join-Path $RUN "supervisor.mode"

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

Write-Host "1/2  stopping local services ..." -ForegroundColor Cyan
$procs = @(Get-CimInstance Win32_Process -Filter "Name like '%python%' or Name like '%litellm%' or Name like '%ssh%'" |
           Where-Object { $_.CommandLine -match 'tunnel_supervisor|normalize_proxy|litellm_config|18000:127\.0\.0\.1:18000' })
if ($DryRun) {
    if ($procs.Count -eq 0) { Write-Host "     -DryRun: nothing is running" -ForegroundColor DarkGray }
    else { $procs | ForEach-Object { Write-Host "     -DryRun: would kill pid $($_.ProcessId)" -ForegroundColor DarkGray } }
} elseif ($procs.Count -eq 0) {
    Write-Host "     (nothing was running)" -ForegroundColor DarkGray
} else {
    $procs | ForEach-Object {
        Write-Host "     killing pid $($_.ProcessId)" -ForegroundColor DarkGray
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
    }
    Remove-Item $MODE_FILE -ErrorAction SilentlyContinue
}

Write-Host "2/2  removing the instance ..." -ForegroundColor Cyan
$ours = Get-Ours

if (-not $ours) {
    Write-Host "     no instance of ours found (no .run\instance_id, none labelled $LABEL)" -ForegroundColor DarkGray
    $rest = @(Get-Instances)
    if ($rest.Count -gt 0) {
        $list = ($rest | ForEach-Object { "$($_.id)($($_.actual_status))" }) -join " "
        Write-Host "     other instances exist and keep billing: $list" -ForegroundColor Yellow
        Write-Host "     they are not ours; remove them with: vastai destroy instance <id> -y" -ForegroundColor DarkGray
    } else {
        Write-Host "  nothing billing at all." -ForegroundColor Green
    }
    Remove-Item $ID_FILE -ErrorAction SilentlyContinue
    exit 0
}

$mo = [math]::Round(($ours.disk_space * $ours.storage_cost), 2)

if ($KeepDisk) {
    Write-Host "     instance $($ours.id) ($($ours.actual_status), `$$($ours.dph_total)/hr) -> stop, keeping $($ours.disk_space) GB of weights" -ForegroundColor DarkGray
    if ($DryRun) {
        Write-Host "     -DryRun: would run: vastai stop instance $($ours.id)" -ForegroundColor Yellow
        exit 0
    }
    & vastai stop instance $ours.id | Out-Null
    Start-Sleep -Seconds 4
    Write-Host ""
    Write-Host "  GPU billing stopped. Disk stays at ~`$$mo/month; .\start-qwen-direct.ps1 resumes in ~24s." -ForegroundColor Yellow
    exit 0
}

Write-Host "     instance $($ours.id) ($($ours.actual_status), `$$($ours.dph_total)/hr) -> DESTROY, losing $($ours.disk_space) GB of weights" -ForegroundColor DarkGray
if ($DryRun) {
    Write-Host "     -DryRun: would run: vastai destroy instance $($ours.id) -y" -ForegroundColor Yellow
    exit 0
}

$destroyed = $ours.id
& vastai destroy instance $destroyed -y | Out-Null
Start-Sleep -Seconds 5

# confirm it is really gone before claiming $0
$still = @(@(Get-Instances) | Where-Object { "$($_.id)" -eq "$destroyed" })
if ($still.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: instance $destroyed still shows up - check cloud.vast.ai/instances/" -ForegroundColor Red
    exit 1
}
Remove-Item $ID_FILE -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "  Instance $destroyed destroyed - `$0.00/hr, no standby disk." -ForegroundColor Green
$rest = @(Get-Instances)
if ($rest.Count -gt 0) {
    $list = ($rest | ForEach-Object { "$($_.id)($($_.actual_status))" }) -join " "
    Write-Host "  note: other instances still billing: $list" -ForegroundColor Yellow
}
Write-Host "  Next .\start-qwen-direct.ps1 rents fresh and re-downloads (~2-3 min)." -ForegroundColor DarkGray
