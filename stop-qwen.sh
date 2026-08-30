#!/usr/bin/env bash
# Shuts down the local gateway and STOPS (does not destroy) the Vast worker.
# (Ubuntu/Linux twin of stop-qwen.ps1)
#
# Stopping keeps the instance's disk, so the 51 GB model stays downloaded and the
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
# To pay nothing at all between sessions, use stop-qwen-full.sh instead.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
RUN="$here/.run"; mkdir -p "$RUN"
. "$here/_stop_local.sh"

if [[ -t 1 ]]; then C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[90m'; N=$'\033[0m'
else C=; G=; Y=; D=; N=; fi

# one line per instance: "<id> <status> <disk_gb> <storage_cost_per_gb_month>"
vast_rows() {
    vastai show instances --raw --full 2>/dev/null | python3 -c '
import json, sys
try:
    inst = json.load(sys.stdin)
except Exception:
    inst = []
for i in inst:
    print(i.get("id"), i.get("actual_status"), i.get("disk_space") or 0, i.get("storage_cost") or 0)
' 2>/dev/null
}

printf '%s1/2  stopping local services ...%s\n' "$C" "$N"
stop_local "$RUN"

printf '%s2/2  stopping Vast instance(s), keeping disk ...%s\n' "$C" "$N"
if ! command -v vastai >/dev/null 2>&1; then
    printf '%s     vastai CLI not found - local services are down, but the GPU may still be billing%s\n' "$Y" "$N"
    exit 1
fi

mapfile -t rows < <(vast_rows)
if (( ${#rows[@]} == 0 )); then
    printf '%s     no instances found%s\n' "$D" "$N"
else
    for row in "${rows[@]}"; do
        read -r id status _disk _cost <<<"$row"
        if [[ "$status" == "running" ]]; then
            printf '%s     stopping %s (disk %s GB kept)%s\n' "$D" "$id" "$_disk" "$N"
            vastai stop instance "$id" >/dev/null 2>&1
        else
            printf '%s     %s already %s%s\n' "$D" "$id" "$status" "$N"
        fi
    done
fi

sleep 6
echo
mapfile -t rows < <(vast_rows)
for row in "${rows[@]}"; do
    read -r id status disk cost <<<"$row"
    mo="$(awk -v d="$disk" -v c="$cost" 'BEGIN{printf "%.2f", d*c}')"
    printf '%s  instance %s: %s  disk %s GB  ~$%s/month standby%s\n' "$Y" "$id" "$status" "$disk" "$mo" "$N"
done
if (( ${#rows[@]} == 0 )); then
    printf '%s  no instances - nothing billing at all%s\n' "$G" "$N"
else
    printf '\n%s  GPU billing stopped. Run ./start-qwen.sh to resume (~24s).%s\n' "$G" "$N"
fi
