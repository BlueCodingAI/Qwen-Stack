# Shuts down the local gateway. Leaves the Vast side intact ON PURPOSE.
#
# With cold_workers=0 and inactivity_timeout=900, Vast STOPS the worker ~15 min after
# the last request and keeps its disk. That means:
#   - GPU billing ($1.20/hr) stops
#   - disk billing continues (~150 GB x $0.1333/GB/mo ~= $20/mo)
#   - the next start is a restart, not a rebuild: ~24s instead of ~2-3 min
#
# That is the deliberate trade. To pay literally nothing between sessions instead,
# use stop-qwen-full.ps1, which also deletes the workergroup and destroys the disk.

$ErrorActionPreference = "Continue"

Write-Host "stopping local services ..." -ForegroundColor Cyan
$killed = 0
Get-CimInstance Win32_Process -Filter "Name like '%python%' or Name like '%litellm%' or Name like '%ssh%'" |
  Where-Object { $_.CommandLine -match 'tunnel_supervisor|normalize_proxy|litellm_config|18000:127\.0\.0\.1:18000' } |
  ForEach-Object {
      Write-Host "   killing pid $($_.ProcessId)" -ForegroundColor DarkGray
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
  }
if ($killed -eq 0) { Write-Host "   (nothing was running)" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "Local gateway down." -ForegroundColor Green
Write-Host "Vast worker will stop itself ~15 min after its last request; disk is kept" -ForegroundColor Yellow
Write-Host "(~`$20/mo standby) so the next start-qwen takes ~24s." -ForegroundColor Yellow
Write-Host ""
Write-Host "To stop paying entirely, run: .\stop-qwen-full.ps1" -ForegroundColor DarkGray
