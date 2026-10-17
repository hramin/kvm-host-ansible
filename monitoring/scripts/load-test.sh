#!/usr/bin/env bash
# Put CPU or memory load on this host for a short time, to fire the lab alerts.
#
#   ./load-test.sh cpu [seconds]            # all cores busy (default 30 s)
#   ./load-test.sh mem [seconds] [percent]  # hold <percent> of MemAvailable (default 30 s, 90 %)
#
# Prints CPU and memory every 2 seconds while it runs. Needs only bash and python3.
# Stops cleanly on Ctrl+C.
set -euo pipefail

mode="${1:-}"
seconds="${2:-30}"
percent="${3:-90}"
pids=()

cleanup() {
    for pid in "${pids[@]:-}"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mem_kb() { awk -v k="$1:" '$1 == k {print $2}' /proc/meminfo; }

cpu_sample() { awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }   # total idle

watch_stats() {
    local end=$((SECONDS + seconds)) prev now
    prev="$(cpu_sample)"
    printf '%-8s %-10s %-22s %s\n' "time" "cpu busy" "mem available" "load 1m"
    while (( SECONDS < end )); do
        sleep 2
        now="$(cpu_sample)"
        read -r t0 i0 <<< "$prev"; read -r t1 i1 <<< "$now"; prev="$now"
        local dt=$((t1 - t0)) di=$((i1 - i0))
        local busy=$(( dt > 0 ? 100 * (dt - di) / dt : 0 ))
        local avail total
        avail="$(mem_kb MemAvailable)"; total="$(mem_kb MemTotal)"
        printf '%-8s %-10s %-22s %s\n' "$(date +%T)" "${busy}%" \
            "$((avail / 1024)) MiB ($((100 * avail / total))%)" "$(cut -d' ' -f1 /proc/loadavg)"
    done
}

case "$mode" in
    cpu)
        cores="$(nproc)"
        echo "CPU load: ${cores} busy loop(s) for ${seconds}s"
        for _ in $(seq "$cores"); do
            timeout "$seconds" bash -c 'while :; do :; done' &
            pids+=("$!")
        done
        ;;
    mem)
        avail_kb="$(mem_kb MemAvailable)"
        bytes=$(( avail_kb * 1024 * percent / 100 ))
        echo "Memory load: holding $((bytes / 1024 / 1024)) MiB (${percent}% of MemAvailable) for ${seconds}s"
        # Write one byte per 4 KiB page so the kernel really commits the memory.
        python3 -c '
import sys, time
size, secs = int(sys.argv[1]), int(sys.argv[2])
buf = bytearray(size)
for i in range(0, size, 4096):
    buf[i] = 1
time.sleep(secs)
' "$bytes" "$seconds" &
        pids+=("$!")
        ;;
    *)
        echo "usage: $0 cpu [seconds] | mem [seconds] [percent]" >&2
        exit 2
        ;;
esac

watch_stats
echo "Done. Load stopped."
