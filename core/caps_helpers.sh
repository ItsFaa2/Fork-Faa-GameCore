#!/system/bin/sh
# caps_helpers.sh — capability-gated operation executors (POSIX sh).
# Every mutating operation first checks the LAST VERIFIED capability snapshot
# (state/caps.json, written by core/caps.sh probes). If an environment does
# not support an operation, we fail HONESTLY (nonzero + structured log) and
# only that feature is skipped — never faked success, never brand assumptions.
# Sourced, not executed.

# fgc_cap_enabled <key> -> 0 when caps.json reports the key as working
#   foreground -> "ok" | pkg_query -> "pm" | kill -> "am" | freeze -> "pm"
fgc_cap_enabled() {
  _ck="$1"
  [ -f "$FGC_STATE/caps.json" ] || return 1
  case "$_ck" in
    foreground) grep -q '"foreground":"ok"' "$FGC_STATE/caps.json" 2>/dev/null ;;
    *) grep -q "\"$_ck\":\"pm\"\|\"$_ck\":\"am\"" "$FGC_STATE/caps.json" 2>/dev/null ;;
  esac
}

fgc_cap_fail_msg() {
  # $1 = key -> human token recorded in logs (stable, greppable)
  printf 'cap-unsupported-%s' "$1"
}

fgc_am_force_stop() {
  # $1 = exact package. Kill ONLY if the kill capability was verified.
  _kp="$1"
  case "$_kp" in ''|*[!a-zA-Z0-9._]*) return 2 ;; esac
  if ! fgc_cap_enabled kill; then
    fgc_log "CLEANUP_FAILED" "$_kp" "force-stop" "failed" "$(fgc_cap_fail_msg kill)"
    return 3
  fi
  fgc_run_timed 30 am force-stop "$_kp"
}

fgc_pm_disable_user() {
  # $1 = exact package. Freeze ONLY if the full freeze cycle was verified.
  _fp="$1"
  case "$_fp" in ''|*[!a-zA-Z0-9._]*) return 2 ;; esac
  if ! fgc_cap_enabled freeze; then
    fgc_log "CLEANUP_FAILED" "$_fp" "freeze" "failed" "$(fgc_cap_fail_msg freeze)"
    return 3
  fi
  fgc_run_timed 20 pm disable-user --user 0 "$_fp"
}

fgc_pm_enable() {
  # $1 = exact package. Unfreeze path: enable is part of the verified freeze
  # cycle (both verbs probed together), so the same gate applies.
  _ep="$1"
  case "$_ep" in ''|*[!a-zA-Z0-9._]*) return 2 ;; esac
  if ! fgc_cap_enabled freeze; then
    fgc_log "CLEANUP_FAILED" "$_ep" "unfreeze" "failed" "$(fgc_cap_fail_msg freeze)"
    return 3
  fi
  fgc_run_timed 20 pm enable --user 0 "$_ep"
}
