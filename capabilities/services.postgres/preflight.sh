# alwayswork capability: services.postgres (preflight)
# shellcheck disable=SC1090
source "${CAP_DIR}/postgres.sh"
if ! have podman; then
  [[ "$DRY_RUN" == "1" ]] || die "services.postgres: podman not found; runtime.podman is a dependency"
fi
pg_version >/dev/null; pg_port >/dev/null; pg_db >/dev/null; pg_user >/dev/null
