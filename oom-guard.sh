#!/usr/bin/env bash
# oom-guard: reap idle worker processes before they OOM-hang a small box.
#
# A worker is "idle" when its average CPU rate since the last sample is below
# IDLE_RATE (ticks/sec). When a worker stays idle continuously for IDLE_SECS,
# it is sent SIGTERM (then SIGKILL after a short grace period). This frees the
# RAM that idle workers slowly accumulate, which on a memory-constrained host
# (e.g. a 1 GB VPS/EC2 instance) is a common cause of the machine thrashing
# and freezing under memory pressure (an out-of-memory hang).
#
# Point it at the WORKER process you want reaped via PROC_PATTERN. It matches
# with `pgrep -x` (exact process name). It only ever touches processes that
# match PROC_PATTERN, so a parent daemon with a different name is never killed
# and clients can simply reconnect to spawn a fresh worker.
#
# No root required: it only reads /proc and kills processes the running user
# already owns.
#
# Tunables (override via environment):
set -euo pipefail

PROC_PATTERN="${PROC_PATTERN:-claude.exe}"  # exact process name to reap when idle
IDLE_SECS="${IDLE_SECS:-1800}"              # idle this long (s) before reaping (30 min)
IDLE_RATE="${IDLE_RATE:-2.0}"               # CPU ticks/sec below this == idle
GRACE_SECS="${GRACE_SECS:-10}"              # wait after SIGTERM before SIGKILL
DRY_RUN="${DRY_RUN:-0}"                     # 1 = log decisions, kill nothing

STATE_DIR="${STATE_DIR:-$HOME/.local/state/oom-guard}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.tsv"   # lines: pid<TAB>starttime<TAB>cputicks<TAB>idle_since
LOG_FILE="$STATE_DIR/oom-guard.log"
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"  # ticks per second (informational)

now="$(date +%s)"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

# Read cumulative CPU ticks (utime+stime) and starttime for a pid from /proc.
# comm (field 2) may contain spaces/parens, so split on the LAST ')'.
read_proc() { # $1=pid -> echoes "cputicks starttime" or nothing
  local stat rest
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  rest="${stat#*) }"                       # everything after "pid (comm) "
  # rest fields: state(1) ... utime(12) stime(13) ... starttime(20)
  awk -v r="$rest" 'BEGIN{n=split(r,f," "); print f[12]+f[13], f[20]}'
}

declare -A prev_ticks prev_start idle_since
if [[ -f "$STATE_FILE" ]]; then
  while IFS=$'\t' read -r p st tk since; do
    [[ -n "${p:-}" ]] || continue
    prev_ticks["$p"]="$tk"; prev_start["$p"]="$st"; idle_since["$p"]="$since"
  done <"$STATE_FILE"
fi

# Interval since last run, for rate calc (default to IDLE_SECS if first run / no marker).
last_run_file="$STATE_DIR/.lastrun"
interval="$IDLE_SECS"
if [[ -f "$last_run_file" ]]; then
  prev_run="$(cat "$last_run_file" 2>/dev/null || echo 0)"
  (( now > prev_run )) && interval=$(( now - prev_run ))
fi
echo "$now" >"$last_run_file"

tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")"
mapfile -t pids < <(pgrep -x "$PROC_PATTERN" || true)

for pid in "${pids[@]:-}"; do
  [[ -n "${pid:-}" ]] || continue
  read -r ticks start < <(read_proc "$pid") || continue
  [[ -n "${ticks:-}" && -n "${start:-}" ]] || continue

  pstart="${prev_start[$pid]:-}"
  ptick="${prev_ticks[$pid]:-}"
  psince="${idle_since[$pid]:-0}"

  # New process or PID reuse (starttime changed) -> reset tracking.
  if [[ "$pstart" != "$start" || -z "$ptick" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$ticks" "0" >>"$tmp"
    continue
  fi

  delta=$(( ticks - ptick )); (( delta < 0 )) && delta=0
  # rate (ticks/sec) = delta / interval ; compare against IDLE_RATE
  is_idle="$(awk -v d="$delta" -v i="$interval" -v thr="$IDLE_RATE" \
            'BEGIN{ r = (i>0)? d/i : 0; print (r < thr) ? 1 : 0 }')"

  if [[ "$is_idle" == "1" ]]; then
    since="$psince"; (( since == 0 )) && since="$now"
    idle_for=$(( now - since ))
    if (( idle_for >= IDLE_SECS )); then
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN would reap pid=$pid idle_for=${idle_for}s (delta=${delta}t/${interval}s)"
        printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$ticks" "$since" >>"$tmp"
      else
        log "reaping pid=$pid idle_for=${idle_for}s (delta=${delta}t/${interval}s) SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        # don't write state for it; if it survives we'll re-detect next run
      fi
    else
      printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$ticks" "$since" >>"$tmp"
    fi
  else
    # active -> reset idle clock
    printf '%s\t%s\t%s\t%s\n' "$pid" "$start" "$ticks" "0" >>"$tmp"
  fi
done

# Second pass (only when actually killing): SIGKILL anything we TERMed that lingers.
if [[ "$DRY_RUN" != "1" ]]; then
  sleep "$GRACE_SECS"
  for pid in "${pids[@]:-}"; do
    [[ -n "${pid:-}" ]] || continue
    # still alive AND no fresh state line (i.e. we tried to reap it)?
    if kill -0 "$pid" 2>/dev/null && ! grep -q "^$pid"$'\t' "$tmp"; then
      log "pid=$pid survived SIGTERM -> SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
fi

mv -f "$tmp" "$STATE_FILE"
