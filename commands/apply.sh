# shellcheck shell=bash
# aw apply — reconcile installed capabilities with the config.

cmd_apply() {
  require_root apply "the control agent reconciles desired state on its own; run this by hand only to converge right now"
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
    # Dependencies the desired state did not name explicitly (agents.dsh ->
    # runtime.podman) are installed and persisted too, the way `aw enable`
    # does: desired state means "this and whatever it needs".
    for c in "${ordered[@]}"; do
      cap_install "$c" || return 1
      cap_is_enabled "$c" || cfg_list_add '.capabilities.enabled' "$c"
    done
  else
    info "no capabilities enabled"
  fi

  # Stop workloads absent from the resolved desired set, retaining their data.
  # Foundation teardown remains an explicit decommission operation.
  local prior="$AW_STATE/applied-capabilities.json" old i
  local -a previous=()
  if [[ -f "$prior" ]]; then
    mapfile -t previous < <(jq -r '.[]' "$prior")
    for (( i=${#previous[@]}-1; i>=0; i-- )); do
      old="${previous[i]}"
      [[ " ${ordered[*]} " == *" $old "* ]] && continue
      cap_exists "$old" || { warn "cannot remove missing capability $old"; return 1; }
      [[ -n "$(cap_meta "$old" '.workload.id')" ]] || continue
      AW_PURGE=0 cap_uninstall "$old" || return 1
    done
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

  printf '%s\n' "${ordered[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' | aw_write "$AW_STATE/applied-capabilities.json"
  ok "applied"

  # Last, and deliberately: everything above is finished, so reloading an agent
  # that is running older code cannot interrupt a half-applied reconcile.
  aw_agent_reload_if_stale
}
