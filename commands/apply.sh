# shellcheck shell=bash
# aw apply — reconcile installed capabilities with the config.

cmd_apply() {
  require_root apply
  cfg_require
  cfg_need
  aw_state_init
  log "Reconciling to $(cfg_file)"

  if cfg_bool '.hardening.firewall' true; then
    fw_ensure || warn "firewall was not configured"
  fi

  power_apply


  local -a caps=() ordered=()
  mapfile -t caps < <(cfg_list '.capabilities.enabled')
  if (( "${#caps[@]}" > 0 )); then
    mapfile -t ordered < <(cap_resolve "${caps[@]}")
    local c
    for c in "${ordered[@]}"; do cap_install "$c"; done
  else
    info "no capabilities enabled"
  fi

  # Apps are part of the desired state the control plane delivers, so a node is
  # fully provisioned by enrollment + apply with no extra manual step.
  local -a apps=()
  mapfile -t apps < <(cfg_list '.capabilities.apps')
  if (( "${#apps[@]}" > 0 )); then
    local a
    for a in "${apps[@]}"; do
      if app_exists "$a"; then app_install "$a"; else warn "unknown app in desired state: $a"; fi
    done
  fi

  ok "applied"
}
