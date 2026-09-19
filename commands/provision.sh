# shellcheck shell=bash
# aw provision — first-boot / headless provisioning entry point.
# Runs on every boot via alwayswork-provision.timer. Each run is cheap and
# idempotent: an enrolled node exits immediately (a token-enrolled node still
# awaiting approval polls once), a decommissioned node stays put until
# explicitly rejoined, otherwise USB provisioning wins and a pending claim is
# created or checked exactly once (the timer retries; a udev rule also fires
# it when a USB stick is plugged in).

cmd_provision() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) info "usage: aw provision"; info "  First-boot provisioning: resume decommission, USB enroll, or pending claim."; return 0 ;;
      *) die "unknown option: $arg" ;;
    esac
  done
  require_root provision
  # 1. Resume an interrupted decommission first — never provision a node that
  #    is half-removed.
  if decommission_in_progress; then
    log "provision: resuming an interrupted decommission"
    # The marker pins the restore mode chosen when the run started; a marker
    # without one predates the ledger, and its run keeps the old behaviour.
    decommission_run 0 keep-agent || die "provision: decommission resume failed; will retry next boot"
    run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
    return 0
  fi
  # 2. Enrolled with a token but still waiting for the console click: one
  #    bounded poll; on approval the first delivery is applied and the agent
  #    starts.
  if control_enrolled && control_pending; then
    control_enroll_resume_once || true
    return 0
  fi
  # 3. Already a node: nothing to do; the timer has served its purpose.
  if control_enrolled; then
    run systemctl disable --now alwayswork-provision.timer 2>/dev/null || true
    return 0
  fi
  # 4. USB provisioning wins — also the rejoin path after a decommission.
  local toml
  if toml="$(control_usb_find_provision 2>/dev/null)"; then
    log "provision: USB provisioning file found"
    if control_usb_apply "$toml"; then
      control_usb_consume "$toml"
      return 0
    fi
    die "provision: USB provisioning failed"
  fi
  # 5. A decommissioned node stays unenrolled until the operator acts.
  if decommission_completed; then
    info "provision: node was decommissioned; plug a USB provisioning stick or run 'aw enroll' to rejoin"
    return 0
  fi
  # 6. Pending claim: register if needed, check once, never block.
  control_claim_poll_once || true
}
