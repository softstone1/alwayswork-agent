# shellcheck shell=bash
# aw periderm — the detached halves of the Periderm trust roles
# (lib/periderm-trust.sh). The control agent starts these as transient units;
# they are not meant to be run by hand, except `flush`.
#   aw periderm job <workId> <attempt>     one signed build / verify / backup item
#   aw periderm watchdog <activationId>    start, probe, switch, revert (§9.4)
#   aw periderm reconcile <activationId>   load an active release's image and converge
#   aw periderm flush                      send queued results and reports now
cmd_periderm() {
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|"") info "usage: aw periderm job <workId> <attempt> | watchdog <activationId> | reconcile <activationId> | flush"; return 0 ;;
  esac
  require_root periderm
  cfg_require; cfg_need; aw_state_init
  case "$sub" in
    job)       [[ $# -eq 2 ]] || die "usage: aw periderm job <workId> <attempt>"; pd_job_run "$1" "$2" ;;
    watchdog)  [[ $# -eq 1 ]] || die "usage: aw periderm watchdog <activationId>"; pd_watchdog_run "$1" ;;
    reconcile) [[ $# -eq 1 ]] || die "usage: aw periderm reconcile <activationId>"; pd_reconcile_run "$1" ;;
    flush)     pd_outbox_flush ;;
    *) die "unknown periderm command: $sub (try: aw periderm --help)" ;;
  esac
}
