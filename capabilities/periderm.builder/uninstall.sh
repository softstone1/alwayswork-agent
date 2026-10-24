# alwayswork capability: periderm.builder (remove)
# The egress proxy and the firewall openings go unless workspaces still use
# them; build scratch space goes. Built images were uploaded; local tags go.
if ! pd_role_enabled "$PD_ROLE_WORKSPACE"; then
  pd_remove_unit "$PD_PROXY" || true
  pd_firewall_close
fi
if have podman && [[ "$DRY_RUN" != "1" ]]; then
  podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^localhost/periderm-build:' \
    | while IFS= read -r t; do run podman rmi -f "$t" >/dev/null 2>&1 || true; done
fi
ok "periderm builder removed"
