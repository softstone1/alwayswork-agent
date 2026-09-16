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

  local with_deps=0
  local -a targets=()
  local t
  for t in "$@"; do
    case "$t" in
      --with-deps) with_deps=1 ;;
      -h|--help)   info "usage: aw disable <capability>... [--with-deps]"; return 0 ;;
      --*)         die "unknown option: $t" ;;
      *)           targets+=("$t") ;;
    esac
  done
  (( "${#targets[@]}" > 0 )) || die "usage: aw disable <capability>... [--with-deps]"

  local -a ordered=()
  mapfile -t ordered < <(cap_resolve "${targets[@]}")
  if (( with_deps == 0 )); then
    # Disable only what was named. cap_resolve pulls in dependencies for
    # ordering, but uninstalling them too would cascade: disabling one
    # capability used to uninstall shared deps like core.
    local -a named=() o
    for o in "${ordered[@]}"; do
      for t in "${targets[@]}"; do
        [[ "$o" == "$t" ]] && { named+=("$o"); break; }
      done
    done
    ordered=("${named[@]}")
  fi

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
