# shellcheck shell=bash
# aw decommission — remove this node from the fleet.
# Drain workloads, ask the control plane to tombstone the device identity,
# wipe local secrets, then restore the machine from the footprint ledger
# (docs/DECOMMISSION.md). Every phase is idempotent and recorded, so a failed
# or interrupted run resumes instead of redoing work. Never automatic: this
# always starts from an explicit operator decision (here, or Decommission in
# the web console, which the agent observes as device_state=draining).

cmd_decommission() {
  local local_only=0 purge=0 mode=full
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local)           local_only=1 ;;
      --purge)           purge=1 ;;
      --keep-foundation) mode=keep-foundation ;;
      --keep-agent)      mode=keep-agent ;;
      -h|--help)
        info "usage: aw decommission [--local] [--keep-foundation|--keep-agent] [--purge]"
        info "  Drain workloads, tombstone this device at the control plane, wipe"
        info "  its identity and secrets, then restore the machine from the ledger:"
        info "  firewall, SSH, packages, units and files as they were before"
        info "  alwayswork, and finally alwayswork itself. A normal PC afterwards."
        info "  --keep-foundation  keep the firewall/SSH hardening, core and aw (unenrolled)"
        info "  --keep-agent       no restore: alwayswork stays installed, ready to re-join"
        info "  --local            wipe now; the plane revocation is left to the web console"
        info "  --purge            with --keep-*: also forget the identity (aw reset --purge)"
        return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  require_root decommission
  cfg_require
  cfg_need
  section "decommission this node"
  kv "hostname" "$(hostname)"
  kv "device" "$(control_device_id)"
  kv "afterwards" "$(case "$mode" in
    full) printf 'a normal PC: everything alwayswork added is removed, including aw' ;;
    keep-foundation) printf 'hardened base and aw kept, unenrolled' ;;
    *) printf 'alwayswork kept, unenrolled (no restore)' ;;
  esac)"
  if (( local_only )); then
    warn "--local: the control plane will NOT be told; remove the node in the web console too"
  fi
  confirm "decommission '$(hostname)'? Its identity and secrets will be wiped"
  decommission_run "$local_only" "$mode" || die "decommission failed partway; re-run 'aw decommission' to resume"
  run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  if (( purge )); then
    if [[ "$mode" == "full" ]]; then
      info "--purge is implied by the full restore: nothing of alwayswork is left"
    else
      # shellcheck source=/dev/null
      source "$AW_ROOT/commands/reset.sh"
      cmd_reset --purge
    fi
  fi
  ok "node decommissioned"
}
