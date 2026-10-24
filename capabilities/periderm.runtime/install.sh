# alwayswork capability: periderm.runtime
# Production apps arrive as activations in desired state; nothing to set up
# beyond the workload network runtime.podman provides.
if ! have podman; then [[ "$DRY_RUN" == "1" ]] || die "periderm.runtime: podman not found; runtime.podman is a dependency"; fi
have curl || [[ "$DRY_RUN" == "1" ]] || die "periderm.runtime: curl is required to probe releases"
ok "periderm runtime ready (activations arrive in desired state)"
