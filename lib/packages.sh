# shellcheck shell=bash
# alwayswork · packages (SYSTEM_SPEC §9).
#
# A package is a versioned manifest the control plane delivers — only once
# an operator approved it, and only inside the Ed25519-signed desired state
# (`packages: [...]`). It is the one vehicle the control plane has to change
# what runs on a node; there is still no exec channel. Three kinds:
#
#   oci         any long-running container on the workload contract
#               (lib/workload.sh): pinned image, userns=auto, budget,
#               loopback publish, data subvolumes, env file, healthcheck.
#               Every published port is reported as a service, so the
#               control plane routes <node>-<name>.<base> to it.
#   capability  enable one of this agent's capabilities with its config
#               (the way `aw enable <cap> --key value` does by hand).
#   distro      apps from the curated catalog (`aw app install`).
#
# State:  $AW_STATE/packages/desired.json          the last delivered set
#         $AW_STATE/packages/installed/<name>.json {name,version,digest,kind,state,error,at}
#         $AW_STATE/workloads/<name>/<volume>      data of an oci package (kept on removal)
# The installed set rides the heartbeat as health.packages, digest included,
# so the console shows exactly which approved manifest each node runs.

pkg_dir()           { printf '%s/packages' "$AW_STATE"; }
pkg_desired_file()  { printf '%s/desired.json' "$(pkg_dir)"; }
pkg_installed_dir() { printf '%s/installed' "$(pkg_dir)"; }
pkg_root()          { printf '%s/workloads/%s' "$AW_STATE" "$1"; }
pkg_env_file()      { printf '%s/pkg-%s.env' "$AW_ETC" "$1"; }

pkg_valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }

# pkg_record <name> <version> <digest> <kind> <state> [error]
pkg_record() {
  ensure_dir "$(pkg_installed_dir)"
  jq -nc --arg n "$1" --arg v "$2" --arg d "$3" --arg k "$4" --arg s "$5" --arg e "${6:-}" --argjson at "$(( $(date +%s) * 1000 ))" \
    '{name:$n, version:$v, digest:$d, kind:$k, state:$s, at:$at} + (if $e == "" then {} else {error:$e} end)' \
    | aw_write "$(pkg_installed_dir)/$1.json"
}

# pkg_apply_from_delivery <delivery-json>: converge the node's packages to
# the delivered set. A package that fails is recorded as failed and reported;
# it never blocks the rest of the delivery (a bad image must not make a node
# retry the same desired state forever).
pkg_apply_from_delivery() {
  local json="$1" n name
  jq -e '.packages | type == "array"' >/dev/null 2>&1 <<<"$json" || return 0
  ensure_dir "$(pkg_dir)"; ensure_dir "$(pkg_installed_dir)"
  jq -c '.packages' <<<"$json" | aw_write "$(pkg_desired_file)"
  n="$(jq -r '.packages | length' <<<"$json")"
  local -a want=()
  while IFS= read -r name; do
    pkg_valid_name "$name" || { warn "packages: ignoring package with bad name '$name'"; continue; }
    want+=("$name")
    pkg_install_one "$(jq -c --arg n "$name" '.packages[] | select(.name == $n)' <<<"$json")"
  done < <(jq -r '.packages[].name' <<<"$json")
  # Installed but no longer delivered: removed (data kept).
  local f keep w
  for f in "$(pkg_installed_dir)"/*.json; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .json)"; keep=0
    for w in "${want[@]:-}"; do [[ "$w" == "$name" ]] && keep=1; done
    (( keep )) || pkg_remove_one "$name" "$(jq -r '.kind // ""' "$f" 2>/dev/null)"
  done
  (( n > 0 )) && info "packages: $n package(s) in desired state"
  return 0
}

# One package: install or update in place when the digest changed; a no-op
# otherwise (the control agent re-applies desired state on every delivery).
pkg_install_one() {
  local p="$1" name version digest kind cur
  name="$(jq -r '.name' <<<"$p")"; version="$(jq -r '.version // ""' <<<"$p")"
  digest="$(jq -r '.digest // ""' <<<"$p")"; kind="$(jq -r '.kind // ""' <<<"$p")"
  cur="$(jq -r '.digest // ""' "$(pkg_installed_dir)/$name.json" 2>/dev/null || true)"
  local curstate; curstate="$(jq -r '.state // ""' "$(pkg_installed_dir)/$name.json" 2>/dev/null || true)"
  if [[ -n "$cur" && "$cur" == "$digest" && "$curstate" == "installed" && "${PKG_FORCE:-0}" != "1" ]]; then
    # Still re-assert the workload unit for oci packages: a unit an operator
    # deleted by hand comes back, and wl_apply_unit only restarts on change.
    [[ "$kind" == "oci" ]] && { pkg_oci_apply "$p" >/dev/null 2>&1 || true; }
    return 0
  fi
  log "packages: $name@$version ($kind) $( [[ -n "$cur" ]] && echo update || echo install )"
  # Each kind runs in a subshell: a `die` inside a package (bad volume, pull
  # failure) fails that package, not the control agent.
  local errf rc=0; errf="$(mktemp)"
  case "$kind" in
    oci)        ( pkg_oci_apply "$p" ) >/dev/null 2>"$errf" || rc=$? ;;
    capability) ( pkg_capability_apply "$p" ) >/dev/null 2>"$errf" || rc=$? ;;
    distro)     ( pkg_distro_apply "$p" ) >/dev/null 2>"$errf" || rc=$? ;;
    *)          printf 'unknown package kind: %s\n' "$kind" > "$errf"; rc=2 ;;
  esac
  if (( rc != 0 )); then
    local err; err="$(grep -v '^\s*$' "$errf" | tail -n 1 | sed 's/\x1b\[[0-9;]*m//g' | head -c 256)"
    rm -f "$errf"
    warn "packages: $name@$version failed: ${err:-rc $rc}"
    pkg_record "$name" "$version" "$digest" "$kind" failed "${err:-rc $rc}"
    return 0
  fi
  rm -f "$errf"
  pkg_record "$name" "$version" "$digest" "$kind" installed
  ok "packages: $name@$version installed"
}

# --- kind: oci --------------------------------------------------------------------
# shellcheck disable=SC2034  # WL_* are the workload contract read by wl_write_unit
pkg_oci_apply() {
  local p="$1" name image root
  name="$(jq -r '.name' <<<"$p")"; image="$(jq -r '.manifest.image // ""' <<<"$p")"
  [[ "$image" =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]{1,128})?(@sha256:[a-f0-9]{64})?$ ]] || { err "packages: $name: bad image '$image'"; return 1; }
  have podman || { err "packages: $name: podman is not installed (enable runtime.podman)"; return 1; }
  root="$(pkg_root "$name")"
  wl_subvolume "$root"

  WL_NAME="$name"; WL_IMAGE="$image"; WL_DESC="package $name ($(jq -r '.version' <<<"$p"))"
  WL_PUBLISH=(); WL_VOLUMES=(); WL_LABELS=("dev.alwayswork.workload=$name" "dev.alwayswork.package=$name"); WL_TMPFS=(); WL_EXTRA=(); WL_ARGS=()
  WL_READ_ONLY="$(jq -r 'if .manifest.readOnly == true then 1 else 0 end' <<<"$p")"
  WL_HEALTH=""; WL_ENV_FILE=""; WL_NETWORK=""
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local port cport
    port="${line%%:*}"; cport="${line#*:}"
    [[ "$port" =~ ^[0-9]{1,5}$ && "$cport" =~ ^[0-9]{1,5}$ ]] || { err "packages: $name: bad publish '$line'"; return 1; }
    WL_PUBLISH+=("$port:$cport")
  done < <(jq -r '.manifest.publish[]? | "\(.port):\(.containerPort // .port)"' <<<"$p")
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local vname vpath vro
    vname="${line%%|*}"; line="${line#*|}"; vpath="${line%%|*}"; vro="${line#*|}"
    [[ "$vname" =~ ^[a-z][a-z0-9-]{0,31}$ && "$vpath" =~ ^/[A-Za-z0-9._/-]{1,200}$ ]] || { err "packages: $name: bad volume '$vname'"; return 1; }
    wl_subvolume "$root/$vname"
    WL_VOLUMES+=("$root/$vname:$vpath:$( [[ "$vro" == "true" ]] && echo ro || echo U )")
  done < <(jq -r '.manifest.volumes[]? | "\(.name)|\(.path)|\(.readOnly // false)"' <<<"$p")
  case "$(jq -r '.manifest.network // "full"' <<<"$p")" in none) WL_NETWORK=none ;; *) WL_NETWORK="" ;; esac
  local v
  v="$(jq -r '.manifest.resources.cpu // ""' <<<"$p")";      [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && WL_EXTRA+=(--cpus "$v")
  v="$(jq -r '.manifest.resources.memoryMb // ""' <<<"$p")"; [[ "$v" =~ ^[0-9]{2,7}$ ]] && WL_EXTRA+=(--memory "${v}m")
  v="$(jq -r '.manifest.resources.pids // ""' <<<"$p")";     [[ "$v" =~ ^[0-9]{2,5}$ ]] && WL_EXTRA+=(--pids-limit "$v")
  v="$(jq -r '.manifest.user // ""' <<<"$p")";               [[ "$v" =~ ^[0-9]{1,6}(:[0-9]{1,6})?$ ]] && WL_EXTRA+=(--user "$v")
  if [[ "$(jq -r '.manifest.health | type' <<<"$p")" == "array" ]]; then
    # An argv, re-quoted so podman's shell runs exactly these words.
    local -a hc=(); mapfile -t hc < <(jq -r '.manifest.health[]' <<<"$p")
    WL_HEALTH="$(printf '%q ' "${hc[@]}")"; WL_HEALTH="${WL_HEALTH% }"
  fi
  mapfile -t WL_ARGS < <(jq -r '.manifest.args[]?' <<<"$p")
  pkg_oci_render_env "$p" || return 1
  WL_ENV_FILE="$(pkg_env_file "$name")"
  wl_ensure_image "$image" || { err "packages: $name: image pull failed"; return 1; }
  wl_apply_unit
  # Every published port is a surface (SYSTEM_SPEC §12.8): the first under
  # the package name, the others as <name>-<port>; `kind` says what it is
  # for (http UI, vnc, tcp, cdp), `name` what to call it.
  local i=0 proto path id kind sname
  while IFS=$'\t' read -r port proto kind path sname; do
    [[ -n "$port" ]] || continue
    id="$name"; (( i > 0 )) && id="${name:0:25}-$port"
    [[ -n "$kind" ]] || kind="$proto"
    wl_report_surface "$name" "$id" "$kind" "$port" "$path" "${sname:-$name}"
    i=$((i + 1))
  done < <(jq -r '.manifest.publish[]? | [(.port|tostring), (.protocol // "http"), (.kind // ""), (.path // ""), (.name // "")] | @tsv' <<<"$p")
}

# The env file: plain env from the manifest, secrets by name from the sealed
# store (a missing secret is a warning — the container starts without it —
# not a failure that would loop). 0600, never on a command line.
pkg_oci_render_env() {
  local p="$1" name dest tmp k v
  name="$(jq -r '.name' <<<"$p")"; dest="$(pkg_env_file "$name")"
  if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] render %s\n' "$dest" >&2; return 0; fi
  ensure_dir "$(dirname "$dest")"
  tmp="$(mktemp "${dest}.XXXXXX")" || { err "packages: $name: cannot stage env file"; return 1; }
  chmod 600 "$tmp"
  {
    jq -r '.manifest.env // {} | to_entries[] | select(.key | test("^[A-Z][A-Z0-9_]{0,63}$")) | .key + "=" + (.value | gsub("\n"; " "))' <<<"$p"
    while IFS= read -r k; do
      [[ "$k" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || continue
      v="$(sec_get "$k" 2>/dev/null || true)"
      if [[ -n "$v" ]]; then printf '%s=%s\n' "$k" "$v"; else warn "packages: $name: secret $k is not in the sealed store"; fi
    done < <(jq -r '.manifest.secrets[]?' <<<"$p")
  } > "$tmp"
  mv -f "$tmp" "$dest"; chmod 600 "$dest"
}

# --- kind: capability ---------------------------------------------------------------
pkg_capability_apply() {
  local p="$1" name cap k v
  name="$(jq -r '.name' <<<"$p")"; cap="$(jq -r '.manifest.capability // ""' <<<"$p")"
  [[ "$cap" =~ ^[a-z][a-z0-9.-]{0,63}$ ]] || { err "packages: $name: bad capability id '$cap'"; return 1; }
  cap_exists "$cap" || { err "packages: $name: unknown capability $cap"; return 1; }
  while IFS=$'\t' read -r k v; do
    [[ "$k" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || continue
    cfg_set_str ".capabilities.config.${cap}.${k}" "$v"
  done < <(jq -r '.manifest.config // {} | to_entries[] | [.key, .value] | @tsv' <<<"$p")
  cfg_list_add '.capabilities.enabled' "$cap"
  # `aw apply` (run by the control agent right after the packages) installs it.
}

# --- kind: distro --------------------------------------------------------------------
pkg_distro_apply() {
  local p="$1" name a
  name="$(jq -r '.name' <<<"$p")"
  while IFS= read -r a; do
    [[ "$a" =~ ^[a-z0-9][a-z0-9.-]{0,63}$ ]] || continue
    app_exists "$a" || { err "packages: $name: unknown catalog app $a"; return 1; }
    cfg_list_add '.capabilities.apps' "$a"
  done < <(jq -r '.manifest.apps[]?' <<<"$p")
}

# --- removal ---------------------------------------------------------------------------
pkg_remove_one() {
  local name="$1" kind="$2"
  log "packages: $name no longer in desired state; removing ($kind)"
  case "$kind" in
    oci)
      wl_remove_unit "$name"
      local f; for f in "$(wl_services_dir)"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(jq -r '.name // ""' "$f" 2>/dev/null)" == "$name" ]] && run rm -f "$f"
      done
      run rm -f "$(pkg_env_file "$name")"
      info "packages: data of $name kept at $(pkg_root "$name")"
      ;;
    capability)
      # The capability stays unless nothing else asks for it; the control
      # agent rebuilds .capabilities.enabled from desired state on the next
      # delivery, so there is nothing to undo here.
      ;;
  esac
  run rm -f "$(pkg_installed_dir)/$name.json"
}

# --- reporting --------------------------------------------------------------------------
pkg_reports_json() {
  local d out; d="$(pkg_installed_dir)"
  local -a files=()
  [[ -d "$d" ]] && for f in "$d"/*.json; do [[ -f "$f" ]] && files+=("$f"); done
  (( ${#files[@]} )) || { printf '[]'; return 0; }
  # Capture, then print once: jq -s prints [] before failing on a bad file,
  # and a doubled value breaks the whole health report (--argjson).
  out="$(jq -sc '[.[] | {name, version, digest, state} + (if .error then {error} else {} end)]' "${files[@]}" 2>/dev/null)" || out=""
  [[ "$out" == \[* ]] && printf '%s' "$out" || printf '[]'
}

pkg_status() {
  section "packages"
  local d f; d="$(pkg_installed_dir)"
  if [[ ! -d "$d" ]] || ! ls "$d"/*.json >/dev/null 2>&1; then info "no packages delivered to this node"; return 0; fi
  for f in "$d"/*.json; do
    kv "$(jq -r '.name' "$f")" "$(jq -r '"\(.version)  \(.kind)  \(.state)\(if .error then "  — " + .error else "" end)"' "$f")"
  done
}
