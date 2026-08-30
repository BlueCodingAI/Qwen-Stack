# Brings the whole stack up from a fully torn-down state.
#
#   Claude Code --/v1/messages--> LiteLLM :4000
#                --/v1/chat/completions--> normalize_proxy :8100
#                --> SSH tunnel :18000 --> llama-server on a Vast worker
#
# Each hop exists for a measured reason:
#   workergroup - recreated here because stop-qwen deletes it; without one the
#                 autoscaler cannot create a worker (and so cannot bill you).
#   tunnel      - Vast's routing SDK does a lookup per request against an API
#                 limited to 1 req/sec; under Claude Code's rate it 429s and backs
#                 off (random 1-18s/call). Tunnel is a steady ~1.1-2.6s.
#   proxy       - the model's Jinja template raise_exception()s (opaque HTTP 500)
#                 on late/multiple system messages and on reasoning_effort=high.
#   supervisor  - rebuilds the tunnel if the worker restarts.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$TEMPLATE      = "ad7f44ce435d59f8dfd2a16af201ff37"   # Qwen3.8-27B Heretic BF16 serverless
$ENDPOINT_NAME = "qwen38-bf16"
$ENDPOINT_ID   = 35555
$SEARCH        = "gpu_ram>=90 num_gpus=1 inet_down>=4000 disk_space>=160 rentable=true verified=true dph_total<=1.20"

$env:VAST_API_KEY  = (Get-Content "$HOME\.config\vastai\vast_api_key" -Raw).Trim()
$env:VAST_ENDPOINT = $ENDPOINT_NAME
$env:SHIM_MODEL_ID = "qwen38-27b-heretic"
$env:VAST_SSH_KEY  = "$HOME\.ssh\runpod_key"

function Wait-Url($url, $label, $minutes) {
    $deadline = (Get-Date).AddMinutes($minutes)
    do {
        Start-Sleep -Seconds 4
        $ok = $false
        try { $ok = (Invoke-WebRequest $url -TimeoutSec 4 -UseBasicParsing).StatusCode -eq 200 } catch {}
    } until ($ok -or (Get-Date) -gt $deadline)
    if (-not $ok) { Write-Error "$label never came up"; exit 1 }
    Write-Host "     $label ok" -ForegroundColor Green
}

# 1. workergroup - only create one if the endpoint has none
Write-Host "1/4  ensuring a workergroup exists ..." -ForegroundColor Cyan
$existing = @()
try { $existing = @((& vastai show workergroups --raw --full 2>$null | ConvertFrom-Json) |
                    Where-Object { $_.endpoint_id -eq $ENDPOINT_ID }) } catch {}
if ($existing.Count -gt 0) {
    Write-Host "     reusing workergroup $($existing[0].id)" -ForegroundColor DarkGray
} else {
    Write-Host "     creating workergroup (rents a GPU, starts billing)" -ForegroundColor Yellow
    & vastai create workergroup --endpoint_name $ENDPOINT_NAME --template_hash $TEMPLATE `
        --test_workers 1 --gpu_ram 90 --cold_workers 0 --search_params $SEARCH | Out-Null
}

# 2. supervisor - waits for the worker, then tunnels to it.
#    First start after a teardown re-downloads 51 GB, so allow ~8 min.
Write-Host "2/4  tunnel supervisor (first start re-downloads 51 GB, ~2-3 min) ..." -ForegroundColor Cyan
Start-Process -WindowStyle Minimized python -ArgumentList "-u","tunnel_supervisor.py" -WorkingDirectory $here
Wait-Url "http://127.0.0.1:18000/health" "tunnel :18000" 10

Write-Host "3/4  normalization proxy ..." -ForegroundColor Cyan
Start-Process -WindowStyle Minimized python `
  -ArgumentList "-m","uvicorn","normalize_proxy:app","--host","127.0.0.1","--port","8100","--log-level","warning" `
  -WorkingDirectory $here
Wait-Url "http://127.0.0.1:8100/health" "proxy :8100" 2

Write-Host "4/4  LiteLLM ..." -ForegroundColor Cyan
Start-Process -WindowStyle Minimized litellm `
  -ArgumentList "--config","litellm_config.yaml","--port","4000" -WorkingDirectory $here
Wait-Url "http://127.0.0.1:4000/health/liveliness" "litellm :4000" 3

Write-Host ""
Write-Host "Ready. In the terminal where you want Qwen:" -ForegroundColor Green
Write-Host "  . .\use-qwen.ps1 ; claude"
Write-Host ""
Write-Host "Billing ~`$1.20/hr while up. Run .\stop-qwen.ps1 when done." -ForegroundColor Yellow
