# shellcheck shell=bash
# aw secrets — manage the sops+age encrypted store.

cmd_secrets() {
  require_root secrets
  local sub="${1:-list}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    init)   sec_init ;;
    set)
      [[ $# -ge 1 ]] || die "usage: aw secrets set KEY [VALUE|--stdin]"
      if [[ "${2:-}" == "--stdin" ]]; then
        # Read the value from stdin so it never appears on a command line.
        sec_set_stdin "$1"
      else
        [[ $# -ge 2 ]] || die "usage: aw secrets set KEY [VALUE|--stdin]"
        sec_set "$1" "$2"
      fi ;;
    get)
      [[ $# -ge 1 ]] || die "usage: aw secrets get KEY"
      sec_get "$1" ;;
    list)   sec_list ;;
    env)
      [[ $# -ge 1 ]] || die "usage: aw secrets env DEST"
      sec_env "$1" ;;
    -h|--help) info "usage: aw secrets <init|set KEY [VALUE|--stdin]|get|list|env>" ;;
    *)      die "usage: aw secrets <init|set|get|list|env>" ;;
  esac
}
