# shellcheck shell=bash
# alwayswork · the workload container contract (SYSTEM_SPEC §12).
#
# Every workload — an agent harness, a database, any long-running service —
# is ONE rootful Podman container under a system unit, built the same way:
#   - userns=auto: container root is an unused, unprivileged host uid range
#   - cap-drop ALL, no-new-privileges, pids/cpu/memory budget from .limits
#   - data on subvolumes under $AW_STATE (btrfs where the host has it)
#   - published to 127.0.0.1 only; the tunnel remains the public path
#   - secrets via a 0600 env file, never on a command line
#   - a healthcheck systemd restarts on; state reported on heartbeat
# Capabilities describe their workload through the WL_* variables below
# and call wl_write_unit / wl_apply_unit. agents.dsh and services.* share
# this file; nothing here knows what runs inside.

WL_UNIT_DIR="${AW_SYSTEMD_DIR:-/etc/systemd/system}"

# --- storage ---------------------------------------------------------------------
# A btrfs subvolume where the host has btrfs (snapshots come for free), a
# plain directory otherwise. Idempotent.
wl_subvolume() {
  local p="$1"
  ensure_dir "$(dirname "$p")"
  [[ -d "$p" ]] && return 0
  if hw_is_btrfs && have btrfs && [[ "$(findmnt -no FSTYPE --target "$(dirname "$p")" 2>/dev/null)" == "btrfs" ]]; then
    log "workload: creating btrfs subvolume $p"
    run btrfs subvolume create "$p" >/dev/null || run mkdir -p "$p"
  else
    run mkdir -p "$p"
  fi
}

# Read-only snapshot of a subvolume into <parent>/.snapshots/<stamp>[-label].
# Prints the snapshot path. Off btrfs: a warning and no snapshot (dumps are
# the safety net there).
wl_snapshot() {
  local p="$1" label="${2:-manual}" dir stamp dest
  dir="$(dirname "$p")/.snapshots"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$dir/${stamp}-${label}"
  if ! have btrfs || [[ "$(findmnt -no FSTYPE --target "$p" 2>/dev/null)" != "btrfs" ]]; then
    warn "workload: $p is not on btrfs; no snapshot taken (use backup instead)"
    return 1
  fi
  ensure_dir "$dir"
  run btrfs subvolume snapshot -r "$p" "$dest" >/dev/null || return 1
  printf '%s\n' "$dest"
}

# --- image ---------------------------------------------------------------------------
# Pull a pinned image; when a Containerfile directory is given and the pull
# fails, build the identical file locally.
wl_ensure_image() {
  local img="$1" build_dir="${2:-}"; shift 2 || true
  [[ "$img" =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "workload: refusing suspicious image '$img'"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "workload: dry-run — would pull $img${build_dir:+ (or build $build_dir)}"
    return 0
  fi
  if podman image exists "$img" 2>/dev/null && [[ "${WL_PULL:-}" != "always" ]]; then
    ok "image present: $img"; return 0
  fi
  if [[ "${WL_BUILD:-}" != "true" ]]; then
    log "workload: pulling $img"
    if run podman pull "$img" >/dev/null; then ok "pulled $img"; return 0; fi
    [[ -n "$build_dir" ]] || die "workload: could not pull $img"
    warn "workload: pull failed; building the same image locally"
  fi
  [[ -n "$build_dir" ]] || die "workload: no Containerfile to build $img from"
  run podman build --pull=newer -t "$img" "$@" -f "$build_dir/Containerfile" "$build_dir" >/dev/null \
    || die "workload: image build failed"
  ok "built $img"
}

# --- the unit --------------------------------------------------------------------------
# Inputs (set by the capability before calling):
#   WL_NAME        container + unit stem (alwayswork-<name>)
#   WL_IMAGE       pinned image
#   WL_DESC        unit description
#   WL_PUBLISH     array of host:container ports, e.g. (3080:3080); loopback only
#   WL_VOLUMES     array of "host:container[:opts]" mounts
#   WL_ENV_FILE    0600 env file (optional)
#   WL_LABELS      array of key=value labels
#   WL_READ_ONLY   1 = read-only rootfs with a tmpfs /tmp (harnesses); 0 = writable (databases)
#   WL_TMPFS       array of extra tmpfs mounts, e.g. (/run/postgresql)
#   WL_HEALTH      healthcheck command inside the container (optional)
#   WL_EXTRA       array of extra podman flags (e.g. --shm-size 256m)
#   WL_NETWORK     "" (the node's `alwayswork` network) | none | <name>
#   WL_ARGS        array of arguments after the image (optional)
# systemd quoting, not shell quoting: bare when safe, else double quotes with
# backslash and double-quote escaped (systemd.syntax(7) "Quoting").
wl_q() {
  local a="$1"
  if [[ "$a" =~ ^[A-Za-z0-9_./:=@,+%-]+$ ]]; then printf '%s' "$a"
  else a="${a//\\/\\\\}"; a="${a//\"/\\\"}"; printf '"%s"' "$a"; fi
}
wl_qs() { local out="" a; for a in "$@"; do out+="$(wl_q "$a") "; done; printf '%s' "$out"; }

wl_unit_name() { printf 'alwayswork-%s.service' "$1"; }
wl_container()  { printf 'alwayswork-%s' "$1"; }

wl_write_unit() {
  local unit container podman_bin flags v
  unit="$(wl_unit_name "$WL_NAME")"; container="$(wl_container "$WL_NAME")"
  podman_bin="$(command -v podman || echo /usr/bin/podman)"
  engine_build_args
  local -a iso=(--userns=auto)
  if [[ "${WL_READ_ONLY:-0}" == "1" ]]; then iso+=(--read-only --tmpfs "/tmp:rw,nosuid,size=512m"); fi
  for v in "${WL_TMPFS[@]:-}"; do [[ -n "$v" ]] && iso+=(--tmpfs "$v"); done
  case "${WL_NETWORK:-}" in
    none) iso+=(--network none) ;;
    "")   iso+=(--network alwayswork) ;;
    *)    iso+=(--network "$WL_NETWORK") ;;
  esac
  if [[ -n "${WL_HEALTH:-}" ]]; then
    iso+=(--health-cmd "$WL_HEALTH" --health-interval 30s --health-retries 3 --health-start-period 60s)
    # A failing healthcheck stops the container; systemd then restarts it.
    iso+=(--health-on-failure=stop)
  fi
  for v in "${WL_PUBLISH[@]:-}"; do [[ -n "$v" ]] && iso+=(--publish "127.0.0.1:$v"); done
  for v in "${WL_VOLUMES[@]:-}"; do [[ -n "$v" ]] && iso+=(--volume "$v"); done
  [[ -n "${WL_ENV_FILE:-}" ]] && iso+=(--env-file "$WL_ENV_FILE")
  for v in "${WL_LABELS[@]:-}"; do [[ -n "$v" ]] && iso+=(--label "$v"); done
  for v in "${WL_EXTRA[@]:-}"; do [[ -n "$v" ]] && iso+=("$v"); done
  flags="$(wl_qs "${AW_ENGINE_ARGS[@]}" "${iso[@]}")"
  local args=""; [[ -n "${WL_ARGS[*]:-}" ]] && args="$(wl_qs "${WL_ARGS[@]}")"
  aw_write "$WL_UNIT_DIR/$unit" <<UNIT
[Unit]
Description=AlwaysWork workload: ${WL_DESC}
Documentation=https://github.com/softstone1/alwayswork-agent
After=network-online.target
Wants=network-online.target
# Managed by alwayswork (lib/workload.sh). Image: ${WL_IMAGE}

[Service]
Type=notify
NotifyAccess=all
Restart=always
RestartSec=5
TimeoutStartSec=300
TimeoutStopSec=60
ExecStartPre=-${podman_bin} rm -f ${container}
ExecStart=${podman_bin} run --rm --replace --sdnotify=conmon --name ${container} \\
  ${flags}\\
  ${WL_IMAGE} ${args}
ExecStop=${podman_bin} stop -t 30 ${container}

[Install]
WantedBy=multi-user.target
UNIT
}

# Write the unit and (re)start only when it changed or is not running: the
# control agent re-applies desired state on every delivery and must not
# bounce a healthy database or a live agent session.
wl_apply_unit() {
  local unit path before="" after=""
  unit="$(wl_unit_name "$WL_NAME")"; path="$WL_UNIT_DIR/$unit"
  [[ -f "$path" ]] && before="$(sha256sum "$path" | cut -d' ' -f1)"
  wl_write_unit
  [[ -f "$path" && "$DRY_RUN" != "1" ]] && after="$(sha256sum "$path" | cut -d' ' -f1)"
  run systemctl daemon-reload
  run systemctl enable "$unit"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "workload: dry-run — would (re)start $unit"
  elif [[ "$before" != "$after" ]] || ! systemctl is-active --quiet "$unit"; then
    run systemctl restart "$unit"
  else
    info "workload: $unit unchanged; container left running"
  fi
}

wl_remove_unit() {
  local unit; unit="$(wl_unit_name "$1")"
  run systemctl disable --now "$unit" 2>/dev/null || true
  run rm -f "$WL_UNIT_DIR/$unit"
  run systemctl daemon-reload
  if have podman; then run podman rm -f "$(wl_container "$1")" 2>/dev/null || true; fi
}

# --- reporting ------------------------------------------------------------------------------
# Each exposed service writes $AW_STATE/services/<id>.json:
#   {"id","name","protocol":"http"|"tcp","port",("path")}
# The control agent sends the set on heartbeat as expose.services (§5.2); the
# control plane adds <id>-<node>.<base> to the node's tunnel.
wl_services_dir() { printf '%s' "$AW_STATE/services"; }

wl_report_service() {
  local id="$1" name="$2" protocol="$3" port="$4" path="${5:-}"
  [[ "$id" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "workload: bad service id '$id'"
  ensure_dir "$(wl_services_dir)"
  jq -n --arg id "$id" --arg name "$name" --arg proto "$protocol" --argjson port "$port" --arg path "$path" \
    '{id:$id, name:$name, protocol:$proto, port:$port} + (if $path == "" then {} else {path:$path} end)' \
    | aw_write "$(wl_services_dir)/$id.json"
  chmod 644 "$(wl_services_dir)/$id.json" 2>/dev/null || true
}

wl_unreport_service() { run rm -f "$(wl_services_dir)/$1.json"; }

# The set the heartbeat carries, with live health from podman where it runs.
wl_services_json() {
  local d f id health
  d="$(wl_services_dir)"
  [[ -d "$d" ]] || { printf '[]'; return 0; }
  for f in "$d"/*.json; do
    [[ -f "$f" ]] || continue
    id="$(jq -r '.id // ""' "$f" 2>/dev/null)"; [[ -n "$id" ]] || continue
    health="unknown"
    if have podman && [[ -z "${AW_TEST:-}" ]]; then
      health="$(podman inspect --format '{{.State.Health.Status}}' "$(wl_container "$id")" 2>/dev/null || true)"
      [[ -n "$health" ]] || health="$(podman inspect --format '{{.State.Status}}' "$(wl_container "$id")" 2>/dev/null || echo unknown)"
    fi
    jq -c --arg h "$health" '. + {health:$h}' "$f" 2>/dev/null
  done | jq -sc '.'
}
