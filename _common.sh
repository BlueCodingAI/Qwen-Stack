# Helper, not a command -- sourced by start-qwen.sh and start-qwen-direct.sh.
#
# Everything below the Vast layer is identical whether the GPU came from the
# serverless autoscaler or from an instance you rented yourself: the same
# normalization proxy, the same LiteLLM, the same way of backgrounding and
# probing them. Only how the worker comes into existence differs, so only that
# lives in the two start scripts.
#
# Services are nohup'd with their pid in .run/<name>.pid and output in
# .run/<name>.log, so they survive an SSH disconnect and the stop scripts can
# find them.

QWEN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$QWEN_HOME/.run"; mkdir -p "$RUN"

if [[ -t 1 ]]; then C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[90m'; R=$'\033[31m'; N=$'\033[0m'
else C=; G=; Y=; D=; R=; N=; fi
info() { printf '%s%s%s\n' "$C" "$1" "$N"; }
ok()   { printf '%s%s%s\n' "$G" "$1" "$N"; }
warn() { printf '%s%s%s\n' "$Y" "$1" "$N"; }
dim()  { printf '%s%s%s\n' "$D" "$1" "$N"; }
die()  { printf '%s%s%s\n' "$R" "$1" "$N" >&2; exit 1; }

preflight() {   # preflight <bin>...
    local bin
    for bin in "$@"; do
        command -v "$bin" >/dev/null 2>&1 \
            || die "'$bin' not found on PATH. See README-ubuntu.md for the install steps."
    done
}

load_api_key() {
    local keyfile="$HOME/.config/vastai/vast_api_key"
    [[ -r "$keyfile" ]] || die "no Vast API key at $keyfile - run: vastai set api-key <key>"
    VAST_API_KEY="$(tr -d '[:space:]' < "$keyfile")"; export VAST_API_KEY
}

ensure_ssh_key() {
    # ssh refuses a key readable by group or other, which is the usual state
    # after copying one over from Windows or out of a backup.
    export VAST_SSH_KEY="${VAST_SSH_KEY:-$HOME/.ssh/runpod_key}"
    [[ -f "$VAST_SSH_KEY" ]] \
        || die "ssh key not found: $VAST_SSH_KEY (export VAST_SSH_KEY=/path/to/key to override)"
    local perms; perms="$(stat -c '%a' "$VAST_SSH_KEY")"
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        warn "     $VAST_SSH_KEY is mode $perms; ssh will refuse it - fixing to 600"
        chmod 600 "$VAST_SSH_KEY"
    fi
}

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

wait_url() {   # wait_url <url> <label> <minutes> [name] [progress-fn]
    local url="$1" label="$2" deadline=$(( $(date +%s) + $3 * 60 )) name="${4:-}" prog="${5:-}"
    local next=$(( $(date +%s) + 30 ))
    until curl -fsS -m 4 -o /dev/null "$url" 2>/dev/null; do
        if [[ -n "$name" && -s "$RUN/$name.pid" ]] && ! kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
            printf '%s--- last 20 lines of .run/%s.log ---%s\n' "$R" "$name" "$N" >&2
            tail -n 20 "$RUN/$name.log" >&2 2>/dev/null
            die "$label died on startup"
        fi
        (( $(date +%s) > deadline )) && die "$label never came up"
        if [[ -n "$prog" ]] && (( $(date +%s) >= next )); then
            "$prog"; next=$(( $(date +%s) + 30 ))
        fi
        sleep 4
    done
    ok "     $label ok"
}

# The supervisor is mode-specific: a serverless one wakes workers through the
# router, a direct one drives a single instance. Reusing the wrong one would
# quietly ignore the mode you just asked for, so the live mode is recorded and
# a mismatch forces a restart.
start_supervisor() {   # start_supervisor <mode-label> <wait-minutes> [progress-fn]
    local mode="$1" minutes="$2" prog="${3:-}" pid=""
    pid="$(running_pid supervisor tunnel_supervisor)"
    if [[ -n "$pid" ]]; then
        if [[ "$(cat "$RUN/supervisor.mode" 2>/dev/null)" == "$mode" ]]; then
            dim "     reusing supervisor pid $pid ($mode)"
        else
            warn "     supervisor pid $pid is in $(cat "$RUN/supervisor.mode" 2>/dev/null || echo unknown) mode - restarting it as $mode"
            kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
            rm -f "$RUN/supervisor.pid"
            pid=""
        fi
    fi
    if [[ -z "$pid" ]]; then
        start_bg supervisor python3 -u tunnel_supervisor.py
        echo "$mode" >"$RUN/supervisor.mode"
    fi
    wait_url "http://127.0.0.1:18000/health" "tunnel :18000" "$minutes" supervisor "$prog"
}

start_proxy() {
    if alive "http://127.0.0.1:8100/health"; then
        dim "     already listening on :8100, reusing"
        running_pid proxy 'normalize_proxy' >/dev/null
    else
        start_bg proxy python3 -m uvicorn normalize_proxy:app \
            --host 127.0.0.1 --port 8100 --log-level warning
        wait_url "http://127.0.0.1:8100/health" "proxy :8100" 2 proxy
    fi
}

start_litellm() {
    if alive "http://127.0.0.1:4000/health/liveliness"; then
        dim "     already listening on :4000, reusing"
        running_pid litellm 'litellm_config' >/dev/null
    else
        start_bg litellm litellm --config litellm_config.yaml --port 4000
        wait_url "http://127.0.0.1:4000/health/liveliness" "litellm :4000" 3 litellm
    fi
}
