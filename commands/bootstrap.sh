# shellcheck shell=bash
# aw bootstrap — secure the machine and install the foundation profile.

apply_ssh_policy() {
  local policy; policy="$(cfg_get '.hardening.ssh' disabled)"
  case "$policy" in
    disabled)
      if systemctl is-enabled --quiet sshd 2>/dev/null; then
        log "Disabling SSH (policy: disabled)"
        run systemctl disable --now sshd 2>/dev/null || true
      else
        ok "SSH already disabled"
      fi
      ;;
    tailscale)
      warn "SSH policy 'tailscale' expects access.tailscale to manage sshd"
      ;;
    lan)
      warn "SSH policy 'lan' leaves sshd enabled; bind it to the LAN interface"
      ;;
    *)
      warn "unknown hardening.ssh policy: $policy"
      ;;
  esac
}

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

  section "Anakut Worker bootstrap"
  hw_report

  if ! hw_is_arch; then
    warn "this does not look like an Arch-based system; continue with care"
  fi
  if ! hw_is_btrfs; then
    warn "root is not btrfs; snapshot/rollback will be unavailable"
  fi

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
