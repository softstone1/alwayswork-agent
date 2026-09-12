# shellcheck shell=bash
# aw capability — manage the catalog, including out-of-tree capabilities.

cmd_capability() {
  local sub="${1:-list}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    add)
      [[ $# -ge 1 ]] || die "usage: aw capability add <path>"
      cap_add "$1" ;;
    list)  cmd_list "$@" ;;
    -h|--help) info "usage: aw capability <add <path>|list>" ;;
    *)     die "usage: aw capability <add <path>|list>" ;;
  esac
}
