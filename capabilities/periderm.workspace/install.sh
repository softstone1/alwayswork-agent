# alwayswork capability: periderm.workspace
# Prepares the node for Periderm workspaces: the internal `periderm` network,
# the `periderm-egress` network the proxy goes out on, and the firewall
# openings for them. The workspaces themselves come from desired state and are
# reconciled by lib/periderm.sh after every apply.
if ! have podman; then [[ "$DRY_RUN" == "1" ]] || die "periderm.workspace: podman not found; runtime.podman is a dependency"; fi
if [[ -r /proc/sys/user/max_user_namespaces && "$(cat /proc/sys/user/max_user_namespaces)" == "0" ]]; then
  die "periderm.workspace: user namespaces are disabled on this kernel; workspaces need userns=auto"
fi
have age || [[ "$DRY_RUN" == "1" ]] || warn "periderm.workspace: age is not installed; workspace tokens cannot be opened"
log "periderm.workspace: networks $PD_NET (internal) and $PD_NET_EGRESS"
pd_ensure_networks || die "periderm.workspace: networks not ready"
pd_firewall_open
ok "periderm workspaces ready (sessions arrive in desired state)"
