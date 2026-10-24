# alwayswork capability: periderm.workspace (health)
podman network exists "$PD_NET" || die "network $PD_NET missing"
[[ "$(podman network inspect "$PD_NET" --format '{{.Internal}}' 2>/dev/null)" == "true" ]] || die "network $PD_NET is not internal"
podman network exists "$PD_NET_EGRESS" || die "network $PD_NET_EGRESS missing"
if compgen -G "$WL_UNIT_DIR/alwayswork-pdws-*.service" >/dev/null; then
  systemctl is-active --quiet "$(wl_unit_name "$PD_PROXY")" || die "workspaces present but $(wl_unit_name "$PD_PROXY") is not active"
fi
ok "periderm networks ready"
