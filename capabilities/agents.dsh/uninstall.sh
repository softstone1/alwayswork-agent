# alwayswork capability: agents.dsh (remove)
# Stops and removes the workload unit and container. The workspace, the
# harness home and the image are DATA and stay unless AW_PURGE=1; a full
# decommission removes the state directory anyway.
# shellcheck disable=SC1090
source "${CAP_DIR}/ensure.sh"
# shellcheck disable=SC1090
source "${CAP_DIR}/container.sh"

run systemctl disable --now "$DSH_UNIT" 2>/dev/null || true
run systemctl disable --now "$DSH_LEGACY_UNIT" 2>/dev/null || true
run rm -f "$DSH_UNIT_DIR/$DSH_UNIT" "$DSH_UNIT_DIR/$DSH_LEGACY_UNIT"
run systemctl daemon-reload
if have podman; then
  run podman rm -f "$DSH_CONTAINER" 2>/dev/null || true
fi
run rm -f "$AW_STATE/webui.json" "$(dsc_env_file)"
if [[ "${AW_PURGE:-0}" == "1" ]]; then
  warn "agents.dsh: purging workspace, harness home and image"
  run rm -rf "$(dsc_workspace)" "$(dsc_home)"
  if have podman; then run podman rmi -f "$(dsc_image)" 2>/dev/null || true; fi
else
  info "agents.dsh: kept $(dsc_workspace) and $(dsc_home) (AW_PURGE=1 removes them)"
fi
ok "node web ui removed"
wl_unreport_manifest_surfaces agents.dsh 2>/dev/null || true
