#!/usr/bin/env bash
# The pair-restart guard for rank 0 (the port's): with the spill tier or KV sharding on, the engine's broken-pair policy
# (TF_DS_PAIR_BROKEN, default `exit` then) ends rank 0's process with status 75 when the pair breaks (rank 1 gone or
# hung, a spill-tier or KV-transfer break). start.sh runs detached containers, so nothing would restart them until
# the deployment's health watchdog gave up on /health (minutes). This guard polls rank 0's container every
# PAIRWATCH_POLL_S seconds (2) and, when it finds it `exited 75`, runs `./start.sh restart` from the recipe folder: both
# ranks stop and start again, the load included. docs/PORT-RECIPE.md "When the rank pair breaks".
#
# It acts only on 75 (memguard's kill is 137, a crash another code, a clean stop 0: those stay the watchdog's), only
# while the arm file exists (start.sh creates it, stop.sh removes it before it stops anything, so a stop's own exit is
# never restarted), never while the hold file (if one is given) exists, and at most MAX times an hour (then it logs and
# ends, leaving the stack to a person or the watchdog). It replaces itself with the restart (exec): the restarted
# start.sh starts a new guard. Self-contained, like scripts/memguard.sh.
#
# Before the restart (which removes the containers) it saves the exited rank 0's whole log, and each worker's rank's
# over ssh, into the log's folder (LOG_DIR) as <date>-<time>-rank<N>.log.gz, as start.sh and stop.sh name them, keeping
# the newest PAIRWATCH_SAVE_KEEP (start.sh passes LOG_KEEP, 10) of each rank. PAIRWATCH_WORKERS lists the workers as
# "<rank>=<ssh target>" words (start.sh passes WORKER's); a worker that cannot be read is logged and skipped.
#
# Retention is bounded: the log is rotated once it passes PAIRWATCH_LOG_MAX_KB (1024) KiB, keeping PAIRWATCH_LOG_KEEP (3)
# old copies (<log>.1 newest), checked before every line and before the restart's output is appended to it; the restart
# history (pairwatch.restarts beside the pid file) keeps only the last hour's restarts, at most 1,000 lines.
#
# Usage: pairwatch.sh start <container> <recipe dir> <log file> <pid file> <arm file> [max an hour [hold file]]
#        pairwatch.sh stop <pid file>
set -u

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
# rotate_log <log>: past the cap, <log> becomes <log>.1 (and .1 .2, up to the kept count); the oldest is dropped
rotate_log() {
  local log=$1 max_kb=${PAIRWATCH_LOG_MAX_KB:-1024} keep=${PAIRWATCH_LOG_KEEP:-3} size i
  [[ "$max_kb" =~ ^[1-9][0-9]*$ ]] || max_kb=1024
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  [[ -f "$log" && ! -L "$log" ]] || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d ' ') || return 0
  (( ${size:-0} > max_kb * 1024 )) || return 0
  if (( keep == 0 )); then : > "$log"; return 0; fi
  rm -f -- "$log.$keep"
  for (( i = keep - 1; i >= 1; i-- )); do [[ ! -f "$log.$i" ]] || mv -f -- "$log.$i" "$log.$((i + 1))"; done
  mv -f -- "$log" "$log.1"
}
# say <log> <text>: one stamped line, after a rotation if the log is past its cap
say() { rotate_log "$1"; echo "$(stamp) pairwatch: $2" >> "$1"; }
# prune_hist <file> <now>: keep only the restarts of the last hour (the hourly limit reads nothing older), at most 1,000
prune_hist() {
  local f=$1 now=$2 tmp
  [[ -f "$f" ]] || return 0
  tmp="$f.$$"
  awk -v t=$((now - 3600)) '$1 ~ /^[0-9]+$/ && $1 > t' "$f" 2>/dev/null | tail -n 1000 > "$tmp" && mv -f -- "$tmp" "$f" || rm -f -- "$tmp"
}
nap() { sleep "$1" & wait $!; }
# save_rank_log <dir> <rank> <container> <keep> [ssh target]: the container's whole log (stdout and stderr, with
# timestamps) gzipped into <dir>/<date>-<time>-rank<N>.log.gz (scripts/nodes.sh save_log's name and retention: the
# newest <keep> of that rank stay), read over ssh when a target is given (a worker's rank); prints the file.
save_rank_log() {
  local dir=$1 rank=$2 c=$3 keep=$4 host=${5:-} stamp f i=0 st
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || return 0
  mkdir -p "$dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S); f="$dir/$stamp-rank$rank.log.gz"
  while [[ -e "$f" ]]; do f="$dir/$stamp.$((++i))-rank$rank.log.gz"; done   # same second: still sorts as newer
  if [[ -n "$host" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 "$host" "docker logs --timestamps '$c' 2>&1" | gzip > "$f"
  else
    docker logs --timestamps "$c" 2>&1 | gzip > "$f"
  fi
  st=("${PIPESTATUS[@]}")
  if (( st[0] != 0 || st[1] != 0 )); then rm -f -- "$f"; return 1; fi
  ls -1 "$dir"/*-rank"$rank".log.gz 2>/dev/null | { grep -vxF "$f" || true; } | LC_ALL=C sort -r | tail -n +"$keep" | xargs -r rm -f --
  echo "$f"
}
# save_logs <log> <container>: every rank's log saved beside <log> before the restart removes the containers
save_logs() {
  local log=$1 c=$2 dir keep=${PAIRWATCH_SAVE_KEEP:-10} w f
  dir=$(dirname "$log")
  if f=$(save_rank_log "$dir" 0 "$c" "$keep"); then say "$log" "saved rank 0's log: ${f:-not kept (PAIRWATCH_SAVE_KEEP=0)}"
  else say "$log" "could not save rank 0's log ($c)"; fi
  for w in ${PAIRWATCH_WORKERS:-}; do
    [[ "$w" =~ ^([1-9])=(.+)$ ]] || { say "$log" "skipping the worker entry '$w' (not <rank>=<ssh target>)"; continue; }
    if f=$(save_rank_log "$dir" "${BASH_REMATCH[1]}" "$c" "$keep" "${BASH_REMATCH[2]}"); then say "$log" "saved rank ${BASH_REMATCH[1]}'s log: ${f:-not kept}"
    else say "$log" "could not save rank ${BASH_REMATCH[1]}'s log from ${BASH_REMATCH[2]}"; fi
  done
}

stop_watch() {
  local pidfile=$1 pid
  [[ -f "$pidfile" ]] || return 0
  pid=$(cat "$pidfile" 2>/dev/null)
  if [[ "$pid" =~ ^[0-9]+$ ]] && grep -q pairwatch "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 50); do [[ -d /proc/$pid ]] || break; sleep 0.1; done
  fi
  rm -f "$pidfile"
}

run_watch() {
  local c=$1 dir=$2 log=$3 pidfile=$4 arm=$5 max=${6:-6} hold=${7:-} hist st now n held=0 why
  hist="$(dirname "$pidfile")/pairwatch.restarts"
  mkdir -p "$(dirname "$log")" "$(dirname "$pidfile")"
  echo $$ > "$pidfile"
  trap '[[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]] && rm -f "$pidfile"; exit 0' TERM INT
  say "$log" "watching $c for exit status 75 (at most $max restarts an hour${hold:+, never while $hold exists})"
  while nap "${PAIRWATCH_POLL_S:-2}"; do
    st=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$c" 2>/dev/null) || continue
    [[ "$st" == "exited 75" ]] || { held=0; continue; }
    [[ -e "$arm" ]] || continue                                   # stop.sh is stopping the stack: not a break
    if [[ -n "$hold" && -e "$hold" ]]; then
      (( held )) || say "$log" "$c exited with status 75, but $hold exists: not restarting"
      held=1; continue
    fi
    now=$(date +%s)
    prune_hist "$hist" "$now"
    n=$(( $(awk -v t=$((now - 3600)) '$1 > t' "$hist" 2>/dev/null | wc -l) ))
    if (( n >= max )); then
      say "$log" "$c exited with status 75, but the pair was restarted $n times in the last hour: not again (docker logs $c)"
      rm -f "$pidfile"; exit 0
    fi
    echo "$now" >> "$hist"
    why=$(docker logs --tail 300 "$c" 2>&1 | grep -m1 -E 'rank pair broken|the rank pair broke' || true)
    say "$log" "$c exited with status 75 (${why:-no rank pair line in its log}): restarting both ranks ($dir/start.sh restart)"
    save_logs "$log" "$c"                                           # (the restart removes the containers and their logs)
    rm -f "$pidfile"; trap - TERM INT
    cd "$dir" || { say "$log" "no recipe folder $dir"; exit 1; }
    rotate_log "$log"
    exec ./start.sh restart >> "$log" 2>&1
  done
}

# Sourced with PAIRWATCH_LIB=1 (scripts/port_test.sh): define the functions and stop here
[[ "${PAIRWATCH_LIB:-0}" != 1 ]] || return 0

case "${1:-}" in
  start)
    shift
    (( $# >= 5 && $# <= 7 )) || { echo "usage: pairwatch.sh start <container> <recipe dir> <log file> <pid file> <arm file> [max an hour [hold file]]" >&2; exit 2; }
    [[ -z "${6:-}" || "$6" =~ ^[1-9][0-9]*$ ]] || { echo "pairwatch: the hourly limit is a positive count, not $6" >&2; exit 2; }
    [[ -x "$2/start.sh" ]] || { echo "pairwatch: no $2/start.sh" >&2; exit 2; }
    stop_watch "$4"
    # detached as memguard is (its own session, no terminal), without start.sh's lock (fd 8) or other fds
    setsid nohup "$0" run "$@" >/dev/null 2>&1 < /dev/null 8>&- 9>&- &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$4" ]] && exit 0; sleep 0.2; done
    echo "pairwatch: did not start" >&2; exit 1 ;;
  run) shift; run_watch "$@" ;;
  stop) stop_watch "${2:?usage: pairwatch.sh stop <pid file>}" ;;
  *) echo "usage: pairwatch.sh start|stop ..." >&2; exit 2 ;;
esac
