# shellcheck shell=bash
# alwayswork · btrfs/snapper snapshots for safe, reversible updates.

snap_config() { cfg_get '.hardening.snapper_config' root; }
snap_available() { hw_is_btrfs && have snapper; }

snap_create() {
  local desc="$1"
  snap_available || { warn "snapshots unavailable (btrfs + snapper required)"; return 0; }
  run snapper -c "$(snap_config)" create -d "$desc"
}

snap_list() {
  snap_available || { warn "snapshots unavailable"; return 0; }
  snapper -c "$(snap_config)" list
}

snap_latest_id() {
  snap_available || return 0
  snapper -c "$(snap_config)" list --columns number,type 2>/dev/null \
    | awk '$2 ~ /pre|single/ {print $1}' | tail -1
}

snap_rollback() {
  local id="$1"
  snap_available || die "snapshots unavailable"
  [[ -n "$id" ]] || die "snapshot id required"
  log "Rolling back to snapshot $id"
  info "a reboot is required to complete the rollback"
  run snapper -c "$(snap_config)" rollback "$id"
}
