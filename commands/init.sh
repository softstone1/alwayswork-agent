# shellcheck shell=bash
# aw init — write the desired-state config.

cmd_init() {
  local profile="foundation" name="" tz="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) [[ -n "${2-}" ]] || die "missing value for --profile"; profile="$2"; shift ;;
      --name)    [[ -n "${2-}" ]] || die "missing value for --name";    name="$2"; shift ;;
      --timezone|--tz) [[ -n "${2-}" ]] || die "missing value for $1"; tz="$2"; shift ;;
      --force)   force=1 ;;
      -h|--help) info "usage: aw init [--profile P] [--name N] [--timezone TZ] [--force]"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  require_root init
  cfg_require
  name="${name:-$(hostname)}"
  tz="${tz:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
  if cfg_exists && [[ "$force" != "1" ]]; then
    info "config already exists at $(cfg_file)"
    info "re-run with --force to overwrite"
    return 0
  fi
  aw_state_init
  cfg_render "$profile" "$name" "$tz"
  ok "wrote $(cfg_file) (profile: $profile)"
  info "edit it if needed, then run: aw bootstrap"
}
