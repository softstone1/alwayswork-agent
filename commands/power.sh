# shellcheck shell=bash
# aw power — headless / always-on power policy.

cmd_power() {
  local sub="${1:-status}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    status)      cfg_require; power_status ;;
    apply)       require_root power; cfg_require; cfg_need; power_apply ;;
    off|disable) require_root power; cfg_require; cfg_need; power_unapply ;;
    -h|--help)   info "usage: aw power <status|apply|off>" ;;
    *)           die "usage: aw power <status|apply|off>" ;;
  esac
}
