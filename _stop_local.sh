# Helper, not a command -- sourced by stop-qwen.sh and stop-qwen-full.sh.
# Defines stop_local(), which shuts down the three local services plus the ssh
# tunnel the supervisor spawned (killing the supervisor does not kill its child).
#
# Two passes, because a pid file is authoritative but not sufficient: a service
# started by hand, or a tunnel left behind by a supervisor that was killed
# earlier, has no pid file. So: pid files first, then the same command-line
# patterns the Windows version matches on.

QWEN_PATTERNS=(tunnel_supervisor normalize_proxy litellm_config '18000:127\.0\.0\.1:18000')

stop_local() {
    local run="$1" killed=0 pid f pat
    local -a doomed=()

    for f in "$run"/*.pid; do
        [[ -e "$f" ]] || continue
        pid="$(cat "$f" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            printf '     killing %s pid %s\n' "$(basename "$f" .pid)" "$pid"
            kill "$pid" 2>/dev/null && doomed+=("$pid") && killed=$((killed+1))
        fi
        rm -f "$f"
    done

    for pat in "${QWEN_PATTERNS[@]}"; do
        while read -r pid; do
            [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
            printf '     killing stray pid %s (%s)\n' "$pid" "$pat"
            kill "$pid" 2>/dev/null && doomed+=("$pid") && killed=$((killed+1))
        done < <(pgrep -f -- "$pat" 2>/dev/null)
    done

    # give SIGTERM a moment, then insist
    if (( ${#doomed[@]} )); then
        sleep 2
        for pid in "${doomed[@]}"; do kill -9 "$pid" 2>/dev/null; done
    fi
    (( killed == 0 )) && printf '     (nothing was running)\n'
    return 0
}
