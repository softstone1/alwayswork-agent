# shellcheck shell=bash
# aw decommission — remove this node from the fleet.
# Drain workloads, ask the control plane to tombstone the device identity,
# then wipe local secrets. Every phase is idempotent and recorded, so a failed
# or interrupted run resumes instead of redoing work. Never automatic: this
# always starts from an explicit operator decision (here, or Decommission in
# the web console, which the agent observes as device_state=draining).

cmd_decommission() {
  local local_only=0 purge=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local) local_only=1 ;;
      --purge) purge=1 ;;
      -h|--help)
        info "usage: aw decommission [--local] [--purge]"
        info "  Drain workloads, tombstone this device at the control plane,"
        info "  then wipe its identity and secrets. The OS and alwayswork stay"
        info "  installed but unenrolled, ready to be claimed again."
        info "  --local  wipe now; the plane revocation is left to the web console"
        info "  --purge  afterwards also forget the identity (aw reset --purge)"
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
  if (( local_only )); then
    warn "--local: the control plane will NOT be told; remove the node in the web console too"
  fi
  confirm "decommission '$(hostname)'? Its identity and secrets will be wiped"
  decommission_run "$local_only" || die "decommission failed partway; re-run 'aw decommission' to resume"
  run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  if (( purge )); then
    # shellcheck source=/dev/null
    source "$AW_ROOT/commands/reset.sh"
    cmd_reset --purge
  fi
  ok "node decommissioned"
}
