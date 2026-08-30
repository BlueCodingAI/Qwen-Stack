#!/usr/bin/env bash
# Full teardown: pay NOTHING between sessions. (Ubuntu/Linux twin of stop-qwen-full.ps1)
# Deletes the workergroup and destroys the instance, taking the 150 GB disk with it,
# so the next start re-downloads the 51 GB model (~2-3 min instead of ~24s).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
RUN="$here/.run"; mkdir -p "$RUN"
. "$here/_stop_local.sh"

ENDPOINT_ID=35555

if [[ -t 1 ]]; then C=$'\033[36m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
else C=; G=; R=; Y=; N=; fi

printf '%s1/3  stopping local services ...%s\n' "$C" "$N"
stop_local "$RUN"

if ! command -v vastai >/dev/null 2>&1; then
    printf '%svastai CLI not found - local services are down, but the GPU is still billing%s\n' "$Y" "$N"
    exit 1
fi

printf '%s2/3  deleting workergroup(s) ...%s\n' "$C" "$N"
while read -r gid; do
    [[ -n "$gid" ]] && vastai delete workergroup "$gid" >/dev/null 2>&1
done < <(vastai show workergroups --raw --full 2>/dev/null | python3 -c '
import json, sys
try:
    groups = json.load(sys.stdin)
except Exception:
    groups = []
print("\n".join(str(g["id"]) for g in groups if g.get("endpoint_id") == int(sys.argv[1])))
' "$ENDPOINT_ID" 2>/dev/null)

instance_ids() {
    vastai show instances --raw --full 2>/dev/null | python3 -c '
import json, sys
try:
    inst = json.load(sys.stdin)
except Exception:
    inst = []
print("\n".join(str(i["id"]) for i in inst))
' 2>/dev/null
}

printf '%s3/3  destroying instances ...%s\n' "$C" "$N"
sleep 5
while read -r iid; do
    [[ -n "$iid" ]] && vastai destroy instance "$iid" -y >/dev/null 2>&1
done < <(instance_ids)

sleep 5
n="$(instance_ids | grep -c '[0-9]')"
echo
if [[ "$n" == "0" ]]; then
    printf '%sAll clear - 0 instances, nothing billing.%s\n' "$G" "$N"
else
    printf '%sWARNING: %s instance(s) remain - check cloud.vast.ai/instances/%s\n' "$R" "$n" "$N"
fi
