#!/usr/bin/env bash
# Brings the whole stack up from a fully torn-down state. (Ubuntu/Linux twin of start-qwen.ps1)
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
# Unlike the Windows version there are no minimized windows: each service is a
# nohup'd background process with its pid in .run/<name>.pid and its output in
# .run/<name>.log, so it survives an SSH disconnect and stop-qwen.sh can find it.
# Re-running this script is safe -- anything already healthy is reused, not
# duplicated (a second uvicorn would just fail to bind :8100 anyway).
#
#   ./start-qwen.sh          # bring everything up
#   tail -f .run/*.log       # watch it
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

TEMPLATE="ad7f44ce435d59f8dfd2a16af201ff37"   # Qwen3.8-27B Heretic BF16 serverless
ENDPOINT_NAME="qwen38-bf16"
ENDPOINT_ID=35555
SEARCH="gpu_ram>=90 num_gpus=1 inet_down>=4000 disk_space>=160 rentable=true verified=true dph_total<=1.20"

export VAST_ENDPOINT="$ENDPOINT_NAME"
export SHIM_MODEL_ID="qwen38-27b-heretic"
export VAST_SSH_KEY="${VAST_SSH_KEY:-$HOME/.ssh/runpod_key}"

RUN="$here/.run"; mkdir -p "$RUN"

if [[ -t 1 ]]; then C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[90m'; R=$'\033[31m'; N=$'\033[0m'
else C=; G=; Y=; D=; R=; N=; fi
info() { printf '%s%s%s\n' "$C" "$1" "$N"; }
ok()   { printf '%s%s%s\n' "$G" "$1" "$N"; }
warn() { printf '%s%s%s\n' "$Y" "$1" "$N"; }
dim()  { printf '%s%s%s\n' "$D" "$1" "$N"; }
die()  { printf '%s%s%s\n' "$R" "$1" "$N" >&2; exit 1; }

# --- preflight ------------------------------------------------------------
for bin in vastai python3 litellm ssh curl pgrep; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH. See README-ubuntu.md for the install steps."
done

KEYFILE="$HOME/.config/vastai/vast_api_key"
[[ -r "$KEYFILE" ]] || die "no Vast API key at $KEYFILE - run: vastai set api-key <key>"
VAST_API_KEY="$(tr -d '[:space:]' < "$KEYFILE")"; export VAST_API_KEY

# ssh refuses a key readable by group or other, which is the usual state after
# copying one over from Windows or out of a backup.
[[ -f "$VAST_SSH_KEY" ]] || die "ssh key not found: $VAST_SSH_KEY (export VAST_SSH_KEY=/path/to/key to override)"
perms="$(stat -c '%a' "$VAST_SSH_KEY")"
if [[ "$perms" != "600" && "$perms" != "400" ]]; then
    warn "     $VAST_SSH_KEY is mode $perms; ssh will refuse it - fixing to 600"
    chmod 600 "$VAST_SSH_KEY"
fi

# --- helpers --------------------------------------------------------------
alive() { curl -fsS -m 3 -o /dev/null "$1" 2>/dev/null; }

running_pid() {   # running_pid <name> <cmdline-pattern> -> echoes a live pid, if any
    local name="$1" pat="$2" pid=""
    if [[ -s "$RUN/$name.pid" ]]; then
        pid="$(cat "$RUN/$name.pid")"
        kill -0 "$pid" 2>/dev/null || pid=""
    fi
    [[ -z "$pid" ]] && pid="$(pgrep -f -- "$pat" 2>/dev/null | head -n1)"
    [[ -n "$pid" ]] && { echo "$pid" >"$RUN/$name.pid"; echo "$pid"; }
}

start_bg() {   # start_bg <name> <cmd...>
    local name="$1"; shift
    nohup "$@" >>"$RUN/$name.log" 2>&1 &
    echo $! >"$RUN/$name.pid"
    disown 2>/dev/null || true
    dim "     $name pid $(cat "$RUN/$name.pid")  log: .run/$name.log"
}

wait_url() {   # wait_url <url> <label> <minutes> [name]
    local url="$1" label="$2" deadline=$(( $(date +%s) + $3 * 60 )) name="${4:-}"
    until curl -fsS -m 4 -o /dev/null "$url" 2>/dev/null; do
        if [[ -n "$name" && -s "$RUN/$name.pid" ]] && ! kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
            printf '%s--- last 20 lines of .run/%s.log ---%s\n' "$R" "$name" "$N" >&2
            tail -n 20 "$RUN/$name.log" >&2 2>/dev/null
            die "$label died on startup"
        fi
        (( $(date +%s) > deadline )) && die "$label never came up"
        sleep 4
    done
    ok "     $label ok"
}

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
#    First start after a teardown re-downloads 51 GB, so allow ~8 min.
#    Health here is the supervisor process, not :18000: it is legitimately down
#    while a cold worker is still booting.
info "2/4  tunnel supervisor (first start re-downloads 51 GB, ~2-3 min) ..."
if pid="$(running_pid supervisor tunnel_supervisor)"; [[ -n "${pid:-}" ]]; then
    dim "     reusing supervisor pid $pid"
else
    start_bg supervisor python3 -u tunnel_supervisor.py
fi
wait_url "http://127.0.0.1:18000/health" "tunnel :18000" 10 supervisor

info "3/4  normalization proxy ..."
if alive "http://127.0.0.1:8100/health"; then
    dim "     already listening on :8100, reusing"
    running_pid proxy 'normalize_proxy' >/dev/null
else
    start_bg proxy python3 -m uvicorn normalize_proxy:app \
        --host 127.0.0.1 --port 8100 --log-level warning
    wait_url "http://127.0.0.1:8100/health" "proxy :8100" 2 proxy
fi

info "4/4  LiteLLM ..."
if alive "http://127.0.0.1:4000/health/liveliness"; then
    dim "     already listening on :4000, reusing"
    running_pid litellm 'litellm_config' >/dev/null
else
    start_bg litellm litellm --config litellm_config.yaml --port 4000
    wait_url "http://127.0.0.1:4000/health/liveliness" "litellm :4000" 3 litellm
fi

echo
ok "Ready. In the shell where you want Qwen:"
echo "  source ./use-qwen.sh && claude"
echo
warn "Billing ~\$1.20/hr while up. Run ./stop-qwen.sh when done."
