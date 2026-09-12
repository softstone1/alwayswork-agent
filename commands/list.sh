# shellcheck shell=bash
# aw list — show the capability catalog.

cmd_list() {
  cfg_require
  local mode="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --available) mode="available" ;;
      --all)       mode="all" ;;
      -h|--help)   info "usage: aw list [--available]"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  printf '%s%-24s %-10s %s%s\n' "$C_BOLD" "CAPABILITY" "STATE" "DESCRIPTION" "$C_RESET"
  local id state desc
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    state="available"
    if cfg_exists && cap_is_enabled "$id"; then state="enabled"; fi
    [[ "$mode" == "available" && "$state" != "available" ]] && continue
    desc="$(cap_description "$id")"
    printf '%-24s %-10s %s\n' "$id" "$state" "$desc"
  done < <(cap_ids)
  printf '\n%sEnable with: aw enable <capability>%s\n' "$C_DIM" "$C_RESET"
}
