#!/system/bin/sh
# main.sh — daemon entry. Poll loop with sleep (no busy loop). Single instance via lock dir.
# Boot-timing robust: waits for sys.boot_completed (bounded), verifies the
# daemon's REAL process when checking liveness, removes stale locks, and never
# reports Running without a live, pid-verified owner.
# Usage: main.sh [MODDIR]
MODDIR="${1:-${0%/*}/..}"
export FGC_MODDIR="$MODDIR"
CORE_DIR="$MODDIR/core"
. "$CORE_DIR/config_manager.sh"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/event_detector.sh"
. "$CORE_DIR/session_controller.sh"
. "$CORE_DIR/paths.sh"

mkdir -p "$FGC_STATE" "$FGC_LOGS"
LOCKDIR="$FGC_STATE/daemon.lock"

fgc_proc_cmdline() {
  # $1 = pid -> prints its cmdline (NULs turned to spaces) or empty.
  _pc="/proc/$1/cmdline"
  [ -r "$_pc" ] || return 1
  tr '\0' ' ' < "$_pc" 2>/dev/null
}

fgc_pid_is_daemon() {
  # $1 = pid ; 0 only when that live process really runs core/main.sh
  _dpid="$1"
  case "$_dpid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$_dpid" ] || return 1
  fgc_proc_cmdline "$_dpid" | grep -q 'core/main\.sh'
}

fgc_daemon_alive() {
  # 0 = a live main.sh owns the lock (refuse start); 1 = stale/missing.
  # Uses /proc cmdline (universal on Android, no pgrep needed); unreadable
  # or mismatched PID is treated as STALE so a crash can never wedge startup.
  # A concurrent starter racing us may still win the mkdir below — harmless:
  # both share canonical state and the session lock serializes cleanups.
  [ -d "$LOCKDIR" ] || return 1
  _dpid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
  if fgc_pid_is_daemon "$_dpid"; then return 0; fi
  return 1
}

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if fgc_daemon_alive; then
    echo "FGC already running"; exit 0
  fi
  rm -rf "$LOCKDIR" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || { echo "FGC lock busy"; exit 0; }
fi
printf '%s' "$$" > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR" 2>/dev/null; exit 0' TERM INT

# ---- boot timing: wait for boot completion before touching activity manager.
# Bounded wait (FGC_BOOT_WAIT_SEC, default 120s): on slow ROMs service.sh may
# run long before sys.boot_completed flips; acting earlier yields false
# detections and failed pm/am calls. getprop failing entirely is not fatal —
# we log honestly and proceed after the wait window.
_fg_wait="${FGC_BOOT_WAIT_SEC:-120}"
_fg_slept=0
while [ "$_fg_slept" -lt "$_fg_wait" ] 2>/dev/null; do
  _bc="$(getprop sys.boot_completed 2>/dev/null)"
  [ "$_bc" = "1" ] && break
  sleep 2
  _fg_slept=$((_fg_slept+2))
done
_bc="$(getprop sys.boot_completed 2>/dev/null)"
if [ "$_bc" != "1" ]; then
  fgc_log "CORE_WARN" "" "daemon" "boot-wait-timeout" "sys.boot_completed!=1 after ${_fg_wait}s; continuing best-effort"
fi

# ---- ownership re-check right before serving: our PID must still own the
# lock (guards against a racy takeover while we waited above).
_own="$(cat "$LOCKDIR/pid" 2>/dev/null)"
if [ "$_own" != "$$" ]; then
  fgc_log "CORE_WARN" "" "daemon" "lock-taken-over" "another daemon owns lock; exiting"
  exit 0
fi

sh "$CORE_DIR/recovery.sh" >/dev/null 2>&1 || true
# capability snapshot for diagnostics + degraded-mode decision
. "$CORE_DIR/caps.sh"
FGC_CAPS_JSON="$(fgc_detect_caps 2>/dev/null)"
case "$FGC_CAPS_JSON" in
  *'"foreground":"none"'*)
    fgc_log "CORE_ERROR" "" "daemon" "no-foreground-source" "foreground detection unavailable; game-session detection disabled (graceful degradation)" ;;
  *'"kill":"none"'*)
    fgc_log "CORE_WARN" "" "daemon" "no-kill-capability" "am force-stop unsupported; cleanup skipped honestly" ;;
  *'"freeze":"none"'*)
    fgc_log "CORE_WARN" "" "daemon" "no-freeze-capability" "pm disable-user/enable unsupported; freeze feature disabled" ;;
esac
fgc_log "SESSION_STARTED" "" "daemon" "core-started" ""

# FGC_MAX_ITER: lifecycle hook for automated tests (default 0 = run forever).
# Production is unaffected; tests set e.g. FGC_MAX_ITER=3 for a bounded run
# with clean lock release, proving start/stop/single-instance behavior.
_n=0
while true; do
  _int="$(fgc_cfg_get poll_interval_sec)"; [ -n "$_int" ] || _int=3
  # heartbeat: refresh the pid every loop so external status checks can verify
  # the ACTUAL live process behind the lock (never a stale "Running").
  printf '%s' "$$" > "$LOCKDIR/pid" 2>/dev/null
  _res="$(fgc_detect_once)"
  case "$_res" in
    GAME\|*) _pkg="${_res#GAME|}"; FGC_GAME="$_pkg" fgc_session_start "$_pkg" ;;
    IDLE) fgc_session_end ;;
    DISABLED) fgc_session_end ;;
  esac
  _n=$((_n+1))
  if [ "${FGC_MAX_ITER:-0}" -gt 0 ] 2>/dev/null && [ "$_n" -ge "$FGC_MAX_ITER" ]; then break; fi
  sleep "$_int"
done
# only remove the lock if WE still own it (never clobber a newer daemon's lock)
_own="$(cat "$LOCKDIR/pid" 2>/dev/null)"
if [ "$_own" = "$$" ]; then rm -rf "$LOCKDIR" 2>/dev/null; fi
