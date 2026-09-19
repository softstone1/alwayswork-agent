# shellcheck shell=bash
# aw bridge — serve the harness's allowlisted requests (lib/objectives.sh).
#   aw bridge --once      what alwayswork-bridge.path fires
cmd_bridge() {
  case "${1:-}" in
    --once|"") ;;
    -h|--help) info "usage: aw bridge --once"; return 0 ;;
    *) die "unknown option: $1" ;;
  esac
  require_root bridge
  cfg_require; cfg_need; aw_state_init
  obj_bridge_serve_once
}
