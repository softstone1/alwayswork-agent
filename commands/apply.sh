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
  (( "${#caps[@]}" > 0 )) || { ok "no capabilities enabled"; return 0; }
  mapfile -t ordered < <(cap_resolve "${caps[@]}")
  local c
  for c in "${ordered[@]}"; do cap_install "$c"; done
  ok "applied"
}
