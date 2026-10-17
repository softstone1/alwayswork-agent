# alwayswork capability: services.postgres (preflight)
# shellcheck disable=SC1090
source "${CAP_DIR}/postgres.sh"
if ! have podman; then
  [[ "$DRY_RUN" == "1" ]] || die "services.postgres: podman not found; runtime.podman is a dependency"
fi
if [[ "$(pg_tls)" == "on" ]] && ! have openssl; then
  [[ "$DRY_RUN" == "1" ]] || die "services.postgres: tls=on needs openssl on the node (or --tls off)"
fi
pg_version >/dev/null; pg_port >/dev/null; pg_db >/dev/null; pg_user >/dev/null; pg_admin >/dev/null
pg_roles >/dev/null; pg_hostnames >/dev/null
# backup=pgbackrest: settings valid and the three group secrets delivered,
# or apply never starts (and archiving never turns on).
pg_backup_mode >/dev/null
if pg_br_on && ! pg_backup_check; then
  [[ "$DRY_RUN" == "1" ]] || die "services.postgres: backup=pgbackrest refused (see above)"
fi
