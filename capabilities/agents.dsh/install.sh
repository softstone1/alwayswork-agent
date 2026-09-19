# alwayswork capability: agents.dsh
# The node's agent web UI (DeepSeek Harness) as a standard workload
# container (SYSTEM_SPEC §12): rootful Podman, userns=auto, cgroup budget,
# read-only rootfs, published to loopback only, secrets via an env file.
# `mode: host` keeps the legacy on-host install for nodes without podman.

# shellcheck disable=SC1090
source "${CAP_DIR}/ensure.sh"
# shellcheck disable=SC1090
source "${CAP_DIR}/container.sh"

if [[ "$(dsc_mode)" == "host" ]]; then
  # shellcheck disable=SC1090
  source "${CAP_DIR}/host.sh"
  dsh_install_host
  # Hooks are sourced inside a subshell function, so `return` ends the hook.
  return 0
fi

if ! have podman; then
  [[ "$DRY_RUN" == "1" ]] || die "agents.dsh: podman is required for container mode (enable runtime.podman, or set --mode host)"
fi

port="$(dsc_port)"
host="$(dsc_host)"
img="$(dsc_image)"

log "agents.dsh: workload container $img -> 127.0.0.1:$port (trusted host $host)"
dsc_ensure_workspace
dsc_render_env
dsc_ensure_image

# Only restart the container when the unit actually changed: `aw apply` runs
# this hook on every delivery and must not bounce a working session.
unit="$DSH_UNIT_DIR/$DSH_UNIT"
before=""; [[ -f "$unit" ]] && before="$(sha256sum "$unit" | cut -d' ' -f1)"
dsc_write_unit
after=""; [[ -f "$unit" && "$DRY_RUN" != "1" ]] && after="$(sha256sum "$unit" | cut -d' ' -f1)"

dsc_retire_legacy_unit
run systemctl daemon-reload
run systemctl enable "$DSH_UNIT"
if [[ "$DRY_RUN" == "1" ]]; then
  info "agents.dsh: dry-run — would (re)start $DSH_UNIT"
elif [[ "$before" != "$after" ]] || ! systemctl is-active --quiet "$DSH_UNIT"; then
  run systemctl restart "$DSH_UNIT"
else
  info "agents.dsh: unit unchanged; container left running"
fi

dsc_report_webui "$host" "$port"
cfg_set_str '.agents.dsh.mode' container 2>/dev/null || true
ok "node web ui (container): https://$host/ -> 127.0.0.1:$port"
