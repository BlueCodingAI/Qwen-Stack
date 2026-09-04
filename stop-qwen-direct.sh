#!/usr/bin/env bash
# Removes the instance that start-qwen-direct.sh rented, so credit burn stops
# completely. This is the point of direct mode: no endpoint left behind, no
# workergroup, no standby disk.
#
#   ./stop-qwen-direct.sh              # destroy the instance   -> $0.00/hr, $0/mo
#   ./stop-qwen-direct.sh --keep-disk  # only stop it           -> $0.00/hr, ~$21/mo
#   ./stop-qwen-direct.sh --dry-run    # say what it would do, touch nothing
#
# --keep-disk keeps the 56 GB of weights on the instance's disk, so the next
# start is a ~24s restart instead of a ~2-3 min re-download. It is the same
# trade-off stop-qwen.sh makes; the default here is the opposite, because an
# instance you rented yourself is yours to pay for until it is gone.
#
# It only ever touches OUR instance - the one in .run/instance_id, or one
# labelled qwen-direct. Anything else on the account is reported and left alone.
# (stop-qwen-full.sh, by contrast, destroys every instance on the account.)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
RUN="$here/.run"; mkdir -p "$RUN"
. "$here/_stop_local.sh"

LABEL="${QWEN_LABEL:-qwen-direct}"
ID_FILE="$RUN/instance_id"

if [[ -t 1 ]]; then C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[90m'; R=$'\033[31m'; N=$'\033[0m'
else C=; G=; Y=; D=; R=; N=; fi

KEEP_DISK=0; DRY_RUN=0
while (( $# )); do
    case "$1" in
        --keep-disk|-k) KEEP_DISK=1 ;;
        --dry-run|-n)   DRY_RUN=1 ;;
        -h|--help)      sed -n '2,16p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
        *) printf '%sunknown option: %s (try --help)%s\n' "$R" "$1" "$N" >&2; exit 1 ;;
    esac
    shift
done

find_ours() {   # -> "id<TAB>status<TAB>dph<TAB>disk<TAB>storage_cost" or nothing
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
        i.get("disk_space") or 0, i.get("storage_cost") or 0)))
' "$want" "$LABEL" 2>/dev/null
}

others() {
    vastai show instances --raw --full 2>/dev/null | python3 -c '
import json, sys
ours, label = sys.argv[1], sys.argv[2]
try:
    inst = json.load(sys.stdin)
except Exception:
    inst = []
out = ["{}({})".format(i.get("id"), i.get("actual_status")) for i in inst
       if str(i.get("id")) != ours and (i.get("label") or "") != label]
print(" ".join(out))
' "$1" "$LABEL" 2>/dev/null
}

printf '%s1/2  stopping local services ...%s\n' "$C" "$N"
if (( DRY_RUN )); then
    printf '%s     --dry-run: would kill %s%s\n' "$D" "$(ls "$RUN"/*.pid 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')" "$N"
else
    stop_local "$RUN"
fi

printf '%s2/2  removing the instance ...%s\n' "$C" "$N"
if ! command -v vastai >/dev/null 2>&1; then
    printf '%s     vastai CLI not found - local services are down, but the GPU is still billing%s\n' "$Y" "$N"
    exit 1
fi

want="$(cat "$ID_FILE" 2>/dev/null || true)"
row="$(find_ours "$want")"

if [[ -z "$row" ]]; then
    printf '%s     no instance of ours found (no .run/instance_id, none labelled %s)%s\n' "$D" "$LABEL" "$N"
    rest="$(others "$want")"
    if [[ -n "$rest" ]]; then
        printf '%s     other instances exist and keep billing: %s%s\n' "$Y" "$rest" "$N"
        printf '%s     they are not ours; remove them with: vastai destroy instance <id> -y%s\n' "$D" "$N"
    else
        printf '%s  nothing billing at all.%s\n' "$G" "$N"
    fi
    rm -f "$ID_FILE"
    exit 0
fi

IFS=$'\t' read -r id status dph disk cost <<<"$row"
mo="$(awk -v d="$disk" -v c="$cost" 'BEGIN{printf "%.2f", d*c}')"

if (( KEEP_DISK )); then
    printf '%s     instance %s (%s, $%s/hr) -> stop, keeping %s GB of weights%s\n' "$D" "$id" "$status" "$dph" "$disk" "$N"
    if (( DRY_RUN )); then
        printf '%s     --dry-run: would run: vastai stop instance %s%s\n' "$Y" "$id" "$N"
        exit 0
    fi
    vastai stop instance "$id" >/dev/null 2>&1
    sleep 4
    printf '\n%s  GPU billing stopped. Disk stays at ~$%s/month; ./start-qwen-direct.sh resumes in ~24s.%s\n' "$Y" "$mo" "$N"
    exit 0
fi

printf '%s     instance %s (%s, $%s/hr) -> DESTROY, losing %s GB of weights%s\n' "$D" "$id" "$status" "$dph" "$disk" "$N"
if (( DRY_RUN )); then
    printf '%s     --dry-run: would run: vastai destroy instance %s -y%s\n' "$Y" "$id" "$N"
    exit 0
fi

vastai destroy instance "$id" -y >/dev/null 2>&1
sleep 5

# confirm it is really gone before claiming $0
if [[ -n "$(find_ours "$id")" ]]; then
    printf '\n%sWARNING: instance %s still shows up - check cloud.vast.ai/instances/%s\n' "$R" "$id" "$N"
    exit 1
fi
rm -f "$ID_FILE"
printf '\n%s  Instance %s destroyed - $0.00/hr, no standby disk.%s\n' "$G" "$id" "$N"
rest="$(others "$id")"
[[ -n "$rest" ]] && printf '%s  note: other instances still billing: %s%s\n' "$Y" "$rest" "$N"
printf '%s  Next ./start-qwen-direct.sh rents fresh and re-downloads (~2-3 min).%s\n' "$D" "$N"
