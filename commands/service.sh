# shellcheck shell=bash
# aw service — operate service workloads (SYSTEM_SPEC §12.7).
#
#   aw service list
#   aw service status|logs|snapshot|backup|restore|upgrade|psql <id> [args]
#
# Every action is the same audited path an agent uses through its tools:
# the harness's alwayswork plugin calls exactly these commands.

cmd_service() {
  local action="${1:-list}" id="${2:-}"
  case "$action" in
    -h|--help|help)
      info "usage: aw service list"
      info "       aw service status|logs|snapshot|backup|restore <file>|upgrade <major>|psql <id> [args]"
      return 0 ;;
    list)
      cfg_require; cfg_need
      section "services"
      local j; j="$(wl_services_json)"
      if [[ "$j" == "[]" ]]; then info "none (enable one: aw enable services.postgres)"; return 0; fi
      jq -r '.[] | "\(.id)\t\(.name)\t\(.protocol) 127.0.0.1:\(.port)\t\(.health)"' <<<"$j" | while IFS=$'\t' read -r i n p h; do
        kv "$i" "$n · $p · $h"
      done
      return 0 ;;
  esac
  [[ -n "$id" ]] || die "usage: aw service $action <id>"
  cap_valid_id "services.$id" || die "bad service id: $id"
  cap_exists "services.$id" || die "unknown service: $id (no capability services.$id)"
  require_root "service $action"
  cfg_require; cfg_need
  shift 2
  # Each service capability provides <id>.sh with <id>_status, <id>_logs, ...
  CAP_ID="services.$id"; CAP_DIR="$(cap_dir "services.$id")"; export CAP_ID CAP_DIR
  local lib="$CAP_DIR/$id.sh"
  [[ -f "$lib" ]] || die "service $id has no operations library ($lib)"
  # shellcheck disable=SC1090
  source "$lib"
  local fn="${id}_${action}"
  declare -F "$fn" >/dev/null || die "service $id does not support '$action'"
  "$fn" "$@"
}
