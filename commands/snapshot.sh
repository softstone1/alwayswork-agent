# shellcheck shell=bash
# aw snapshot — list, create and roll back btrfs snapshots.

cmd_snapshot() {
  require_root snapshot
  local sub="${1:-list}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    list)     snap_list ;;
    create)   snap_create "${1:-manual snapshot $(date -Iseconds)}" ;;
    rollback) snap_rollback "${1:-}" ;;
    -h|--help) info "usage: aw snapshot <list|create|rollback> [arg]"; return 0 ;;
    *)        die "usage: aw snapshot <list|create|rollback> [arg]" ;;
  esac
}
