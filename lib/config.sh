# shellcheck shell=bash
# alwayswork · desired-state config (worker.yaml) read/write via yq.

cfg_require() { [[ "$DRY_RUN" == "1" ]] && return 0; require_cmd yq; }
cfg_file()    { printf '%s\n' "$AW_CONFIG"; }
cfg_exists()  { [[ -f "$(cfg_file)" ]]; }
cfg_defaults(){ printf '%s\n' "$AW_ROOT/config/defaults.yaml"; }

cfg_need() {
  cfg_exists || die "no config at $(cfg_file); run: aw init"
}

cfg_get() {
  cfg_need
  local path="$1" default="${2:-}" v
  v="$(yq -r "$path" "$(cfg_file)" 2>/dev/null || true)"
  if [[ -z "$v" || "$v" == "null" ]]; then printf '%s\n' "$default"; else printf '%s\n' "$v"; fi
}

cfg_bool() {
  [[ "$(cfg_get "$1" "${2:-false}")" == "true" ]]
}

cfg_set_expr() {
  local path="$1" expr="$2"
  cfg_need
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] set %s = %s\n' "$path" "$expr" >&2; return 0
  fi
  yq -i "$path = $expr" "$(cfg_file)"
}

cfg_set_str() {
  local path="$1" val="$2"
  cfg_need
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] set %s = %s\n' "$path" "$val" >&2; return 0
  fi
  AW_VAL="$val" yq -i "$path = strenv(AW_VAL)" "$(cfg_file)"
}

cfg_list() {
  cfg_need
  yq -r "$1 // [] | .[]" "$(cfg_file)" 2>/dev/null || true
}

cfg_list_has() {
  cfg_list "$1" | grep -qx -- "$2"
}

cfg_list_add() {
  local path="$1" item="$2"
  cfg_list_has "$path" "$item" && return 0
  cfg_need
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] add %s to %s\n' "$item" "$path" >&2; return 0
  fi
  AW_ITEM="$item" yq -i "$path += [strenv(AW_ITEM)]" "$(cfg_file)"
}

cfg_list_remove() {
  local path="$1" item="$2"
  cfg_need
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] remove %s from %s\n' "$item" "$path" >&2; return 0
  fi
  AW_ITEM="$item" yq -i "$path -= [strenv(AW_ITEM)]" "$(cfg_file)"
}

# Render worker.yaml from defaults + a profile.
cfg_render() {
  local profile="$1" name="${2:-$(hostname)}" tz="${3:-UTC}"
  local defs profile_file
  defs="$(cfg_defaults)"
  profile_file="$AW_ROOT/profiles/$profile.yaml"
  [[ -f "$profile_file" ]] || die "unknown profile: $profile (see profiles/)"
  ensure_dir "$AW_ETC"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] render %s from profile %s\n' "$(cfg_file)" "$profile" >&2
    return 0
  fi
  cp "$defs" "$(cfg_file)"
  cfg_set_str '.name' "$name"
  cfg_set_str '.profile' "$profile"
  cfg_set_str '.timezone' "$tz"
  AW_PROFILE_FILE="$profile_file" yq -i '
    .capabilities.enabled = (load(strenv(AW_PROFILE_FILE)).capabilities)
  ' "$(cfg_file)"
}
