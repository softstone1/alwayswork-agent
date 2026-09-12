# shellcheck shell=bash
# aw clean — remove packages, caches and junk that are no longer used.

cmd_clean() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) info "usage: aw clean"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  require_root clean
  cfg_require
  cfg_need
  cleanup_apply
}
