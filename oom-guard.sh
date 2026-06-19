#!/usr/bin/env bash
# oom-guard: reap worker processes under MEMORY PRESSURE before they OOM-hang a
# small box.
#
# When free RAM (MemAvailable) drops below MEM_MIN_KB, oom-guard kills the
# IDLEST matching worker first (lowest recent CPU), re-checks memory after each,
# and stops as soon as MemAvailable recovers past MEM_TARGET_KB. The single
# most-active worker is ALWAYS protected (PROTECT_ACTIVE=1), so your live
# session survives while abandoned / overlapping ones are cleared. A client can
# just reconnect to spawn a fresh worker.
#
# Idleness is measured in-run with two CPU samples SAMPLE_SECS apart, so it
# reacts immediately and needs no persisted history. A brand-new worker with no
# measured activity is treated as active (protected), not a victim.
#
# Point it at the WORKER process you want reaped via PROC_PATTERN. It matches
# with `pgrep -x` (exact process name). It only ever touches processes that
# match PROC_PATTERN, so a parent daemon with a different name is never killed.
#
# Optional: set IDLE_SECS>0 to ALSO reap workers continuously idle that long,
# regardless of memory (off by default -- memory pressure is the real trigger).
#
# No root required: it only reads /proc and kills processes the running user
# already owns.
#
# Tunables (override via environment):
set -euo pipefail

PROC_PATTERN="${PROC_PATTERN:-claude.exe}"  # exact process name to reap (pgrep -x)
MEM_MIN_KB="${MEM_MIN_KB:-120000}"          # reap when MemAvailable < this (~120 MB)
MEM_TARGET_KB="${MEM_TARGET_KB:-200000}"    # stop reaping once MemAvailable >= this (~200 MB)
SAMPLE_SECS="${SAMPLE_SECS:-3}"             # window for the idleness (CPU-rate) measurement
IDLE_RATE="${IDLE_RATE:-2.0}"               # CPU ticks/sec below this == "idle"
GRACE_SECS="${GRACE_SECS:-10}"              # wait after SIGTERM before SIGKILL
PROTECT_ACTIVE="${PROTECT_ACTIVE:-1}"       # 1 = never kill the single most-active worker
IDLE_SECS="${IDLE_SECS:-0}"                 # >0 = also reap workers idle this long (memory aside)
DRY_RUN="${DRY_RUN:-0}"                     # 1 = log decisions, kill nothing

STATE_DIR="${STATE_DIR:-$HOME/.local/state/oom-guard}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/idle-state.tsv"   # pid<TAB>starttime<TAB>idle_since (only used if IDLE_SECS>0)
LOG_FILE="$STATE_DIR/oom-guard.log"

now="$(date +%s)"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }
mem_avail_kb() { awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo; }

# cumulative CPU ticks (utime+stime) and starttime for a pid from /proc.
# comm (field 2) may contain spaces/parens, so split on the LAST ')'.
read_proc() { # $1=pid -> "cputicks starttime" or nothing
  local stat rest
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  rest="${stat#*) }"                       # everything after "pid (comm) "
  # rest fields: state(1) ... utime(12) stime(13) ... starttime(20)
  awk -v r="$rest" 'BEGIN{split(r,f," "); print f[12]+f[13], f[20]}'
}

avail="$(mem_avail_kb)"; avail="${avail:-999999999}"   # can't read mem -> don't false-trigger
need_mem_reap=0
(( avail < MEM_MIN_KB )) && need_mem_reap=1

# Fast exit: memory is fine and idle-reaping is disabled -> nothing to do (no sample).
if (( need_mem_reap == 0 && IDLE_SECS == 0 )); then
  exit 0
fi

mapfile -t raw < <(pgrep -x "$PROC_PATTERN" || true)
pids=(); for p in "${raw[@]:-}"; do [[ -n "$p" ]] && pids+=("$p"); done
(( ${#pids[@]} == 0 )) && exit 0

# --- sample CPU twice to get a current idleness rate (ticks/sec) per pid ---
declare -A t0 start0
for p in "${pids[@]}"; do
  read -r tk st < <(read_proc "$p") || continue
  [[ -n "${tk:-}" ]] || continue
  t0["$p"]="$tk"; start0["$p"]="$st"
done
sleep "$SAMPLE_SECS"
declare -A rate
for p in "${pids[@]}"; do
  [[ -n "${t0[$p]:-}" ]] || continue
  read -r tk st < <(read_proc "$p") || continue
  [[ -n "${tk:-}" && "$st" == "${start0[$p]}" ]] || continue   # gone, or PID reused
  rate["$p"]="$(awk -v d="$((tk - ${t0[$p]}))" -v s="$SAMPLE_SECS" 'BEGIN{print (s>0)? d/s : 0}')"
done
(( ${#rate[@]} == 0 )) && exit 0

# Protect the most-active worker (highest rate) so your live session survives.
protect=""; best="-1"
for p in "${!rate[@]}"; do
  awk -v a="${rate[$p]}" -v b="$best" 'BEGIN{exit !(a>b)}' && { best="${rate[$p]}"; protect="$p"; }
done
[[ "$PROTECT_ACTIVE" == "1" ]] || protect=""

# Victims: everyone with a measured rate except the protected one, idlest-first.
tmpv=()
for p in "${!rate[@]}"; do [[ "$p" == "$protect" ]] || tmpv+=("$p|${rate[$p]}"); done
victims=()
if (( ${#tmpv[@]} > 0 )); then
  mapfile -t victims < <(printf '%s\n' "${tmpv[@]}" | sort -t'|' -k2,2g | cut -d'|' -f1)
fi

reap() { # $1=pid $2=reason
  local pid="$1" why="$2" i
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN would reap pid=$pid rate=${rate[$pid]:-?}t/s ($why)"; return 0
  fi
  log "reaping pid=$pid rate=${rate[$pid]:-?}t/s ($why) SIGTERM"
  kill -TERM "$pid" 2>/dev/null || true
  for ((i=0; i<GRACE_SECS; i++)); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    log "pid=$pid survived SIGTERM -> SIGKILL"; kill -KILL "$pid" 2>/dev/null || true
  fi
}

# --- memory-pressure reaping: kill idlest until MemAvailable recovers ---
if (( need_mem_reap == 1 )); then
  if (( ${#victims[@]} == 0 )); then
    log "MEM low: MemAvailable=${avail}kB < ${MEM_MIN_KB}kB but only the active worker is present; nothing safe to reap (host likely undersized)"
  else
    log "MEM low: MemAvailable=${avail}kB < ${MEM_MIN_KB}kB; ${#victims[@]} reapable worker(s); protecting pid=${protect:-none}"
    for pid in "${victims[@]}"; do
      cur="$(mem_avail_kb)"; cur="${cur:-0}"
      (( cur >= MEM_TARGET_KB )) && { log "MemAvailable recovered to ${cur}kB >= ${MEM_TARGET_KB}kB; stopping"; break; }
      reap "$pid" "mem-pressure idlest"
    done
  fi
fi

# --- optional: reap workers continuously idle >= IDLE_SECS (off unless set) ---
if (( IDLE_SECS > 0 )); then
  declare -A idle_since pstart
  if [[ -f "$STATE_FILE" ]]; then
    while IFS=$'\t' read -r p st since; do
      [[ -n "${p:-}" ]] && { pstart["$p"]="$st"; idle_since["$p"]="$since"; }
    done <"$STATE_FILE"
  fi
  tmp="$(mktemp "$STATE_DIR/.idle.XXXXXX")"
  for p in "${pids[@]}"; do
    kill -0 "$p" 2>/dev/null || continue          # already reaped above
    [[ -n "${rate[$p]:-}" && "$p" != "$protect" ]] || continue
    awk -v r="${rate[$p]}" -v thr="$IDLE_RATE" 'BEGIN{exit !(r<thr)}' || continue  # active -> skip
    st="${start0[$p]}"; since="${idle_since[$p]:-0}"
    [[ "${pstart[$p]:-}" == "$st" ]] || since=0    # PID reused -> reset idle clock
    (( since == 0 )) && since="$now"
    if (( now - since >= IDLE_SECS )); then
      reap "$p" "idle $((now - since))s >= ${IDLE_SECS}s"
    else
      printf '%s\t%s\t%s\n' "$p" "$st" "$since" >>"$tmp"
    fi
  done
  mv -f "$tmp" "$STATE_FILE"
fi
