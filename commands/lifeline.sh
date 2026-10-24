# shellcheck shell=bash
# aw lifeline — agent recovery, run by alwayswork-lifeline.timer (lib/lifeline.sh).

cmd_lifeline() {
  case "${1:-}" in -h|--help) info "usage: aw lifeline   (run by alwayswork-lifeline.timer every two minutes)"; return 0 ;; esac
  require_root lifeline
  cfg_require
  lifeline_run
}
