#!/usr/bin/env bash
# SERVERLESS mode: the endpoint's autoscaler owns the GPU. (Twin of start-qwen.ps1)
# For a plain rented instance you create and destroy yourself, see start-qwen-direct.sh.
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
#
# NOTE: this mode still serves the OLD model. `create workergroup` takes only a
# template hash, with no --onstart override, so the worker runs the onstart baked
# into template ad7f44ce... - which downloads 0bserverx/Qwen3.8-27B-Heretic-
# Abliterated-Uncensored-GGUF. The swap to huihui-ai/Huihui-Qwen3.8-27B-abliterated-
# GGUF lives in onstart-direct.sh and therefore reaches DIRECT mode only. To move
# serverless too, edit the template's onstart in the Vast console (or point
# $TEMPLATE at a new template) - it cannot be done from this repo.
#
# Re-running this script is safe: anything already healthy is reused, not
# duplicated (a second uvicorn would just fail to bind :8100 anyway).
#
#   ./start-qwen.sh          # bring everything up
#   tail -f .run/*.log       # watch it
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
. "$here/_common.sh"

TEMPLATE="ad7f44ce435d59f8dfd2a16af201ff37"   # Qwen3.8-27B Heretic BF16 serverless
ENDPOINT_NAME="qwen38-bf16"
ENDPOINT_ID=35555
SEARCH="gpu_ram>=90 num_gpus=1 inet_down>=4000 disk_space>=160 rentable=true verified=true dph_total<=1.20"

export VAST_ENDPOINT="$ENDPOINT_NAME"
export SHIM_MODEL_ID="qwen38-27b-heretic"
export VAST_MODE="serverless"
unset VAST_INSTANCE_ID

preflight vastai python3 litellm ssh curl pgrep
load_api_key
ensure_ssh_key

# 1. workergroup - only create one if the endpoint has none
info "1/4  ensuring a workergroup exists ..."
existing="$(vastai show workergroups --raw --full 2>/dev/null | python3 -c '
import json, sys
try:
    groups = json.load(sys.stdin)
except Exception:
    groups = []
print("\n".join(str(g["id"]) for g in groups if g.get("endpoint_id") == int(sys.argv[1])))
' "$ENDPOINT_ID" 2>/dev/null)"

if [[ -n "$existing" ]]; then
    dim "     reusing workergroup $(head -n1 <<<"$existing")"
else
    warn "     creating workergroup (rents a GPU, starts billing)"
    vastai create workergroup --endpoint_name "$ENDPOINT_NAME" --template_hash "$TEMPLATE" \
        --test_workers 1 --gpu_ram 90 --cold_workers 0 --search_params "$SEARCH" >/dev/null \
        || die "workergroup create failed - check 'vastai show workergroups'"
fi

# 2. supervisor - waits for the worker, then tunnels to it.
#    First start after a teardown re-downloads 51 GB, so allow ~10 min.
#    Health here is the supervisor process, not :18000: the tunnel is
#    legitimately down while a cold worker is still booting.
info "2/4  tunnel supervisor (first start re-downloads 51 GB, ~2-3 min) ..."
start_supervisor serverless 10

info "3/4  normalization proxy ..."
start_proxy

info "4/4  LiteLLM ..."
start_litellm

echo
ok "Ready. In the shell where you want Qwen:"
echo "  source ./use-qwen.sh && claude"
echo
warn "Billing ~\$1.20/hr while up. Run ./stop-qwen.sh when done."
