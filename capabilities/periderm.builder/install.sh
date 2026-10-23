# alwayswork capability: periderm.builder
# Prepares the node for Periderm builds: the internal `periderm` network the
# build runs on, the `periderm-egress` network its proxy goes out on, and the
# firewall openings for them. Builds come as signed work in desired state.
if ! have podman; then [[ "$DRY_RUN" == "1" ]] || die "periderm.builder: podman not found; runtime.podman is a dependency"; fi
have git || [[ "$DRY_RUN" == "1" ]] || die "periderm.builder: git is required to unpack source bundles"
have timeout || [[ "$DRY_RUN" == "1" ]] || die "periderm.builder: timeout (coreutils) is required to bound builds"
log "periderm.builder: networks $PD_NET (internal) and $PD_NET_EGRESS"
pd_ensure_networks || die "periderm.builder: networks not ready"
pd_firewall_open
ok "periderm builder ready (build work arrives in desired state)"
