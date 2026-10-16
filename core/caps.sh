#!/system/bin/sh
# caps.sh — runtime capability detection. No model-name checks, no brand assumptions.
# Probes which Android commands exist AND whether the specific operations this
# module performs actually work. A capability is only reported "yes"/set when a
# real probe run succeeds — command presence alone is never treated as proof.
# Writes state/caps.json (best effort) and shell-sets FGC_CAPS_* vars. Sourced, not executed.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"
. "${FGC_MODDIR}/core/str.sh"
# foreground verification reuses the exact production parser:
. "${FGC_MODDIR}/core/foreground_monitor.sh"

fgc_has_cmd() { command -v "$1" >/dev/null 2>&1; }

fgc_detect_launcher() {
  # Best-effort current launcher package. Prints package or empty. Never fails hard.
  # File-based (no cmd|grep pipe): avoids early-exit pipe hazards on some runtimes.
  _r=""
  if fgc_has_cmd cmd; then
    _cout="$FGC_STATE/.cmdout"
    if fgc_run_timed 15 cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME > "$_cout" 2>/dev/null; then
      while IFS= read -r _cl || [ -n "$_cl" ]; do
        case "$_cl" in */*) _r="${_cl%%/*}"; break ;; esac
      done < "$_cout"
    fi
    rm -f "$_cout"
  fi
  if [ -z "$_r" ] && fgc_has_cmd dumpsys; then
    _dout="$FGC_STATE/.dout"
    if fgc_run_timed 15 dumpsys activity activities > "$_dout" 2>/dev/null; then
      _r="$(grep -m1 'mFocusedApp' "$_dout" 2>/dev/null | grep -o '[a-zA-Z][a-zA-Z0-9_]*\(\.[a-zA-Z0-9_][a-zA-Z0-9_]*\)\+' | tail -n1)"
    fi
    rm -f "$_dout"
    case "$_r" in *launcher*|*home*) ;; *) _r="" ;; esac
  fi
  case "$_r" in ''|*[!a-zA-Z0-9._]*) printf '' ;; *) printf '%s' "$_r" ;; esac
}

fgc_detect_caps() {
  # Prints compact JSON. Also refreshes state/protected_extra.txt (dynamic launcher).
  # CAPABILITY = OPERATION VERIFIED, not command presence alone: `pm`, `am`,
  # `dumpsys` or `getprop` existing proves nothing about the specific calls
  # this module makes. Every "yes" below comes from a real probe run.
  _pm=no;     fgc_has_cmd pm && _pm=yes
  _dumpsys=no; fgc_has_cmd dumpsys && _dumpsys=yes
  _am=no;     fgc_has_cmd am && _am=yes
  _cmd=no;    fgc_has_cmd cmd && _cmd=yes
  _getprop=no; fgc_has_cmd getprop && _getprop=yes

  # ps: must actually list processes (toybox/busybox differ; `ps -A` may fail)
  _ps=no
  if command -v ps >/dev/null 2>&1; then
    if fgc_run_timed 10 ps -A >/dev/null 2>&1; then _ps=yes; fi
  fi

  # getprop: must return boot_completed value (non-empty output)
  _getprop_ok=no
  if [ "$_getprop" = yes ]; then
    if [ -n "$(fgc_run_timed 5 getprop sys.boot_completed 2>/dev/null)" ]; then _getprop_ok=yes; fi
  fi

  # foreground detection: probe BOTH sources; only a source that yields a
  # parseable package token counts as working. Never fake success.
  _fg=none; _fgok=no
  if [ "$_dumpsys" = yes ]; then
    # grep -c consumes all input (no early exit) -> always terminates
    if [ "$(fgc_run_timed 20 dumpsys activity activities 2>/dev/null | grep -c 'mFocusedApp\|ResumedActivity')" -gt 0 ] 2>/dev/null; then _fg=activity
    elif [ "$(fgc_run_timed 20 dumpsys window windows 2>/dev/null | grep -c 'mCurrentFocus\|mFocusedApp')" -gt 0 ] 2>/dev/null; then _fg=window
    else _fg=dumpsys-present-unverified; fi
    if [ "$_fg" = activity ] || [ "$_fg" = window ]; then
      _tok="$(fgc_foreground_pkg 2>/dev/null)"
      case "$_tok" in *.*) _fgok=yes ;; esac
    fi
  fi

  # pkg_query: `pm list packages` must actually return package lines
  _pkg=none
  if [ "$_pm" = yes ]; then
    if fgc_run_timed 20 pm list packages 2>/dev/null | head -n1 | grep -q '^package:'; then _pkg=pm; fi
  fi

  # kill: `am force-stop` must be ACCEPTED (probe on throwaway package name;
  # a nonexistent pkg errors differently from an unsupported/absent verb).
  _kill=none
  if [ "$_am" = yes ]; then
    if fgc_run_timed 10 am force-stop com.fgc.cap.probe >/dev/null 2>&1; then _kill=am
    else
      _kout="$(fgc_run_timed 10 am force-stop com.fgc.cap.probe 2>&1)"
      case "$_kout" in *unknown*command*|*not*found*) ;; *) _kill=am ;; esac
    fi
  fi

  # freeze/unfreeze: BOTH verbs of the reversible freeze cycle must be
  # accepted by pm (disable-user AND enable) — probing only one would let a
  # half-working environment strand apps in the disabled state.
  _freeze=none
  if [ "$_pm" = yes ]; then
    _fd=no; _fe=no
    fgc_run_timed 15 pm disable-user --user 0 com.fgc.cap.probe >/dev/null 2>&1 && _fd=yes
    if [ "$_fd" = no ]; then
      _o="$(fgc_run_timed 15 pm disable-user --user 0 com.fgc.cap.probe 2>&1)"
      case "$_o" in ''|*unknown*command*|*not*found*) ;; *) _fd=yes ;; esac
    fi
    fgc_run_timed 15 pm enable --user 0 com.fgc.cap.probe >/dev/null 2>&1 && _fe=yes
    if [ "$_fe" = no ]; then
      _o="$(fgc_run_timed 15 pm enable --user 0 com.fgc.cap.probe 2>&1)"
      case "$_o" in ''|*unknown*command*|*not*found*) ;; *) _fe=yes ;; esac
    fi
    [ "$_fd" = yes ] && [ "$_fe" = yes ] && _freeze=pm
  fi
  mkdir -p "$FGC_STATE"
  # system-package snapshot for profile policy (Balance = user-type only).
  # No early-exit pipes: pm output fully consumed, empty result removes stale data.
  _sys="$FGC_STATE/.syspkgs"
  if fgc_has_cmd pm; then
    fgc_run_timed 20 pm list packages -s 2>/dev/null | sed 's/^package://' | sort -u > "$_sys.tmp" 2>/dev/null
    if [ -s "$_sys.tmp" ]; then mv "$_sys.tmp" "$_sys"; else rm -f "$_sys.tmp" "$_sys"; fi
  else
    rm -f "$_sys"
  fi
  # dynamic extra protection: detected launcher (universal, not brand-specific)
  _lc="$(fgc_detect_launcher)"
  if [ -n "$_lc" ]; then printf '%s\n' "$_lc" > "$FGC_STATE/protected_extra.txt"
  else : > "$FGC_STATE/protected_extra.txt"; fi
  # foreground: reported "ok" ONLY when a real probe returned a parseable
  # package token; otherwise the exact failure mode is surfaced honestly.
  if [ "$_fgok" = yes ]; then _fg=ok; fi
  printf '{"pm":"%s","dumpsys":"%s","am":"%s","cmd":"%s","getprop":"%s","ps":"%s","getprop_boot":"%s","foreground":"%s","pkg_query":"%s","kill":"%s","freeze":"%s","launcher":"%s"}\n' \
    "$_pm" "$_dumpsys" "$_am" "$_cmd" "$_getprop" "$_ps" "$_getprop_ok" "$_fg" "$_pkg" "$_kill" "$_freeze" "$_lc" | tee "$FGC_STATE/caps.json" 2>/dev/null
}
case "$0" in *caps.sh) fgc_detect_caps ;; esac
