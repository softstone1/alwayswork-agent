# alwayswork capability: services.postgres
# PostgreSQL as a workload container (SYSTEM_SPEC §12.7): pinned image,
# userns=auto, cgroup budget, data on a btrfs subvolume, healthcheck systemd
# restarts on, loopback publish; reported on heartbeat so the control plane
# exposes <node>-postgres.<base> through the tunnel for Hyperdrive.
# shellcheck disable=SC1090
source "${CAP_DIR}/postgres.sh"

log "services.postgres: $(pg_image) -> 127.0.0.1:$(pg_port), data $(pg_data)"
wl_subvolume "$(pg_data)"
ensure_dir "$(pg_backups)"
pg_ensure_secrets || true
pg_render_env
pg_render_init
WL_PULL="$(cap_config pull)" wl_ensure_image "$(pg_image)"
pg_apply_unit
wl_report_service "$PG_ID" "PostgreSQL" tcp "$(pg_port)"
ok "postgres ready on 127.0.0.1:$(pg_port) (db $(pg_db), role $(pg_user))"
