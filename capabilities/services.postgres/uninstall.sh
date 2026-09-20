# alwayswork capability: services.postgres (remove)
# The unit and container go; the DATA, snapshots and dumps stay unless
# AW_PURGE=1 (a full decommission removes the state directory anyway).
# shellcheck disable=SC1090
source "${CAP_DIR}/postgres.sh"
wl_remove_unit "$PG_ADMIN_ID" || return 1
wl_unreport_manifest_surfaces services.postgres
run rm -f "$(pg_admin_env_file)"
wl_remove_unit "$PG_ID" || return 1
run rm -f "$(pg_env_file)"
if [[ "${AW_PURGE:-0}" == "1" ]]; then
  warn "services.postgres: purging $(pg_root) (data, snapshots, backups)"
  run rm -rf "$(pg_root)"
else
  info "services.postgres: kept $(pg_root) (AW_PURGE=1 removes it)"
fi
ok "postgres removed"
