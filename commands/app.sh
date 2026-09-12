# shellcheck shell=bash
# aw app — the on-demand tool catalog.

cmd_app() {
  require_cmd yq
  local sub="${1:-list}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    list)    app_list "${1:-}" ;;
    search)
      [[ $# -ge 1 ]] || die "usage: aw app search <term>"
      app_search "$1" ;;
    install)
      [[ $# -ge 1 ]] || die "usage: aw app install <id>..."
      require_root app
      local id
      for id in "$@"; do app_install "$id"; done
      ;;
    remove)
      [[ $# -ge 1 ]] || die "usage: aw app remove <id>..."
      require_root app
      local id
      for id in "$@"; do app_remove "$id"; done
      ;;
    -h|--help) info "usage: aw app <list [category]|search <term>|install <id>...|remove <id>...>" ;;
    *) die "usage: aw app <list [category]|search <term>|install <id>...|remove <id>...>" ;;
  esac
}
