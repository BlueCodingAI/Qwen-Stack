#!/usr/bin/env bash
# DIRECT mode: rent one ordinary instance yourself, run the model on it, destroy
# it when you are done. No endpoint, no workergroup, no autoscaler.
#
#   Claude Code --/v1/messages--> LiteLLM :4000
#                --/v1/chat/completions--> normalize_proxy :8100
#                --> SSH tunnel :18000 --> llama-server on YOUR instance
#
# Why you might prefer this to start-qwen.sh (serverless):
#   * one thing to reason about - an instance either exists and bills, or does
#     not exist and bills nothing. No 15-minute idle timeout deciding for you,
#     no cold_workers, no router.
#   * the instance is yours until you destroy it, so it cannot be scaled away
#     mid-session, and the weights stay in page cache between requests.
#   * ./stop-qwen-direct.sh destroys it, so credit burn goes to exactly $0.
#
# What you give up: nothing wakes the GPU for you. Destroy it and the next start
# re-rents and re-downloads (~2-3 min).
#
# The container comes from the same template hash the serverless endpoint uses,
# so the image, the llama-server flags and the :18000 port are identical - the
# only difference is who owns the machine.
#
#   ./start-qwen-direct.sh --dry-run     # show what it would rent, bill nothing
#   ./start-qwen-direct.sh               # rent it and bring the stack up
#   ./start-qwen-direct.sh --offer 1234  # rent one specific offer id
#   ./stop-qwen-direct.sh                # destroy it
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
. "$here/_common.sh"

TEMPLATE="${QWEN_TEMPLATE:-ad7f44ce435d59f8dfd2a16af201ff37}"   # Qwen3.8-27B Heretic BF16
LABEL="${QWEN_LABEL:-qwen-direct}"          # how the stop script recognises our instance
DISK="${QWEN_DISK:-160}"                    # GB; the weights are ~51 GB
# Sized from what this model actually needs, not from a GPU class. Qwen3.8-27B
# (gguf arch "qwen35") is a HYBRID attention/SSM model: full_attention_interval=4,
# so only 16 of its 64 layers keep a KV cache and the other 48 hold a small
# context-independent SSM state. With head_count_kv=4 and k/v_length=256 that is
#
#     weights BF16 + mmproj   50.7 GB
#     KV cache @ 131072 ctx    8.6 GB   (a normal 27B would want ~32 GB here)
#     SSM state + buffers      ~3.1 GB
#     -------------------------------
#     total                   ~62.4 GB
#
# so 80 GB is the real floor with headroom, not 90 - which also lets an A100 80GB
# qualify instead of only RTX PRO 6000 boards.
#
# inet_down is 1000, not 4000: the 4000 floor comes from SERVERLESS mode, where the
# autoscaler kills a worker that cannot pull 51 GB inside ~940 s. Direct mode has no
# such deadline, and 4000 was excluding the cheapest hosts outright - the machines it
# skipped are $1.035/hr against the $1.161 it was holding out for.
SEARCH="${QWEN_SEARCH:-gpu_ram>=80 num_gpus=1 inet_down>=1000 disk_space>=160 rentable=true verified=true dph_total<=1.20}"

# The template's own onstart plus a fix for the authorized_keys ownership Vast
# gets wrong, which otherwise leaves the instance unreachable over ssh and so
# unusable - see the comment at the top of that file. It REPLACES the template's
# onstart rather than adding to it, so the two have to stay in step.
ONSTART_FILE="${QWEN_ONSTART_FILE:-$here/onstart-direct.sh}"

# Escape hatch: if that template ever turns out to carry serverless-only
# plumbing, set these two and it launches a plain container instead. Whatever
# you run must listen on 18000 inside the instance.
QWEN_IMAGE="${QWEN_IMAGE:-}"
QWEN_ONSTART="${QWEN_ONSTART:-}"

export SHIM_MODEL_ID="qwen38-27b-heretic"
export VAST_MODE="direct"

DRY_RUN=0; WANT_OFFER=""
while (( $# )); do
    case "$1" in
        --dry-run|-n) DRY_RUN=1 ;;
        --offer)      WANT_OFFER="${2:-}"; shift ;;
        -h|--help)    sed -n '2,27p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

preflight vastai python3 litellm ssh curl pgrep
load_api_key
ensure_ssh_key

# --- instance bookkeeping -------------------------------------------------
# Our instance is identified by .run/instance_id, and failing that by its label,
# so a lost id file neither orphans a billing GPU nor makes us rent a second one.
ID_FILE="$RUN/instance_id"

find_ours() {   # -> "id<TAB>status<TAB>dph<TAB>gpu<TAB>ssh_host" or nothing
    local want="${1:-}"
    vastai show instances --raw --full 2>/dev/null | python3 -c '
import json, sys
want, label = sys.argv[1], sys.argv[2]
try:
    inst = json.load(sys.stdin)
except Exception:
    inst = []
def pick():
    if want:
        for i in inst:
            if str(i.get("id")) == want:
                return i
    for i in inst:
        if (i.get("label") or "") == label:
            return i
    return None
i = pick()
if i:
    print("\t".join(str(x) for x in (
        i.get("id"), i.get("actual_status") or "?", i.get("dph_total") or 0,
        i.get("gpu_name") or "?", i.get("ssh_host") or "")))
' "$want" "$LABEL" 2>/dev/null
}

other_instances() {   # instances on the account that are not ours - they bill too
    vastai show instances --raw --full 2>/dev/null | python3 -c '
import json, sys
label = sys.argv[1]
try:
    inst = json.load(sys.stdin)
except Exception:
    inst = []
out = ["{}({})".format(i.get("id"), i.get("actual_status"))
       for i in inst if (i.get("label") or "") != label]
print(" ".join(out))
' "$LABEL" 2>/dev/null
}

pick_offer() {   # -> "offer_id<TAB>dph<TAB>gpu<TAB>geo<TAB>inet_down<TAB>disk"
    vastai search offers "$SEARCH" -o dph_total --raw 2>/dev/null | python3 -c '
import json, sys
try:
    offers = json.load(sys.stdin)
except Exception:
    offers = []
if isinstance(offers, dict):
    offers = offers.get("offers", [])
if not offers:
    sys.exit(1)
o = offers[0]
print("\t".join(str(x) for x in (
    o.get("id"), o.get("dph_total"), o.get("gpu_name"), o.get("geolocation"),
    o.get("inet_down"), o.get("disk_space"))))
'
}

INSTANCE_ID=""; status=""; dph=""; gpu=""; FRESH=0
row="$(find_ours "$(cat "$ID_FILE" 2>/dev/null || true)")"
[[ -n "$row" ]] && IFS=$'\t' read -r INSTANCE_ID status dph gpu _host <<<"$row"

# 1. make sure exactly one instance of ours exists and is running
info "1/4  instance ..."
if [[ -n "$INSTANCE_ID" ]]; then
    dim "     found ours: $INSTANCE_ID  $status  $gpu  \$$dph/hr"
    if [[ "$status" == "running" ]]; then
        ok "     already running, reusing (no new charge)"
    elif (( DRY_RUN )); then
        warn "     --dry-run: would restart $INSTANCE_ID (disk kept, ~24s)"
        exit 0
    else
        warn "     restarting $INSTANCE_ID (GPU billing resumes)"
        vastai start instance "$INSTANCE_ID" >/dev/null 2>&1 \
            || die "could not start $INSTANCE_ID - check 'vastai show instances'"
    fi
else
    if [[ -n "$WANT_OFFER" ]]; then
        offer="$WANT_OFFER"
        o_id="$WANT_OFFER"; o_dph="?"; o_gpu="(--offer)"; o_geo="?"; o_inet="?"; o_disk="?"
    else
        if ! orow="$(pick_offer)"; then
            # "no offer matched" on its own leaves you guessing which constraint bit,
            # and the answer changes minute to minute as machines are taken and freed.
            # Drop one constraint at a time so the output names the one blocking. The
            # probes come from $SEARCH itself, so they cannot drift out of sync.
            without() { tr ' ' '\n' <<<"$SEARCH" | grep -v "^$1" | tr '\n' ' '; }
            count_offers() {
                vastai search offers "$1" -o dph_total --raw 2>/dev/null | python3 -c '
import json, sys
try: o = json.load(sys.stdin)
except Exception: o = []
if isinstance(o, dict): o = o.get("offers", [])
if o: print(f"{len(o)} offers   cheapest ${o[0].get(\"dph_total\"):.3f}/hr  {o[0].get(\"gpu_name\")}")
else: print("0 offers   -")
' 2>/dev/null || echo "0 offers   -"
            }
            echo >&2
            warn "no offer matched:" >&2
            dim "  $SEARCH" >&2
            echo >&2
            warn "  what the market has right now, dropping one constraint at a time:" >&2
            for c in dph_total inet_down gpu_ram; do
                printf '    %-24s %s\n' "without $c" "$(count_offers "$(without "$c")")" >&2
            done
            echo >&2
            die "  Whichever line has offers is the constraint to relax in QWEN_SEARCH.
  If they all show 0, the market is simply empty - wait and retry."
        fi
        IFS=$'\t' read -r o_id o_dph o_gpu o_geo o_inet o_disk <<<"$orow"
        offer="$o_id"
    fi
    dim "     cheapest match: offer $o_id  $o_gpu  \$$o_dph/hr  $o_geo  $o_inet Mbps down  $o_disk GB"

    others="$(other_instances)"
    [[ -n "$others" ]] && warn "     note: these instances are NOT ours and are left alone: $others"

    if (( DRY_RUN )); then
        echo
        warn "--dry-run: nothing rented, nothing billed."
        echo "Run without --dry-run to rent offer $o_id at \$$o_dph/hr with $DISK GB disk."
        exit 0
    fi

    warn "     renting offer $o_id (billing starts now, ~\$$o_dph/hr)"
    if [[ -n "$QWEN_IMAGE" ]]; then
        out="$(vastai create instance "$offer" --image "$QWEN_IMAGE" --disk "$DISK" \
                 --label "$LABEL" --ssh --direct --env '-p 18000:18000' \
                 --onstart-cmd "$QWEN_ONSTART" --cancel-unavail --raw 2>&1)"
    else
        # Refuse to rent rather than rent something unreachable: without this file
        # the instance comes up with the broken key permissions and bills while no
        # tunnel can ever reach it.
        [[ -f "$ONSTART_FILE" ]] \
            || die "missing $ONSTART_FILE - refusing to rent an instance we could not ssh into."
        out="$(vastai create instance "$offer" --template_hash "$TEMPLATE" --disk "$DISK" \
                 --label "$LABEL" --onstart "$ONSTART_FILE" --cancel-unavail --raw 2>&1)"
    fi
    INSTANCE_ID="$(python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)
if not d.get("success", True):
    sys.exit(1)
print(d.get("new_contract") or "")
' <<<"$out")" || die "create failed: $out"
    [[ -n "$INSTANCE_ID" ]] || die "create returned no instance id: $out"
    ok "     rented instance $INSTANCE_ID"
    FRESH=1
fi

echo "$INSTANCE_ID" >"$ID_FILE"
export VAST_INSTANCE_ID="$INSTANCE_ID"

# 2. supervisor, pinned to that instance. In direct mode it never calls the
#    serverless router and never creates anything, so it cannot start billing
#    behind your back - it only tunnels, and restarts the instance if stopped.
info "2/4  tunnel supervisor -> instance $INSTANCE_ID ..."
progress() {
    local r st="?"
    r="$(find_ours "$INSTANCE_ID")"
    [[ -n "$r" ]] && st="$(cut -f2 <<<"$r")"
    dim "     ... $INSTANCE_ID is $st   $(tail -n1 "$RUN/supervisor.log" 2>/dev/null | cut -c1-80)"
}
if (( FRESH )); then
    warn "     a fresh instance pulls the image and 51 GB of weights first - up to ~15 min"
    start_supervisor direct 20 progress
else
    start_supervisor direct 10 progress
fi

info "3/4  normalization proxy ..."
start_proxy

info "4/4  LiteLLM ..."
start_litellm

echo
ok "Ready. In the shell where you want Qwen:"
echo "  source ./use-qwen.sh && claude"
echo
warn "Instance $INSTANCE_ID is yours and bills until you remove it:"
echo "  ./stop-qwen-direct.sh              # destroy it - back to \$0"
echo "  ./stop-qwen-direct.sh --keep-disk  # only stop it (disk still bills, ~24s restart)"
