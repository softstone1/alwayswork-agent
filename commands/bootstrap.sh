# shellcheck shell=bash
# aw bootstrap — secure the machine and install the foundation profile.
#
# The SSH hardening policy itself lives in lib/hardening.sh (apply_ssh_policy),
# shared with the control agent's deferred lockdown.

cmd_bootstrap() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) info "usage: aw bootstrap [--yes]"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  require_root bootstrap
  cfg_require
  cfg_need
  aw_state_init

  section "AlwaysWork bootstrap"
  hw_report

  if ! hw_is_btrfs; then
    warn "root is not btrfs; snapshot/rollback will be unavailable"
  fi

  case "$(distro_family)" in
    arch)   : ;;
    debian) info "Debian-family system detected ($(distro_pretty)); using apt" ;;
    *)      warn "unsupported distribution '$(distro_id)'; continuing with care" ;;
  esac

  if cfg_bool '.hardening.firewall' true; then
    log "Configuring firewall (default deny inbound)"
    fw_ensure || warn "firewall was not configured"
  fi

  apply_ssh_policy

  if [[ "$(sec_backend)" == "sops" ]]; then
    log "Initialising encrypted secret store"
    sec_init
  else
    warn "sops/age not installed; skipping secret store"
  fi

  local -a caps=()
  mapfile -t caps < <(cfg_list '.capabilities.enabled')
  if (( "${#caps[@]}" > 0 )); then
    log "Installing ${#caps[@]} enabled capability(ies)"
    local -a ordered=()
    mapfile -t ordered < <(cap_resolve "${caps[@]}")
    local c
    for c in "${ordered[@]}"; do cap_install "$c"; done
  fi

  state_set bootstrap_date "$(date -Iseconds)"
  ok "bootstrap complete"
  info "run 'aw doctor' for the security audit"
}
