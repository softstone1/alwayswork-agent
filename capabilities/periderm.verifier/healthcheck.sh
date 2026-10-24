# alwayswork capability: periderm.verifier (health)
[[ -S "$PD_PODMAN_SOCK" ]] || die "$PD_PODMAN_SOCK missing (podman.socket)"
podman network exists "$PD_VERIFY_NET" || die "network $PD_VERIFY_NET missing"
[[ "$(podman network inspect "$PD_VERIFY_NET" --format '{{.Internal}}' 2>/dev/null)" == "true" ]] || die "network $PD_VERIFY_NET is not internal"
! pd_verifier_conflict || die "another Periderm role is enabled next to the verifier"
ok "periderm verifier ready"
