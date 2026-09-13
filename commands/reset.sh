# shellcheck shell=bash
# aw reset — forget this worker's control identity so it can join again.

cmd_reset() {
  local purge=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge)   purge=1 ;;
      -h|--help) info "usage: aw reset [--purge]"; return 0 ;;
      *)         die "unknown option: $1" ;;
    esac
    shift
  done
  require_root reset
  log "Resetting this worker's control identity"

  if systemctl list-unit-files alwayswork-agent.service >/dev/null 2>&1; then
    run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  fi
  if systemctl list-unit-files alwayswork-webui.service >/dev/null 2>&1; then
    info "the node web UI keeps running; disable it with: aw disable agents.dsh"
  fi

  run rm -f "$(control_config_file)"
  if (( purge )); then
    # A fresh identity is the point of a purge: the next enroll announces a new
    # device key, so the control plane sees a genuinely new node.
    run rm -f "$(control_key_file)"
    run rm -f "$AW_STATE/webui.json"
    info "removed the device identity as well"
  fi
  ok "reset complete"
  info "re-join with: aw enroll --control <url> --token <join-token>"
}
