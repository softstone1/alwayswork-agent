# shellcheck shell=bash
# alwayswork · capability discovery, resolution and lifecycle.
#
# A capability is a directory with a manifest.yaml, an optional install.sh
# and uninstall.sh, and optional preflight.sh / healthcheck.sh hooks. Hooks
# are sourced with CAP_ID and CAP_DIR exported; they may call any lib
# helper (cfg_get, engine_run, fw_allow_port, ...).

cap_search_dirs() {
  printf '%s\n' "$AW_ROOT/capabilities"
  [[ -d "$AW_CAP_USER_DIR" ]] && printf '%s\n' "$AW_CAP_USER_DIR"
}

cap_dir() {
  local id="$1" d
  while IFS= read -r d; do
    if [[ -f "$d/$id/manifest.yaml" ]]; then printf '%s\n' "$d/$id"; return 0; fi
  done < <(cap_search_dirs)
  return 1
}

cap_manifest() { printf '%s\n' "$(cap_dir "$1")/manifest.yaml"; }
cap_exists()   { cap_dir "$1" >/dev/null 2>&1; }

cap_meta() {
  yq -r "$2 // \"\"" "$(cap_manifest "$1")" 2>/dev/null || true
}

cap_ids() {
  local d
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null
  done < <(cap_search_dirs) | sort -u
}

cap_description() { cap_meta "$1" '.description'; }
cap_requires()    { yq -r '.requires // [] | .[]' "$(cap_manifest "$1")" 2>/dev/null || true; }

cap_is_enabled() { cfg_list '.capabilities.enabled' | grep -qx -- "$1"; }

# Capability-scoped config: cap_config <key>
cap_config() { cfg_get ".capabilities.config.${CAP_ID}.$1" "${2:-}"; }

# --- dependency resolution (topological, deps first) ------------------------
_AW_CAP_ORDER=()
_AW_CAP_SEEN=" "

_cap_visit() {
  local id="$1" dep
  [[ "$_AW_CAP_SEEN" == *" $id "* ]] && return 0
  cap_exists "$id" || die "unknown capability: $id"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    _cap_visit "$dep"
  done < <(cap_requires "$id")
  _AW_CAP_SEEN="${_AW_CAP_SEEN}${id} "
  _AW_CAP_ORDER+=("$id")
}

cap_resolve() {
  _AW_CAP_ORDER=(); _AW_CAP_SEEN=" "
  local id
  for id in "$@"; do _cap_visit "$id"; done
  (( "${#_AW_CAP_ORDER[@]}" > 0 )) && printf '%s\n' "${_AW_CAP_ORDER[@]}"
}

# --- hooks ------------------------------------------------------------------
cap_script()     { printf '%s\n' "$(cap_dir "$1")/$2.sh"; }
cap_have_hook()  { [[ -f "$(cap_script "$1" "$2")" ]]; }

cap_run_hook() {
  local id="$1" hook="$2"
  cap_have_hook "$id" "$hook" || return 0
  CAP_ID="$id"
  CAP_DIR="$(cap_dir "$id")"
  export CAP_ID CAP_DIR
  # shellcheck disable=SC1090
  (
    aw_cap_hook() { source "$(cap_script "$id" "$hook")"; }
    aw_cap_hook
  )
}

cap_preflight() {
  local id="$1" dep
  cap_exists "$id" || die "unknown capability: $id"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    cap_is_enabled "$dep" || die "capability '$id' requires '$dep' (enable it first)"
  done < <(cap_requires "$id")
}

cap_install() {
  local id="$1"
  log "Installing capability: $id"
  cap_preflight "$id"
  cap_run_hook "$id" preflight
  cap_run_hook "$id" install
  ok "$id installed"
}

cap_uninstall() {
  local id="$1"
  log "Removing capability: $id"
  cap_run_hook "$id" uninstall
  ok "$id removed"
}

cap_health() { cap_run_hook "$1" healthcheck; }

# --- out-of-tree capabilities ----------------------------------------------
cap_add() {
  local src="$1"
  [[ -f "$src/manifest.yaml" ]] || die "$src is not a capability (missing manifest.yaml)"
  local id; id="$(yq -r '.id' "$src/manifest.yaml")"
  [[ -n "$id" && "$id" != "null" ]] || die "manifest has no id"
  ensure_dir "$AW_CAP_USER_DIR"
  run cp -a "$src" "$AW_CAP_USER_DIR/$id"
  ok "registered capability '$id' from $src"
}
