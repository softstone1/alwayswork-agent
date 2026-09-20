# shellcheck shell=bash
# aw config — read or set a value in /etc/alwayswork/worker.yaml.
#   aw config show                    the whole config (secrets are not in here)
#   aw config get .updates.guard      one value (yq path)
#   aw config set .updates.guard false
# Values are strings unless they parse as true/false/null/number; the
# control agent re-applies desired state over anything it owns, so use
# this for node-local knobs (.updates.*, .hardening.*, .capabilities.config.*).
cmd_config() {
  local sub="${1:-show}"; shift || true
  cfg_require
  case "$sub" in
    show) cfg_need; yq '.' "$(cfg_file)" ;;
    get)
      cfg_need
      [[ -n "${1:-}" ]] || die "usage: aw config get <path>"
      [[ "$1" == .* ]] || die "path must start with '.', e.g. .updates.guard"
      yq -r "$1" "$(cfg_file)" ;;
    set)
      require_root config
      cfg_need
      [[ -n "${1:-}" && $# -ge 2 ]] || die "usage: aw config set <path> <value>"
      [[ "$1" == .* ]] || die "path must start with '.', e.g. .updates.guard"
      local path="$1" val="$2"
      case "$val" in
        true|false|null) cfg_set_expr "$path" "$val" ;;
        *) if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then cfg_set_expr "$path" "$val"; else cfg_set_str "$path" "$val"; fi ;;
      esac
      ok "$path = $(yq -r "$path" "$(cfg_file)")" ;;
    -h|--help|help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown subcommand: config $sub (show|get|set)" ;;
  esac
}
