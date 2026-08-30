# Full teardown: pay NOTHING between sessions.
# Deletes the workergroup and destroys the instance, taking the 150 GB disk with it,
# so the next start re-downloads the 51 GB model (~2-3 min instead of ~24s).

$ErrorActionPreference = "Continue"
$ENDPOINT_ID = 35555

Write-Host "1/3  stopping local services ..." -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name like '%python%' or Name like '%litellm%' or Name like '%ssh%'" |
  Where-Object { $_.CommandLine -match 'tunnel_supervisor|normalize_proxy|litellm_config|18000:127\.0\.0\.1:18000' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }

Write-Host "2/3  deleting workergroup(s) ..." -ForegroundColor Cyan
try {
    foreach ($g in (& vastai show workergroups --raw --full 2>$null | ConvertFrom-Json)) {
        if ($g.endpoint_id -eq $ENDPOINT_ID) { & vastai delete workergroup $g.id | Out-Null }
    }
} catch {}

Write-Host "3/3  destroying instances ..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
try {
    foreach ($i in (& vastai show instances --raw --full 2>$null | ConvertFrom-Json)) {
        & vastai destroy instance $i.id -y | Out-Null
    }
} catch {}

Start-Sleep -Seconds 5
$n = @((& vastai show instances --raw --full 2>$null | ConvertFrom-Json)).Count
if ($n -eq 0) { Write-Host "`nAll clear - 0 instances, nothing billing." -ForegroundColor Green }
else          { Write-Host "`nWARNING: $n instance(s) remain - check cloud.vast.ai/instances/" -ForegroundColor Red }
