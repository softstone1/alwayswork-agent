# shellcheck shell=bash
# alwayswork · btrfs/snapper snapshots for safe, reversible updates.

snap_config() { cfg_get '.hardening.snapper_config' root; }
snap_available() { hw_is_btrfs && have snapper; }

# snap_create <description>: prints the new snapshot's number (snapper's
# --print-number), so callers never have to parse a listing to find it.
snap_create() {
  local desc="$1" id
  snap_available || { warn "snapshots unavailable (btrfs + snapper required)"; return 0; }
  if [[ "$DRY_RUN" == "1" ]]; then run snapper -c "$(snap_config)" create -d "$desc"; return 0; fi
  id="$(snapper -c "$(snap_config)" create -d "$desc" --print-number 2>/dev/null)" || { warn "snapshot creation failed"; return 1; }
  [[ "$id" =~ ^[0-9]+$ ]] && printf '%s\n' "$id"
  return 0
}

snap_list() {
  snap_available || { warn "snapshots unavailable"; return 0; }
  snapper -c "$(snap_config)" list
}

# Newest pre/single snapshot number. Machine-readable CSV is stable across
# snapper versions; the human table changed its separators in 0.10+ (box
# drawing characters), which silently broke column parsing.
snap_latest_id() {
  snap_available || return 0
  local out
  out="$(snapper --machine-readable csv -c "$(snap_config)" list --columns number,type 2>/dev/null)" \
    && [[ -n "$out" ]] \
    && { printf '%s\n' "$out" | awk -F, 'NR > 1 && $2 ~ /^(pre|single)$/ {print $1}' | tail -1; return 0; }
  snapper -c "$(snap_config)" list --columns number,type 2>/dev/null \
    | tr '│|' '  ' | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^(pre|single)$/ {print $1}' | tail -1
}

snap_rollback() {
  local id="$1"
  snap_available || die "snapshots unavailable"
  [[ -n "$id" ]] || die "snapshot id required"
  log "Rolling back to snapshot $id"
  info "a reboot is required to complete the rollback"
  run snapper -c "$(snap_config)" rollback "$id"
}
