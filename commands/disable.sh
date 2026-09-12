# shellcheck shell=bash
# aw disable — cleanly remove capabilities, respecting dependents.

_cap_enabled_dependents() {
  local target="$1" c dep
  while IFS= read -r c; do
    [[ -z "$c" || "$c" == "$target" ]] && continue
    while IFS= read -r dep; do
      [[ "$dep" == "$target" ]] && printf '%s\n' "$c"
    done < <(cap_requires "$c")
  done < <(cfg_list '.capabilities.enabled')
}

cmd_disable() {
  require_root disable
  cfg_require
  cfg_need
  [[ $# -gt 0 ]] || die "usage: aw disable <capability>..."

  local -a ordered=()
  mapfile -t ordered < <(cap_resolve "$@")

  local i cap deps
  for (( i = "${#ordered[@]}" - 1; i >= 0; i-- )); do
    cap="${ordered[i]}"
    if ! cap_is_enabled "$cap"; then
      info "$cap is not enabled"
      continue
    fi
    deps="$(_cap_enabled_dependents "$cap" | tr '\n' ' ')"
    if [[ -n "$deps" ]]; then
      warn "keeping $cap: still required by ${deps}"
      continue
    fi
    cap_uninstall "$cap"
    cfg_list_remove '.capabilities.enabled' "$cap"
  done
  ok "disable complete"
}
