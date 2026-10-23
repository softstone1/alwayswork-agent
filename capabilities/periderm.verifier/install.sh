# alwayswork capability: periderm.verifier
# The host podman socket the verifier drives candidates through, and the
# internal `periderm-verify` network they share with it.
if ! have podman; then [[ "$DRY_RUN" == "1" ]] || die "periderm.verifier: podman not found; runtime.podman is a dependency"; fi
have timeout || [[ "$DRY_RUN" == "1" ]] || die "periderm.verifier: timeout (coreutils) is required to bound verifications"
run systemctl enable --now podman.socket || die "periderm.verifier: could not start podman.socket"
if [[ "$DRY_RUN" == "1" ]]; then
  info "periderm.verifier: dry-run — would create network '$PD_VERIFY_NET' (--internal)"
else
  pd_ensure_verify_network || die "periderm.verifier: network not ready"
fi
ok "periderm verifier ready (verify work arrives in desired state)"
