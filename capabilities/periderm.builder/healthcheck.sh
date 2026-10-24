# alwayswork capability: periderm.builder (health)
podman network exists "$PD_NET" || die "network $PD_NET missing"
[[ "$(podman network inspect "$PD_NET" --format '{{.Internal}}' 2>/dev/null)" == "true" ]] || die "network $PD_NET is not internal"
podman network exists "$PD_NET_EGRESS" || die "network $PD_NET_EGRESS missing"
have git || die "git missing"
! pd_role_enabled "$PD_ROLE_VERIFIER" || die "$PD_ROLE_VERIFIER is enabled on the same node"
ok "periderm builder ready"
