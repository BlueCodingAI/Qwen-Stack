# Shuts down the local gateway and STOPS (does not destroy) the Vast worker.
#
# Stopping keeps the instance's disk, so the model stays downloaded and the
# next start is a restart (~24s) rather than a rebuild (~2-3 min).
#
# Billing after this runs:
#   GPU  $1.20/hr  -> $0        (stopped immediately, not after the 15 min timeout)
#   disk ~$0.1333/GB/month      -> continues while the instance exists
#
# Persistent volumes were evaluated as a cheaper alternative and rejected: the
# $0.004/GB/mo volume offers sit on storage-only hosts, and of the 2 machines with
# both an RTX PRO 6000 and volume capacity, the cheapest volume was $0.2933/GB/mo
# -- more than instance disk, on a $1.989/hr GPU.
#
# To pay nothing at all between sessions, use stop-qwen-full.ps1 instead.

$ErrorActionPreference = "Continue"

Write-Host "1/2  stopping local services ..." -ForegroundColor Cyan
$killed = 0
Get-CimInstance Win32_Process -Filter "Name like '%python%' or Name like '%litellm%' or Name like '%ssh%'" |
  Where-Object { $_.CommandLine -match 'tunnel_supervisor|normalize_proxy|litellm_config|18000:127\.0\.0\.1:18000' } |
  # supervisor first: it restarts a proxy or LiteLLM it finds dead, so killing it
  # last would just revive the two we killed before it.
  Sort-Object @{ Expression = { if ($_.CommandLine -match 'tunnel_supervisor') { 0 } else { 1 } } } |
  ForEach-Object {
      Write-Host "     killing pid $($_.ProcessId)" -ForegroundColor DarkGray
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
  }
if ($killed -eq 0) { Write-Host "     (nothing was running)" -ForegroundColor DarkGray }

Write-Host "2/2  stopping Vast instance(s), keeping disk ..." -ForegroundColor Cyan
$any = $false
try {
    foreach ($i in (& vastai show instances --raw --full 2>$null | ConvertFrom-Json)) {
        $any = $true
        if ($i.actual_status -eq "running") {
            Write-Host "     stopping $($i.id) (disk $($i.disk_space) GB kept)" -ForegroundColor DarkGray
            & vastai stop instance $i.id | Out-Null
        } else {
            Write-Host "     $($i.id) already $($i.actual_status)" -ForegroundColor DarkGray
        }
    }
} catch {}
if (-not $any) { Write-Host "     no instances found" -ForegroundColor DarkGray }

Start-Sleep -Seconds 6
try {
    $data = & vastai show instances --raw --full 2>$null | ConvertFrom-Json
    $inst = @()
    if ($null -ne $data) { $inst = @($data) }
    Write-Host ""
    foreach ($i in $inst) {
        $mo = [math]::Round($i.disk_space * $i.storage_cost, 2)
        Write-Host "  instance $($i.id): $($i.actual_status)  disk $($i.disk_space) GB  ~`$$mo/month standby" -ForegroundColor Yellow
    }
    if ($inst.Count -eq 0) { Write-Host "  no instances - nothing billing at all" -ForegroundColor Green }
    else { Write-Host "`n  GPU billing stopped. Run .\start-qwen.ps1 to resume (~24s)." -ForegroundColor Green }
} catch {}
