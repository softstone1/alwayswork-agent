# shellcheck shell=bash
# alwayswork capability: services.postgres — PostgreSQL on the workload
# contract (SYSTEM_SPEC §12.7). Sourced by the hooks and by `aw service`.
#
# Config (aw enable services.postgres --key value / desired state):
#   version   major version tag of docker.io/library/postgres (default 16)
#   image     full image ref override (digest form welcome)
#   port      loopback port on the node (default 5432)
#   db        database created on first start (default app)
#   user      role created on first start (default app)
#   memory_mb container memory budget (default: .limits.defaults.memory_mb)
#   admin     web admin side-car: pgweb (default) | off
#   admin_port loopback port of the admin UI (default 8081)
# The superuser password is POSTGRES_PASSWORD in the sealed store, generated
# on first enable if absent; the app role's password is POSTGRES_APP_PASSWORD.

PG_ID="postgres"
PG_IMAGE_REPO_DEFAULT="docker.io/library/postgres"

pg_version() { local v; v="$(cap_config version)"; [[ -n "$v" ]] || v=16; [[ "$v" =~ ^[0-9]{2}(\.[0-9]+)?$ ]] || die "services.postgres: bad version '$v'"; printf '%s' "$v"; }
pg_image()   { local i; i="$(cap_config image)"; [[ -n "$i" ]] || i="${PG_IMAGE_REPO_DEFAULT}:$(pg_version)"; printf '%s' "$i"; }
pg_port()    { local p; p="$(cap_config port)"; [[ -n "$p" ]] || p=5432; [[ "$p" =~ ^[0-9]{2,5}$ ]] || die "services.postgres: bad port '$p'"; printf '%s' "$p"; }
pg_db()      { local d; d="$(cap_config db)"; [[ -n "$d" ]] || d=app; [[ "$d" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "services.postgres: bad db name '$d'"; printf '%s' "$d"; }
pg_user()    { local u; u="$(cap_config user)"; [[ -n "$u" ]] || u=app; [[ "$u" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "services.postgres: bad user '$u'"; printf '%s' "$u"; }
pg_root()    { printf '%s' "$AW_STATE/services/$PG_ID"; }
pg_data()    { printf '%s' "$(pg_root)/data"; }
pg_backups() { printf '%s' "$(pg_root)/backups"; }
pg_env_file(){ printf '%s' "$AW_ETC/postgres.env"; }
pg_unit()    { wl_unit_name "$PG_ID"; }

# --- the web admin (SYSTEM_SPEC §12.8: a service's http surface) --------------
# pgweb: one static binary, browses and queries the database over a URL.
# Runs as its own workload container beside postgres on the alwayswork
# network, read-only rootfs, published to loopback, reached through the
# tunnel as <node>-postgres-admin.<base> behind Access. Off with admin=off.
PG_ADMIN_ID="postgres-admin"
PG_ADMIN_IMAGE_DEFAULT="docker.io/sosedoff/pgweb:0.16.2"
pg_admin()       { local a; a="$(cap_config admin)"; [[ -n "$a" ]] || a=pgweb; case "$a" in pgweb|off) printf '%s' "$a" ;; *) die "services.postgres: bad admin '$a' (pgweb|off)" ;; esac; }
pg_admin_port()  { local p; p="$(cap_config admin_port)"; [[ -n "$p" ]] || p=8081; [[ "$p" =~ ^[0-9]{2,5}$ ]] || die "services.postgres: bad admin_port '$p'"; printf '%s' "$p"; }
pg_admin_image() { local i; i="$(cap_config admin_image)"; [[ -n "$i" ]] || i="$PG_ADMIN_IMAGE_DEFAULT"; printf '%s' "$i"; }
pg_admin_env_file() { printf '%s' "$AW_ETC/postgres-admin.env"; }

# The admin connects as the application role over the container network;
# its credentials live only in a 0600 env file.
pg_admin_render_env() {
  local dest tmp
  dest="$(pg_admin_env_file)"
  if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] render %s\n' "$dest" >&2; return 0; fi
  tmp="$(mktemp "${dest}.XXXXXX")" || die "services.postgres: cannot stage admin env file"
  chmod 600 "$tmp"
  printf 'PGWEB_DATABASE_URL=postgres://%s:%s@%s:5432/%s?sslmode=disable\n' "$(pg_user)" "$(sec_get POSTGRES_APP_PASSWORD)" "$(pg_container)" "$(pg_db)" > "$tmp"
  mv -f "$tmp" "$dest"; chmod 600 "$dest"
}

# shellcheck disable=SC2034  # WL_* are read by lib/workload.sh
pg_admin_workload_vars() {
  WL_NAME="$PG_ADMIN_ID"
  WL_IMAGE="$(pg_admin_image)"
  WL_DESC="PostgreSQL web admin (pgweb)"
  WL_PUBLISH=("$(pg_admin_port):8081")
  WL_VOLUMES=()
  WL_ENV_FILE="$(pg_admin_env_file)"
  WL_LABELS=("dev.alwayswork.workload=$PG_ADMIN_ID" "dev.alwayswork.service=postgres" "dev.alwayswork.sidecar_of=$PG_ID")
  WL_READ_ONLY=1
  WL_TMPFS=()
  WL_HEALTH="wget -q -O /dev/null http://127.0.0.1:8081/ || curl -sf -o /dev/null http://127.0.0.1:8081/"
  WL_EXTRA=(--memory 256m --user 65534:65534)
  WL_NETWORK="$(cap_config network)"
  WL_ARGS=(--bind 0.0.0.0 --listen 8081 --skip-open)
}
pg_admin_write_unit() { pg_admin_workload_vars; wl_write_unit; }
pg_admin_apply() {
  if [[ "$(pg_admin)" == "off" ]]; then
    [[ -f "$WL_UNIT_DIR/$(wl_unit_name "$PG_ADMIN_ID")" ]] && wl_remove_unit "$PG_ADMIN_ID"
    wl_unreport_service "$PG_ADMIN_ID"
    return 0
  fi
  pg_admin_render_env
  WL_PULL="$(cap_config pull)" wl_ensure_image "$(pg_admin_image)"
  pg_admin_workload_vars; wl_apply_unit
  wl_report_surface "$PG_ID" "$PG_ADMIN_ID" http "$(pg_admin_port)" "/" "PostgreSQL admin (pgweb)"
}
pg_container(){ wl_container "$PG_ID"; }

# Passwords live only in the sealed store; generated once, never printed.
pg_ensure_secrets() {
  [[ "$(sec_backend)" == "sops" ]] || { warn "services.postgres: no sealed store (sops/age); passwords cannot be kept"; return 1; }
  sec_exists || sec_init
  local k
  for k in POSTGRES_PASSWORD POSTGRES_APP_PASSWORD; do
    if ! sec_has "$k"; then
      if [[ "$DRY_RUN" == "1" ]]; then info "services.postgres: dry-run — would generate $k"; continue; fi
      sec_set "$k" "$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"
    fi
  done
}

pg_render_env() {
  local dest tmp
  dest="$(pg_env_file)"
  if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] render %s\n' "$dest" >&2; return 0; fi
  tmp="$(mktemp "${dest}.XXXXXX")" || die "services.postgres: cannot stage env file"
  chmod 600 "$tmp"
  {
    printf 'POSTGRES_PASSWORD=%s\n' "$(sec_get POSTGRES_PASSWORD)"
    printf 'POSTGRES_DB=%s\n' "$(pg_db)"
    printf 'POSTGRES_USER=postgres\n'
    printf 'PGDATA=/var/lib/postgresql/data/pgdata\n'
    printf 'AW_APP_USER=%s\nAW_APP_PASSWORD=%s\n' "$(pg_user)" "$(sec_get POSTGRES_APP_PASSWORD)"
  } > "$tmp"
  mv -f "$tmp" "$dest"; chmod 600 "$dest"
}

# First-start init script (the image runs /docker-entrypoint-initdb.d/* once,
# on an empty data directory): the application role, owner of the app db.
pg_render_init() {
  local dir; dir="$(pg_root)/init"
  ensure_dir "$dir"
  aw_write "$dir/10-app-role.sh" <<'SH'
#!/bin/sh
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AW_APP_USER}') THEN
    CREATE ROLE "${AW_APP_USER}" LOGIN PASSWORD '${AW_APP_PASSWORD}';
  END IF;
END \$\$;
ALTER DATABASE "${POSTGRES_DB}" OWNER TO "${AW_APP_USER}";
GRANT ALL PRIVILEGES ON DATABASE "${POSTGRES_DB}" TO "${AW_APP_USER}";
SQL
SH
  run chmod 0755 "$dir/10-app-role.sh"
}

# shellcheck disable=SC2034  # WL_* are read by lib/workload.sh
pg_workload_vars() {
  local mem
  mem="$(cap_config memory_mb)"
  WL_NAME="$PG_ID"
  WL_IMAGE="$(pg_image)"
  WL_DESC="PostgreSQL $(pg_version)"
  WL_PUBLISH=("$(pg_port):5432")
  WL_VOLUMES=("$(pg_data):/var/lib/postgresql/data:U" "$(pg_root)/init:/docker-entrypoint-initdb.d:ro")
  WL_ENV_FILE="$(pg_env_file)"
  WL_LABELS=("dev.alwayswork.workload=$PG_ID" "dev.alwayswork.service=postgres")
  WL_READ_ONLY=0
  WL_TMPFS=()
  WL_HEALTH="pg_isready -U postgres -h 127.0.0.1"
  # Run as the image's postgres uid from the start: the official entrypoint
  # otherwise starts as root to chown and drop privileges, which cap-drop ALL
  # forbids. The :U volume flag gives the data mount to that uid, and
  # userns=auto maps it to an unused host range. Shared memory is a
  # deliberate budget for parallel workers, not the 64m default.
  WL_EXTRA=(--user 999:999 --shm-size 256m --stop-signal SIGINT)
  [[ -n "$mem" && "$mem" =~ ^[0-9]{3,6}$ ]] && WL_EXTRA+=(--memory "${mem}m")
  WL_NETWORK="$(cap_config network)"
  WL_ARGS=()
}
pg_write_unit() { pg_workload_vars; wl_write_unit; }
pg_apply_unit() { pg_workload_vars; wl_apply_unit; }

# --- operations (aw service ... postgres) ----------------------------------------
pg_exec() { podman exec -i "$(pg_container)" "$@"; }

pg_status() {
  section "postgres"
  kv "image" "$(pg_image)"
  kv "unit" "$(systemctl is-active "$(pg_unit)" 2>/dev/null || echo unknown)"
  if have podman; then
    kv "health" "$(podman inspect --format '{{.State.Health.Status}}' "$(pg_container)" 2>/dev/null || echo unknown)"
  fi
  kv "port" "127.0.0.1:$(pg_port)"
  kv "data" "$(pg_data) ($(du -sh "$(pg_data)" 2>/dev/null | cut -f1 || echo '?'))"
  kv "db / role" "$(pg_db) / $(pg_user)"
  local n; n="$(find "$(pg_root)/.snapshots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
  kv "snapshots" "$n"
  kv "backups" "$(find "$(pg_backups)" -name '*.sql.gz' 2>/dev/null | wc -l)"
  info "apps reach it through Hyperdrive at $(hostname)-postgres.<base> (see docs/SERVICES.md)"
}

pg_backup() {
  local dest stamp
  ensure_dir "$(pg_backups)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$(pg_backups)/${stamp}.sql.gz"
  log "postgres: logical dump -> $dest"
  if [[ "$DRY_RUN" == "1" ]]; then info "dry-run: pg_dumpall | gzip"; return 0; fi
  ( umask 077; pg_exec pg_dumpall -U postgres | gzip > "$dest" ) || { rm -f "$dest"; die "postgres: dump failed"; }
  ok "backup written ($(du -h "$dest" | cut -f1))"
  # Keep the last 14 dumps locally; backup.restic ships the directory offsite.
  find "$(pg_backups)" -name '*.sql.gz' -type f | sort | head -n -14 | xargs -r rm -f
}

pg_snapshot() {
  local label="${1:-manual}" s
  log "postgres: checkpoint + read-only snapshot of the data subvolume"
  [[ "$DRY_RUN" == "1" ]] || pg_exec psql -U postgres -c 'CHECKPOINT;' >/dev/null 2>&1 || warn "postgres: checkpoint failed (is it running?)"
  if s="$(wl_snapshot "$(pg_data)" "$label")"; then ok "snapshot $s"; fi
}

pg_restore() {
  local file="$1"
  [[ -f "$file" ]] || die "postgres: no such backup: $file"
  log "postgres: restoring $file (all databases; existing objects are kept unless the dump drops them)"
  [[ "$DRY_RUN" == "1" ]] && { info "dry-run: gunzip | psql"; return 0; }
  gunzip -c "$file" | pg_exec psql -U postgres -v ON_ERROR_STOP=0 >/dev/null || die "postgres: restore reported errors"
  ok "restored"
}

# A major upgrade is deliberate: snapshot, dump, switch the tag, and require
# a human (or the agent's runbook) to run pg_upgrade / restore. This command
# does the safe part and prints the rest.
pg_upgrade() {
  local to="$1"
  [[ "$to" =~ ^[0-9]{2}$ ]] || die "usage: aw service upgrade postgres <major>"
  pg_snapshot "pre-upgrade-$to"
  pg_backup
  cfg_set_str ".capabilities.config.services.postgres.version" "$to"
  warn "postgres: version pinned to $to in config. Data directories are major-specific:"
  info "  1. aw service backup postgres   (done above: $(pg_backups))"
  info "  2. move the old data aside:   mv $(pg_data) $(pg_data).v-old   (or restore the snapshot on failure)"
  info "  3. sudo aw apply                (starts $to on an empty directory)"
  info "  4. aw service restore postgres <latest dump>"
  info "the agent's runbook (docs/SERVICES.md) automates this sequence."
}

pg_logs() { podman logs --tail "${1:-100}" "$(pg_container)"; }
pg_psql() { pg_exec psql -U postgres "$@"; }
