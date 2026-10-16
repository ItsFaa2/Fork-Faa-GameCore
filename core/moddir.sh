#!/system/bin/sh
# moddir.sh — dynamic module-directory resolution. No fixed path assumed.
# Candidates are VERIFIED by readdir before use (stat() on Magisk mirror
# paths can flake during mount churn; ls+grep keeps working). The first
# candidate containing core/fgc-cli.sh wins; FGC_MODDIR is exported so all
# children inherit the same value (no split state / duplicate daemons).
# Sourced, not executed. POSIX sh only.

# fgc_moddir_verify <dir> -> 0 when <dir>/core/fgc-cli.sh is readable via readdir
fgc_moddir_verify() {
  [ -n "$1" ] || return 1
  ls "$1/core" 2>/dev/null | grep -qx 'fgc-cli.sh'
}

# fgc_moddir_resolve [extra-candidate...] -> prints first verified dir, or empty.
# Priority: caller extras (e.g. host-provided path) > $0-derived > env >
# standard root-manager module roots (each verified, never assumed).
fgc_moddir_resolve() {
  _self="${0%/*}"
  case "$_self" in */core) _self="${_self%/*}" ;; esac
  for _c in "$@" \
            "${FGC_MODDIR_ARG:-}" \
            "$_self" \
            "${FGC_MODDIR:-}" \
            "/data/adb/modules/faagamecore" \
            "/data/adb/modules_update/faagamecore" \
            "/data/adb/ksu/module/faagamecore" \
            "/data/adb/ap/module/faagamecore"; do
    if fgc_moddir_verify "$_c"; then printf '%s' "$_c"; return 0; fi
  done
  printf ''
  return 1
}
