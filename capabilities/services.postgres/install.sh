# alwayswork capability: services.postgres
# PostgreSQL as a workload container (SYSTEM_SPEC §12.7): pinned image,
# userns=auto, cgroup budget, data on a btrfs subvolume, healthcheck systemd
# restarts on, loopback publish; reported on heartbeat so the control plane
# exposes <node>-postgres.<base> through the tunnel for Hyperdrive. TLS from
# a node-local CA, a managed pg_hba, declared roles and the aw schema are
# reconciled on every apply. backup=pgbackrest adds continuous WAL archiving
# to R2, scheduled backups and a weekly restore drill (postgres.sh).
# shellcheck disable=SC1090
source "${CAP_DIR}/postgres.sh"

# A point-in-time restore owns the data directory until it is done: starting
# the unit now would initdb into the empty directory it is restoring into.
if [[ -e "$(pg_restore_lock)" ]]; then
  err "services.postgres: a point-in-time restore is in progress ($(pg_restore_lock)); not applying"
  return 1
fi
# backup=pgbackrest without its secrets is refused before anything changes:
# archive_command is never turned on without a repository to archive to.
if pg_br_on && ! pg_backup_check; then
  [[ "$DRY_RUN" == "1" ]] || return 1
fi
log "services.postgres: $(pg_image) -> 127.0.0.1:$(pg_port), data $(pg_data), tls $(pg_tls), backup $(pg_backup_mode)"
wl_subvolume "$(pg_data)"
ensure_dir "$(pg_backups)"
pg_ensure_secrets || true
pg_tls_ensure || return 1
pg_render_hba
pg_render_env
pg_render_init
if pg_br_on; then
  pg_br_render || return 1
  pg_br_ensure_image
else
  WL_PULL="$(cap_config pull)" wl_ensure_image "$(pg_image)"
fi
pg_apply_unit
wl_report_manifest_surfaces services.postgres
# A database still initialising is not a failed apply: the next one retries.
pg_up=0
pg_reconcile && pg_up=1
if pg_br_on; then
  pg_br_timers_apply || warn "services.postgres: could not install the backup schedules"
  # The stanza needs the server; until it answers, the next apply creates it.
  (( pg_up )) && { pg_br_stanza_ensure || true; }
else
  pg_br_disable || warn "services.postgres: could not remove the backup schedules"
fi
pg_report || warn "services.postgres: could not add the postgres details to the heartbeat"
pg_admin_apply
ok "postgres ready on 127.0.0.1:$(pg_port) (db $(pg_db), role $(pg_user))$( [[ "$(pg_admin)" == "off" ]] || printf '; web admin on 127.0.0.1:%s' "$(pg_admin_port)" )"
