# shellcheck shell=bash
# aw update — snapshot, upgrade, and know exactly how to roll back.

cmd_update() {
  require_root update
  cfg_require
  cfg_need
  aw_state_init

  local snap_id=""
  if cfg_bool '.hardening.auto_snapshots' true; then
    log "Creating pre-update snapshot"
    snap_create "alwayswork pre-update $(date -Iseconds)"
    snap_id="$(snap_latest_id 2>/dev/null || true)"
    [[ -n "$snap_id" ]] && info "snapshot: $snap_id"
  fi

  log "Upgrading packages"
  local rc=0
  pkg_upgrade || rc=$?

  if (( rc != 0 )); then
    err "package upgrade failed (exit $rc)"
    if [[ -n "$snap_id" ]]; then
      info "roll back with: sudo aw snapshot rollback $snap_id (then reboot)"
    fi
    return 1
  fi

  state_set last_update "$(date -Iseconds)"
  ok "system updated"
  local kernel_now
  kernel_now="$(uname -r)"
  info "running kernel: $kernel_now"
  info "reboot if a kernel, systemd or glibc package changed"
}
