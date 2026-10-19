#!/usr/bin/env bash
# Memory watchdog for a DGX Spark running a rank: a Spark's GPU shares its 121 GiB with the host, so a rank that takes
# all of it does not get a clean CUDA out-of-memory error, the whole machine stops answering (and has to be power-cycled).
# This kills the rank's container (docker kill, no grace period) once MemAvailable has stayed under the floor for two
# samples in a row, before the machine gets there. Self-contained: start.sh copies it to the worker.
#
# Usage: memguard.sh start <container> <floor GiB> <log file> <pid file>   (replaces a guard already running for the pid file)
#        memguard.sh stop <pid file>
# The engine keeps its own reserve (TENSORFOLD_MEMORY_RESERVE_GIB, 12.2 GiB by default) free, so a healthy rank stays well
# above a floor of a few GiB; only something else eating into the reserve (or a reserve set too low) trips this.
set -u

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
avail_kb() { local k v; while read -r k v _; do [[ $k == MemAvailable: ]] && { echo "$v"; return; }; done </proc/meminfo; }

stop_guard() {
  local pidfile=$1 pid
  [[ -f "$pidfile" ]] || return 0
  pid=$(cat "$pidfile" 2>/dev/null)
  if [[ "$pid" =~ ^[0-9]+$ ]] && grep -q memguard "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 50); do [[ -d /proc/$pid ]] || break; sleep 0.1; done   # its exit handler runs first
  fi
  rm -f "$pidfile"
}
# a sleep a signal ends at once (a plain sleep holds the guard's exit handler back until it is over)
nap() { sleep "$1" & wait $!; }

run_guard() {
  local c=$1 floor_kb log=$3 pidfile=$4 low=0 a snap
  floor_kb=$(awk -v g="$2" 'BEGIN {printf "%d", g * 1048576}')
  snap=$(mktemp "${TMPDIR:-/tmp}/memguard-snap.XXXXXX") || snap=/dev/null
  mkdir -p "$(dirname "$log")" "$(dirname "$pidfile")"
  echo $$ > "$pidfile"
  trap '[[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]] && rm -f "$pidfile"; rm -f "$snap"; exit 0' TERM INT
  echo "$(stamp) memguard: watching $c, floor $2 GiB (MemAvailable $(( $(avail_kb) / 1048576 )) GiB now)" >> "$log"
  while nap 0.5; do
    a=$(avail_kb)
    if (( a >= floor_kb )); then low=0; continue; fi
    (( ++low >= 2 )) || continue
    low=0
    # Kill first, log afterwards: on a machine that is already thrashing every command ahead of the kill costs time. The
    # process snapshot runs beside it (it shows who else holds the memory); docker kill fails when the container is not running.
    ps -eo rss,pid,comm --sort=-rss 2>/dev/null | head -6 > "$snap" &
    if timeout 20 docker kill "$c" >/dev/null 2>&1; then
      wait
      {
        echo "$(stamp) memguard: MemAvailable $(( a / 1024 )) MiB was under the $2 GiB floor: killed container $c"
        sed 's/^/    /' "$snap"
      } >> "$log"
      nap 5
    else
      wait
    fi
  done
}

case "${1:-}" in
  start)
    shift
    [[ $# == 4 ]] || { echo "usage: memguard.sh start <container> <floor GiB> <log file> <pid file>" >&2; exit 2; }
    [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "memguard: floor is a number of GiB (2 or 2.5), not $2" >&2; exit 2; }
    stop_guard "$4"
    # detach: its own session, no terminal, so it outlives the ssh or shell that started it. Close fd 8, start.sh's lock
    # (flock on STATE_DIR/start.lock): a guard that kept it would hold the lock for as long as it runs.
    setsid nohup "$0" run "$@" >/dev/null 2>&1 < /dev/null 8>&- 9>&- &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$4" ]] && exit 0; sleep 0.2; done
    echo "memguard: did not start" >&2; exit 1 ;;
  run) shift; run_guard "$@" ;;
  stop) stop_guard "${2:?usage: memguard.sh stop <pid file>}" ;;
  *) echo "usage: memguard.sh start|stop ..." >&2; exit 2 ;;
esac
