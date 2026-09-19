# shellcheck shell=bash
# aw update — snapshot, upgrade, gate on health, and know how to roll back.
#
#   aw update [--yes] [--rollout <id>]   snapshot -> upgrade -> health gate
#                                         (undo from the snapshot on failure)
#                                         -> boot probation
#   aw update --guard                     package-manager hook: allowed?
#   aw update --boot-check                after boot: verify or roll back
# See lib/updates.sh and docs/UPDATES.md (SYSTEM_SPEC §13.1).

cmd_update() {
  local rollout="" mode="update"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --guard)      mode="guard" ;;
      --boot-check) mode="boot-check" ;;
      --rollout)    [[ -n "${2-}" ]] || die "missing value for --rollout"; rollout="$2"; shift ;;
      -h|--help)    info "usage: aw update [--yes] [--rollout <id>] | --guard | --boot-check"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  case "$mode" in
    guard)      upd_guard; return $? ;;
    boot-check) require_root update; cfg_require; cfg_need; aw_state_init; upd_boot_check; return $? ;;
  esac

  require_root update
  cfg_require
  cfg_need
  aw_state_init
  upd_lock

  local snap_id=""
  if cfg_bool '.hardening.auto_snapshots' true; then
    log "Creating pre-update snapshot"
    snap_create "alwayswork pre-update $(date -Iseconds)"
    snap_id="$(snap_latest_id 2>/dev/null || true)"
    [[ -n "$snap_id" ]] && info "snapshot: $snap_id"
  fi
  [[ -n "$rollout" ]] && upd_record_result running "upgrading (rollout $rollout)"

  log "Upgrading packages"
  local rc=0
  pkg_upgrade || rc=$?
  if (( rc != 0 )); then
    err "package upgrade failed (exit $rc)"
    upd_record_result failed "package upgrade failed (exit $rc)"
    [[ -n "$snap_id" ]] && info "roll back with: sudo aw snapshot rollback $snap_id (then reboot)"
    return 1
  fi
  state_set last_update "$(date -Iseconds)"

  # The gate: a node that upgraded but cannot heartbeat, lost its tunnel or
  # fails doctor is not "updated", it is broken. Undo and try the gate again.
  if ! upd_health_gate; then
    if upd_undo_to_snapshot "$snap_id" && upd_health_gate; then
      upd_record_result rolled_back "unhealthy after upgrade; files restored from snapshot $snap_id"
      warn "update: rolled back to snapshot $snap_id (files); the upgrade is NOT applied"
      return 1
    fi
    upd_record_result failed "unhealthy after upgrade and undo did not help"
    err "update: node unhealthy after upgrade; investigate (snapshot $snap_id)"
    return 1
  fi

  # Healthy now; the next boots re-check (kernel, systemd, glibc changes only
  # bite after a reboot) and roll back if the box comes up broken twice.
  upd_probation_start "$snap_id" "$rollout"
  upd_record_result ok "updated; on boot probation"
  ok "system updated (on probation until the next boot verifies)"
  info "running kernel: $(uname -r)"
  info "reboot if a kernel, systemd or glibc package changed; the boot check rolls back if it goes wrong"
}
