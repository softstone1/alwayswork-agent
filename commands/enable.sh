# shellcheck shell=bash
# aw enable — install and persist one or more capabilities (with dependencies).
#
#   aw enable runtime.docker
#   aw enable access.tunnel --domain worker.example.com
#
# Options after the capability names are stored under
# .capabilities.config.<capability>.<key>.

cmd_enable() {
  require_root enable
  cfg_require
  cfg_need
  aw_state_init

  local -a caps=() opts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        info "usage: aw enable <capability>... [--key value]..."
        return 0
        ;;
      --*)
        opts+=("$1")
        if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then
          opts+=("$2"); shift
        fi
        ;;
      *) caps+=("$1") ;;
    esac
    shift
  done

  (( "${#caps[@]}" > 0 )) || die "usage: aw enable <capability>..."

  if (( "${#opts[@]}" > 0 )); then
    local c i k v
    for c in "${caps[@]}"; do
      i=0
      while (( i < "${#opts[@]}" )); do
        k="${opts[i]#--}"
        v="${opts[i+1]:-true}"
        cfg_set_str ".capabilities.config.${c}.${k}" "$v"
        i=$(( i + 2 ))
      done
    done
  fi

  local -a ordered=()
  mapfile -t ordered < <(cap_resolve "${caps[@]}")
  local cap
  for cap in "${ordered[@]}"; do
    if cap_is_enabled "$cap"; then
      info "$cap already enabled (re-applying)"
    fi
    cap_install "$cap"
    cfg_list_add '.capabilities.enabled' "$cap"
  done
  ok "enabled: ${caps[*]}"
}
