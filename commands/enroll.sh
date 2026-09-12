# shellcheck shell=bash
# aw enroll — announce this worker to a control plane and wait for approval.

cmd_enroll() {
  control_enroll "$@"
}
