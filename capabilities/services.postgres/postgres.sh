# shellcheck shell=bash
# alwayswork capability: services.postgres — PostgreSQL on the workload
# contract (SYSTEM_SPEC §12.7). Sourced by the hooks and by `aw service`.
#
# Config (aw enable services.postgres --key value / desired state):
#   version   major version tag of docker.io/library/postgres (default 16)
#   image     full image ref override (digest form welcome)
#   port      loopback port on the node (default 5432)
#   db        database (created when missing; default app)
#   user      legacy application role (default app; owner of db unless a
#             declared role is `:owner`); password POSTGRES_APP_PASSWORD
#   roles     declared login roles: comma list of `name` or `name:owner`
#             (max 8, at most one owner); password PG_ROLE_<NAME>_PASSWORD
#   tls       on (default) | off — TLS from a node-local CA; TCP is
#             scram-sha-256 over hostssl only
#   hostnames extra DNS names for the server certificate (comma list), e.g.
#             the tunnel name Hyperdrive verifies
#   memory_mb container memory budget (default: .limits.defaults.memory_mb)
#   admin     web admin side-car: off (default) | pgweb (alias: on)
#   admin_port loopback port of the admin UI (default 8081)
#   backup    off (default; `aw service backup` is a pg_dumpall) | pgbackrest:
#             continuous WAL archive + weekly full / daily diff to an S3 repo
#             (Cloudflare R2), client-side encrypted, PITR, weekly restore drill
#   backup_endpoint  https://<account>.r2.cloudflarestorage.com (required)
#   backup_bucket    bucket name (required)
#   backup_path      repo path in the bucket (default /<node>/<db>; monthly
#                    fulls go to <backup_path>-monthly)
#   backup_region    default auto
#   backup_retention_full_weeks  PITR window in weeks (default 2 = 14 days)
#   backup_monthly_keep          monthly fulls kept, one per month (default
#                                12; 0 = no monthly repository)
# Secrets (sealed store): POSTGRES_PASSWORD (superuser) and
# POSTGRES_APP_PASSWORD are generated here and node-owned — a delivered group
# secret never replaces them. PG_ROLE_<NAME>_PASSWORD is generated when
# absent but a delivered value wins: that is how the control plane rotates,
# and the next apply ALTERs the role. Every apply reconciles roles, the `aw`
# schema (aw.facts, aw.status) and the heartbeat's `postgres` object
# (database, CA certificate, per-role password fingerprints, backup state —
# never a secret). backup=pgbackrest needs three group secrets, delivered
# sealed and never node-owned: PGBACKREST_R2_ACCESS_KEY_ID,
# PGBACKREST_R2_SECRET_ACCESS_KEY, PGBACKREST_CIPHER_PASS. Without them apply
# refuses and archiving stays off. They reach pgBackRest only through a 0600
# pgbackrest.conf mounted read-only — never argv, a unit file or a log line.

PG_ID="postgres"
PG_IMAGE_REPO_DEFAULT="docker.io/library/postgres"

pg_version() { local v; v="$(cap_config version)"; [[ -n "$v" ]] || v="$(wl_manifest_get services.postgres '.workload.image.version.pinned')"; [[ -n "$v" ]] || v=16; [[ "$v" =~ ^[0-9]{2}(\.[0-9]+)?$ ]] || die "services.postgres: bad version '$v'"; printf '%s' "$v"; }
# The image the node would run without backups (pin, channel or override);
# with backup=pgbackrest the node builds pgBackRest on top of exactly that.
pg_base_image() { local i; i="$(cap_config image)"; [[ -n "$i" ]] || i="${PG_IMAGE_REPO_DEFAULT}:$(pg_version)"; printf '%s' "$i"; }
pg_image()   { if pg_br_on; then pg_br_image; else pg_base_image; fi; }
pg_port()    { local p; p="$(cap_config port)"; [[ -n "$p" ]] || p=5432; [[ "$p" =~ ^[0-9]{2,5}$ ]] || die "services.postgres: bad port '$p'"; printf '%s' "$p"; }
pg_db()      { local d; d="$(cap_config db)"; [[ -n "$d" ]] || d=app; [[ "$d" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "services.postgres: bad db name '$d'"; printf '%s' "$d"; }
pg_user()    { local u; u="$(cap_config user)"; [[ -n "$u" ]] || u=app; [[ "$u" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "services.postgres: bad user '$u'"; printf '%s' "$u"; }
pg_root()    { printf '%s' "$AW_STATE/services/$PG_ID"; }
pg_data()    { printf '%s' "$(pg_root)/data"; }
pg_backups() { printf '%s' "$(pg_root)/backups"; }
pg_env_file(){ printf '%s' "$AW_ETC/postgres.env"; }
pg_unit()    { wl_unit_name "$PG_ID"; }
pg_tls()     { local t; t="$(cap_config tls)"; [[ -n "$t" ]] || t=on; case "$t" in on|off) printf '%s' "$t" ;; *) die "services.postgres: bad tls '$t' (on|off)" ;; esac; }
pg_tls_dir() { printf '%s' "$(pg_root)/tls"; }
pg_conf_dir(){ printf '%s' "$(pg_root)/conf"; }
pg_hba_file(){ printf '%s' "$(pg_conf_dir)/pg_hba.conf"; }
# Where the container sees them (read-only mounts).
PG_TLS_MNT="/etc/alwayswork/tls"
PG_CONF_MNT="/etc/alwayswork/pg"

# hostnames: extra certificate names, one per line, lowercased and checked.
pg_hostnames() {
  local raw h n=0
  raw="$(cap_config hostnames)"
  local -a items=()
  IFS=',' read -ra items <<<"$raw"
  for h in "${items[@]}"; do
    h="${h//[[:space:]]/}"; h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$h" ]] || continue
    [[ "$h" =~ ^(\*\.)?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ && ${#h} -le 253 ]] \
      || die "services.postgres: bad hostname '$h'"
    n=$(( n + 1 )); (( n <= 16 )) || die "services.postgres: at most 16 hostnames"
    printf '%s\n' "$h"
  done
}

# roles: "name<TAB>1|0" (owner) per declared role. Validated as a whole —
# callers take the list with `roles="$(pg_roles)" || return 1`, so a bad
# declaration never reads as "no roles" (which would disable them all).
# pg_* is reserved by PostgreSQL; postgres is the superuser.
PG_ROLES_MAX=8
pg_roles() {
  local raw item name flag n=0 owners=0 seen=","
  raw="$(cap_config roles)"
  local -a items=()
  IFS=',' read -ra items <<<"$raw"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue
    name="${item%%:*}"; flag=""
    [[ "$item" == *:* ]] && flag="${item#*:}"
    [[ "$name" =~ ^[a-z_][a-z0-9_]{0,46}$ ]] || die "services.postgres: bad role name '$name'"
    [[ "$name" != "postgres" && "$name" != pg_* ]] || die "services.postgres: role '$name' is reserved"
    case "$flag" in "") ;; owner) owners=$(( owners + 1 )) ;; *) die "services.postgres: bad role flag '$item' (name or name:owner)" ;; esac
    [[ "$seen" != *",$name,"* ]] || die "services.postgres: role '$name' declared twice"
    seen+="$name,"
    n=$(( n + 1 ))
    (( n <= PG_ROLES_MAX )) || die "services.postgres: at most $PG_ROLES_MAX roles"
    (( owners <= 1 )) || die "services.postgres: at most one :owner role"
    printf '%s\t%s\n' "$name" "$([[ "$flag" == owner ]] && echo 1 || echo 0)"
  done
}
pg_role_secret() { printf 'PG_ROLE_%s_PASSWORD' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# --- the web admin (SYSTEM_SPEC §12.8: a service's http surface) --------------
# pgweb: one static binary, browses and queries the database over a URL.
# Runs as its own workload container beside postgres on the alwayswork
# network, read-only rootfs, published to loopback, reached through the
# tunnel as <node>-postgres-admin.<base> behind Access. Off by default: a
# browser path into the production database is opted into (admin=pgweb).
PG_ADMIN_ID="postgres-admin"
PG_ADMIN_IMAGE_DEFAULT="$(wl_want_image services.postgres postgres-admin 2>/dev/null || printf 'docker.io/sosedoff/pgweb:0.16.2')"
pg_admin()       { local a; a="$(cap_config admin)"; [[ -n "$a" ]] || a=off; case "$a" in pgweb|on) printf pgweb ;; off) printf off ;; *) die "services.postgres: bad admin '$a' (pgweb|off)" ;; esac; }
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
  # The managed hba has no plain TCP rule while tls=on.
  local ssl=disable; [[ "$(pg_tls)" == "on" ]] && ssl=require
  printf 'PGWEB_DATABASE_URL=postgres://%s:%s@%s:5432/%s?sslmode=%s\n' "$(pg_user)" "$(sec_get POSTGRES_APP_PASSWORD)" "$(pg_container)" "$(pg_db)" "$ssl" > "$tmp"
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
  wl_report_manifest_surfaces services.postgres "$PG_ADMIN_ID"
}
pg_container(){ wl_container "$PG_ID"; }

# Passwords live only in the sealed store; generated once, never printed.
# The superuser and app passwords exist only because this node made them, so
# they are recorded node-owned (also when an older agent generated them): a
# group secret of the same name must not replace them under a running
# database. Role passwords are generated when absent but stay control-owned.
pg_gen_password() { head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40; }
pg_ensure_secrets() {
  [[ "$(sec_backend)" == "sops" ]] || { warn "services.postgres: no sealed store (sops/age); passwords cannot be kept"; return 1; }
  sec_exists || sec_init
  local k name _owner roles
  roles="$(pg_roles)" || return 1
  for k in POSTGRES_PASSWORD POSTGRES_APP_PASSWORD; do
    if ! sec_has "$k"; then
      if [[ "$DRY_RUN" == "1" ]]; then info "services.postgres: dry-run — would generate $k"; continue; fi
      sec_set "$k" "$(pg_gen_password)"
    fi
    sec_mark_node_owned "$k"
  done
  while IFS=$'\t' read -r name _owner; do
    [[ -n "$name" ]] || continue
    k="$(pg_role_secret "$name")"
    sec_has "$k" && continue
    if [[ "$DRY_RUN" == "1" ]]; then info "services.postgres: dry-run — would generate $k"; continue; fi
    sec_set "$k" "$(pg_gen_password)"
  done <<<"$roles"
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

# --- TLS from a node-local CA ----------------------------------------------------------
# tls/ca.{key,crt}: the CA, 10 years. Its key is root-only and never mounted
# — the container could otherwise mint certificates for any name.
# tls/server/: the server key and certificate (2 years), the only directory
# mounted (read-only, :U). userns=auto maps container uid 999 to a host range
# picked at start, so the host cannot chown ahead of time; :U hands the files
# to the mapped uid on every start, which satisfies PostgreSQL's rule that the
# key is 0600 and owned by the server user. The CA certificate is public: it
# rides the heartbeat so Hyperdrive can verify the origin.
pg_tls_ca_crt()  { printf '%s' "$(pg_tls_dir)/ca.crt"; }
pg_tls_srv_dir() { printf '%s' "$(pg_tls_dir)/server"; }
pg_tls_san() {
  local h out="DNS:localhost,IP:127.0.0.1" hosts
  hosts="$(pg_hostnames)" || return 1
  while IFS= read -r h; do [[ -n "$h" ]] && out+=",DNS:$h"; done <<<"$hosts"
  printf '%s' "$out"
}
pg_tls_ensure() {
  [[ "$(pg_tls)" == "on" ]] || return 0
  local dir srv san cnf
  dir="$(pg_tls_dir)"; srv="$(pg_tls_srv_dir)"
  san="$(pg_tls_san)" || return 1
  if [[ "$DRY_RUN" == "1" ]]; then info "services.postgres: dry-run — would ensure the TLS CA and server certificate ($san)"; return 0; fi
  have openssl || die "services.postgres: tls=on needs openssl on the node"
  ensure_dir "$dir"; chmod 700 "$dir"; ensure_dir "$srv"
  cnf="$(mktemp "$dir/.openssl.XXXXXX")" || die "services.postgres: cannot stage openssl config"
  # A minimal config of our own: distro defaults differ, and some ship none.
  cat > "$cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = alwayswork postgres
[ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = $san
authorityKeyIdentifier = keyid
CNF
  if [[ ! -s "$dir/ca.key" || ! -s "$dir/ca.crt" ]]; then
    log "services.postgres: creating the node's PostgreSQL CA"
    if ! ( umask 077
           openssl ecparam -name prime256v1 -genkey -noout -out "$dir/ca.key.new" \
             && openssl req -x509 -new -sha256 -days 3650 -key "$dir/ca.key.new" -config "$cnf" -extensions ca \
                  -subj "/CN=alwayswork postgres CA $(hostname 2>/dev/null || echo node)" -out "$dir/ca.crt.new" 2>/dev/null ); then
      rm -f "$cnf" "$dir/ca.key.new" "$dir/ca.crt.new"; die "services.postgres: CA generation failed"
    fi
    mv -f "$dir/ca.key.new" "$dir/ca.key"; mv -f "$dir/ca.crt.new" "$dir/ca.crt"
    rm -f "$srv/server.crt"   # signed by the old CA, if any
  fi
  chmod 600 "$dir/ca.key"; chmod 644 "$dir/ca.crt"
  # Reissue (CA kept) when missing, within 30 days of expiry, not from this
  # CA, or for a different set of names.
  if [[ ! -s "$srv/server.key" || ! -s "$srv/server.crt" ]] \
     || ! openssl x509 -checkend $(( 30 * 86400 )) -noout -in "$srv/server.crt" >/dev/null 2>&1 \
     || ! openssl verify -CAfile "$dir/ca.crt" "$srv/server.crt" >/dev/null 2>&1 \
     || [[ "$(cat "$dir/server.san" 2>/dev/null)" != "$san" ]]; then
    log "services.postgres: issuing the server certificate ($san)"
    if ! ( umask 077
           openssl ecparam -name prime256v1 -genkey -noout -out "$dir/server.key.new" \
             && openssl req -new -sha256 -key "$dir/server.key.new" -config "$cnf" -subj "/CN=localhost" -out "$dir/server.csr" 2>/dev/null \
             && openssl x509 -req -sha256 -days 730 -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
                  -set_serial "0x$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" -extfile "$cnf" -extensions server -out "$dir/server.crt.new" 2>/dev/null ); then
      rm -f "$cnf" "$dir/server.key.new" "$dir/server.crt.new" "$dir/server.csr"; die "services.postgres: server certificate failed"
    fi
    chmod 644 "$dir/server.crt.new"
    mv -f "$dir/server.key.new" "$srv/server.key"; mv -f "$dir/server.crt.new" "$srv/server.crt"
    printf '%s' "$san" > "$dir/server.san"
    rm -f "$dir/server.csr"
  fi
  rm -f "$cnf"
  chmod 600 "$srv/server.key"
}
# Fingerprint of the CA certificate as Hyperdrive sees it (DER, sha256).
pg_tls_ca_sha256() { openssl x509 -in "$(pg_tls_ca_crt)" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }

# --- client authentication -------------------------------------------------------------
# Rendered on every apply and passed with hba_file, so the image's initdb
# rule (host all all all scram-sha-256) and anything edited in PGDATA never
# apply. The socket is `peer` for the superuser only: the entrypoint's init
# scripts, `aw service psql` and the reconcile all run as uid 999 (passwd
# name postgres) inside the container, so peer authenticates them without a
# password and without `trust` — another uid in the container gets nothing.
# TCP is password-only (scram-sha-256), over TLS unless tls=off.
pg_render_hba() {
  local kind=hostssl
  if [[ "$(pg_tls)" == "off" ]]; then
    kind=host
    warn "services.postgres: tls=off — passwords cross the network unencrypted (the tunnel still encrypts the public path)"
  fi
  ensure_dir "$(pg_conf_dir)"
  aw_write "$(pg_hba_file)" <<HBA
# Managed by alwayswork (services.postgres); rewritten on every apply.
# TYPE   DATABASE USER     ADDRESS    METHOD
local    all      postgres            peer
$kind all      all      0.0.0.0/0  scram-sha-256
$kind all      all      ::/0       scram-sha-256
HBA
  [[ "$DRY_RUN" == "1" ]] || chmod 644 "$(pg_hba_file)"
}

# shellcheck disable=SC2034  # WL_* are read by lib/workload.sh
pg_workload_vars() {
  local mem
  mem="$(cap_config memory_mb)"
  WL_NAME="$PG_ID"
  WL_IMAGE="$(pg_image)"
  WL_DESC="PostgreSQL $(pg_version)"
  WL_PUBLISH=("$(pg_port):5432")
  local br=0; pg_br_on && br=1
  WL_VOLUMES=("$(pg_data):/var/lib/postgresql/data:U" "$(pg_root)/init:/docker-entrypoint-initdb.d:ro" "$(pg_conf_dir):$PG_CONF_MNT:ro")
  WL_ARGS=(postgres -c "hba_file=$PG_CONF_MNT/pg_hba.conf" -c password_encryption=scram-sha-256)
  if [[ "$(pg_tls)" == "on" ]]; then
    WL_VOLUMES+=("$(pg_tls_srv_dir):$PG_TLS_MNT:ro,U")
    WL_ARGS+=(-c ssl=on -c "ssl_cert_file=$PG_TLS_MNT/server.crt" -c "ssl_key_file=$PG_TLS_MNT/server.key" -c ssl_min_protocol_version=TLSv1.2)
  fi
  # Continuous archiving only with a repository to archive to.
  if (( br )); then
    WL_VOLUMES+=("$(pg_br_dir):$PG_BR_MNT:ro,U")
    WL_ARGS+=(-c wal_level=replica -c archive_mode=on -c "archive_command=pgbackrest --stanza=$(pg_stanza) archive-push %p" -c archive_timeout=60)
  fi
  WL_ENV_FILE="$(pg_env_file)"
  # A new certificate or hba is read at start: their digest in the unit
  # restarts this container when they change, like the env file's.
  local conf
  # pgbackrest.conf too: :U hands it to the container's uid only at start.
  local -a conf_files=("$(pg_hba_file)" "$(pg_tls_srv_dir)/server.crt")
  (( br )) && conf_files+=("$(pg_br_conf)")
  conf="$(cat "${conf_files[@]}" 2>/dev/null | sha256sum | cut -c1-16)"
  WL_LABELS=("dev.alwayswork.workload=$PG_ID" "dev.alwayswork.service=postgres" "dev.alwayswork.pg_conf=$conf")
  # A node-built image reports the image it derives from (update tracking).
  (( br )) && WL_LABELS+=("dev.alwayswork.base_image=$(pg_base_image)")
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
}
pg_write_unit() { pg_workload_vars; wl_write_unit; }
pg_apply_unit() { pg_workload_vars; wl_apply_unit; }

# --- reconcile (every apply, once the server answers) ------------------------------------
# SQL goes to psql on stdin over the container's socket as postgres (peer):
# no password is ever an argument (visible in /proc) or a log line. A
# password travels hex-encoded in a psql variable and is decoded server side
# into format(%L), so no value can break the quoting; the session silences
# statement logging first, so even a failing ALTER is not written out.
PG_SQL_QUIET="SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET client_min_messages = 'warning';"
pg_sql() { pg_exec psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$1" >/dev/null; }
pg_hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
pg_fingerprint() { printf '%s' "$1" | sha256sum | cut -c1-16; }
PG_ROLE_MARK="managed by alwayswork (services.postgres roles)"

# Over TCP, not the socket: the image's first-start server listens on the
# socket only and is restarted after the init scripts, so a socket answer
# can come from a server about to go away.
pg_wait_ready() {
  local i tries="${PG_READY_TRIES:-60}"
  for (( i = 0; i < tries; i++ )); do
    podman exec "$(pg_container)" pg_isready -q -U postgres -h 127.0.0.1 </dev/null >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

pg_reconcile_role() {
  local name="$1" pw="$2" mark="${3:-0}"
  [[ -n "$pw" ]] || return 1
  {
    printf '%s\n' "$PG_SQL_QUIET"
    printf '%s\n' "\\set pwhex '$(pg_hex "$pw")'"
    printf '%s\n' "SELECT format('CREATE ROLE %I LOGIN', '$name') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$name') \\gexec"
    printf '%s\n' "SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '$name', convert_from(decode(:'pwhex', 'hex'), 'UTF8')) \\gexec"
    if [[ "$mark" == "1" ]]; then printf '%s\n' "COMMENT ON ROLE \"$name\" IS '$PG_ROLE_MARK';"; fi
  } | pg_sql postgres
}

pg_reconcile() {
  [[ "$DRY_RUN" == "1" ]] && { info "services.postgres: dry-run — would reconcile roles and the aw schema"; return 0; }
  have podman || return 1
  local roles db app owner="" keep="" name isowner pw ok_roles="" grants="" report='[]'
  roles="$(pg_roles)" || return 1
  db="$(pg_db)"; app="$(pg_user)"
  pg_wait_ready || { warn "services.postgres: server not ready; roles and the aw schema reconcile on the next apply"; return 1; }
  while IFS=$'\t' read -r name isowner; do
    [[ -n "$name" ]] || continue
    keep+="${keep:+,}$name"
    [[ "$isowner" == "1" ]] && owner="$name"
  done <<<"$roles"
  # Roles dropped from config keep their objects but can no longer log in.
  printf '%s\n\\set db %s\n\\set keep %s\n%s\n' "$PG_SQL_QUIET" "'$db'" "'$keep'" \
"SELECT format('CREATE DATABASE %I', :'db') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \\gexec
SELECT format('ALTER ROLE %I NOLOGIN', rolname) FROM pg_roles
 WHERE rolcanlogin AND shobj_description(oid, 'pg_authid') = '$PG_ROLE_MARK'
   AND NOT (rolname = ANY (string_to_array(:'keep', ','))) \\gexec" \
    | pg_sql postgres || { warn "services.postgres: database reconcile failed"; return 1; }
  # The legacy application role keeps its password and, without a declared
  # owner, the database (what the first-start init script set up).
  if [[ ",$keep," != *",$app,"* ]]; then
    pg_reconcile_role "$app" "$(sec_get POSTGRES_APP_PASSWORD)" 0 || warn "services.postgres: app role '$app' reconcile failed"
    [[ -n "$owner" ]] || owner="$app"
  fi
  while IFS=$'\t' read -r name isowner; do
    [[ -n "$name" ]] || continue
    pw="$(sec_get "$(pg_role_secret "$name")")"
    if pg_reconcile_role "$name" "$pw" 1; then
      ok_roles+="$name "
      grants+="${grants:+, }\"$name\""
      report="$(jq -c --arg n "$name" --arg f "$(pg_fingerprint "$pw")" '. + [{name:$n, secretSha256:$f}]' <<<"$report")"
    else
      warn "services.postgres: role '$name' reconcile failed (secret $(pg_role_secret "$name"))"
    fi
  done <<<"$roles"
  pg_reconcile_schema "$db" "$owner" "$grants" || warn "services.postgres: aw schema reconcile failed"
  # What the database now holds, as fingerprints only: the heartbeat's roles.
  ensure_dir "$(pg_root)"
  printf '%s\n' "$report" | aw_write "$(pg_roles_report)"
  chmod 644 "$(pg_roles_report)" 2>/dev/null || true
  pg_status_facts >/dev/null 2>&1 || true
  [[ -z "$ok_roles" ]] || ok "postgres roles reconciled: $ok_roles"
}
pg_roles_report() { printf '%s' "$(pg_root)/roles.json"; }

# aw.status: one row an operator, the control plane or a declared role can
# read without superuser — server, size, archiving (WAL lag from
# pg_stat_archiver), and the facts the node records: disk, the last backup
# and the last restore drill. New columns only ever go at the end (CREATE OR
# REPLACE VIEW cannot reorder).
pg_reconcile_schema() {
  local db="$1" owner="$2" grants="$3"
  {
    printf '%s\n' "$PG_SQL_QUIET"
    cat <<'SQL'
CREATE SCHEMA IF NOT EXISTS aw AUTHORIZATION postgres;
ALTER SCHEMA aw OWNER TO postgres;
CREATE TABLE IF NOT EXISTS aw.facts (key text PRIMARY KEY, value text, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE aw.facts OWNER TO postgres;
CREATE OR REPLACE VIEW aw.status AS
SELECT current_setting('server_version') AS server_version,
       (SELECT count(*) FROM pg_stat_activity)::int AS connections,
       current_setting('max_connections')::int AS max_connections,
       pg_database_size(current_database()) AS db_size_bytes,
       CASE WHEN current_setting('archive_mode') = 'off' THEN NULL ELSE a.archived_count END AS archived_count,
       CASE WHEN current_setting('archive_mode') = 'off' THEN NULL ELSE a.last_archived_time END AS last_archived_at,
       CASE WHEN current_setting('archive_mode') = 'off' THEN NULL ELSE a.last_failed_time END AS last_failed_at,
       CASE WHEN current_setting('archive_mode') = 'off' THEN NULL
            ELSE extract(epoch FROM now() - a.last_archived_time)::bigint END AS archive_lag_seconds,
       (SELECT NULLIF(value, '')::bigint FROM aw.facts WHERE key = 'disk_free_bytes') AS disk_free_bytes,
       (SELECT NULLIF(value, '')::bigint FROM aw.facts WHERE key = 'disk_total_bytes') AS disk_total_bytes,
       (SELECT NULLIF(value, '')::timestamptz FROM aw.facts WHERE key = 'last_backup_at') AS last_backup_at,
       (SELECT NULLIF(value, '')::boolean FROM aw.facts WHERE key = 'last_backup_ok') AS last_backup_ok,
       (SELECT NULLIF(value, '')::timestamptz FROM aw.facts WHERE key = 'last_restore_drill_at') AS last_restore_drill_at,
       (SELECT NULLIF(value, '')::boolean FROM aw.facts WHERE key = 'last_restore_drill_ok') AS last_restore_drill_ok,
       (SELECT max(updated_at) FROM aw.facts) AS updated_at,
       (SELECT NULLIF(value, '') FROM aw.facts WHERE key = 'last_backup_kind') AS last_backup_kind,
       (SELECT NULLIF(value, '') FROM aw.facts WHERE key = 'last_backup_error') AS last_backup_error,
       (SELECT NULLIF(value, '') FROM aw.facts WHERE key = 'last_restore_drill_error') AS last_restore_drill_error
  FROM pg_stat_archiver a;
ALTER VIEW aw.status OWNER TO postgres;
SQL
    if [[ -n "$grants" ]]; then
      printf 'GRANT USAGE ON SCHEMA aw TO %s;\nGRANT SELECT ON aw.status TO %s;\n' "$grants" "$grants"
    fi
    if [[ -n "$owner" ]]; then printf '%s\n' "SELECT format('ALTER DATABASE %I OWNER TO %I', '$db', '$owner') WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$owner') \\gexec"; fi
  } | pg_sql "$db"
}

# Disk of the data directory, as the host sees it, into aw.facts. Cheap
# enough for every healthcheck; a failure only means stale facts.
pg_status_facts() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local free total
  read -r total free < <(df -Pk "$(pg_data)" 2>/dev/null | awk 'NR == 2 { print $2 * 1024, $4 * 1024 }')
  [[ "$free" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$PG_SQL_QUIET
INSERT INTO aw.facts (key, value, updated_at) VALUES
  ('disk_free_bytes', '$free', now()), ('disk_total_bytes', '$total', now())
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;" | pg_sql "$(pg_db)"
}

# --- heartbeat ---------------------------------------------------------------------------
# The postgres surface file carries what the control plane needs to wire
# Hyperdrive (contract): {database, tls: {caPem, caSha256}, roles: [{name,
# secretSha256}], backup: {mode, lastBackupAt, lastBackupOk, lastDrillAt,
# lastDrillOk}}. Public material only: the CA certificate and the first 16
# hex of each password's sha256, so the control plane can tell its rotation
# landed. Roles are the ones the last reconcile set, still declared.
pg_report_json() {
  local roles='[]' names tls='null' pem declared backup
  declared="$(pg_roles)" || return 1
  names="$(printf '%s\n' "$declared" | cut -f1 | jq -Rsc 'split("\n") | map(select(length > 0))')"
  [[ -s "$(pg_roles_report)" ]] && roles="$(jq -c --argjson n "$names" '[.[]? | select(.name as $x | $n | index($x))]' "$(pg_roles_report)" 2>/dev/null || printf '[]')"
  if [[ "$(pg_tls)" == "on" && -s "$(pg_tls_ca_crt)" ]]; then
    pem="$(cat "$(pg_tls_ca_crt)")"
    tls="$(jq -nc --arg p "$pem"$'\n' --arg s "$(pg_tls_ca_sha256)" '{caPem:$p, caSha256:$s}')"
  fi
  backup="$(pg_br_report_json)" || return 1
  jq -nc --arg db "$(pg_db)" --argjson tls "$tls" --argjson roles "$roles" --argjson backup "$backup" \
    '{database:$db} + (if $tls == null then {} else {tls:$tls} end) + {roles:$roles, backup:$backup}'
}
pg_report() {
  local f out pg
  f="$(wl_services_dir)/$PG_ID.json"
  [[ -f "$f" && "$DRY_RUN" != "1" ]] || return 0
  pg="$(pg_report_json)" || return 1
  out="$(jq -c --argjson pg "$pg" '. + {postgres:$pg}' "$f")" || return 1
  printf '%s\n' "$out" | aw_write "$f"
  chmod 644 "$f" 2>/dev/null || true
}

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
  kv "tls" "$(pg_tls)$( [[ "$(pg_tls)" == "on" && -s "$(pg_tls_srv_dir)/server.crt" ]] && printf ' (server cert until %s)' "$(openssl x509 -enddate -noout -in "$(pg_tls_srv_dir)/server.crt" 2>/dev/null | cut -d= -f2)")"
  kv "roles" "$(pg_roles 2>/dev/null | awk -F'\t' '{ printf "%s%s%s", (NR > 1 ? ", " : ""), $1, ($2 == 1 ? " (owner)" : "") }')"
  local n; n="$(find "$(pg_root)/.snapshots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
  kv "snapshots" "$n"
  kv "dumps" "$(find "$(pg_backups)" -name '*.sql.gz' 2>/dev/null | wc -l)"
  if pg_br_on; then
    local st; st="$(cat "$(pg_br_status_file)" 2>/dev/null || printf '{}')"
    kv "backup" "pgbackrest → s3://$(pg_backup_bucket)$(pg_backup_path) ($(pg_backup_retention_days) days PITR, $(pg_backup_monthly_keep) monthly)"
    kv "last backup" "$(jq -r '(.lastBackupAt // "never") + (if .lastBackupOk == null then "" elif .lastBackupOk then " ok (" + (.lastBackupKind // "?") + ")" else " FAILED: " + (.lastBackupError // "") end)' <<<"$st")"
    kv "last drill" "$(jq -r '(.lastDrillAt // "never") + (if .lastDrillOk == null then "" elif .lastDrillOk then " ok" else " FAILED: " + (.lastDrillError // "") end)' <<<"$st")"
  else
    kv "backup" "off (logical dumps only; --backup pgbackrest for WAL archiving and PITR)"
  fi
  info "apps reach it through Hyperdrive at $(hostname)-postgres.<base> (see docs/SERVICES.md)"
}

# backup=off: a logical dump. backup=pgbackrest: a pgBackRest backup on
# demand (diff by default; --full, --incr, --monthly).
pg_backup() {
  if pg_br_on; then pg_br_backup "${1:---diff}"; return; fi
  [[ -z "${1:-}" ]] || die "postgres: '$1' needs backup=pgbackrest (with backup=off this is a pg_dumpall)"
  pg_dump_backup
}
pg_dump_backup() {
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

# aw service restore postgres <file.sql.gz>          a logical dump (psql)
# aw service restore postgres --to '<time>' --yes     PITR (backup=pgbackrest)
# aw service restore postgres --latest --yes          to the end of the archive
pg_restore() {
  case "${1:-}" in --to|--to=*|--latest|--yes) pg_br_restore "$@"; return ;; esac
  local file="${1:-}"
  [[ -n "$file" ]] || die "usage: aw service restore postgres <file.sql.gz> | --to '<time>' --yes | --latest --yes"
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
  pg_dump_backup
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

# --- backups: pgBackRest to an S3 repository (Cloudflare R2) -----------------------------
# backup=pgbackrest: WAL is archived continuously (archive_command, at most
# 60 s behind), a full backup runs weekly and a differential daily, and the
# repository is encrypted client-side (aes-256-cbc) before it leaves the node.
#   repo1  <backup_path>          14 days of PITR (retention-full-type=time:
#                                 every full needed to reach back that far is
#                                 kept, with its diffs and all their WAL)
#   repo2  <backup_path>-monthly  one full on the 1st of each month, the last
#                                 backup_monthly_keep kept (count); WAL only
#                                 for the newest full plus what each older one
#                                 needs to be consistent
# pgBackRest cannot keep "monthly for a year" beside a 14-day window in one
# repository (retention is per repository), hence two. The binary is in the
# PostgreSQL container (archive_command runs there): a node-built image, see
# Containerfile. Backups run there through `podman exec`; the restore drill
# and a PITR restore run in a throwaway container from the same image.
PG_BR_VERSION="2.59.3"                # Containerfile ARG PGBACKREST_VERSION
PG_BR_MNT="/etc/pgbackrest"           # where the container reads pgbackrest.conf
PG_BR_SECRETS=(PGBACKREST_R2_ACCESS_KEY_ID PGBACKREST_R2_SECRET_ACCESS_KEY PGBACKREST_CIPHER_PASS)
PG_BR_BIN="${AW_BIN:-/usr/local/bin/alwayswork}"
PG_PGDATA="/var/lib/postgresql/data/pgdata"

pg_backup_mode() { local b; b="$(cap_config backup)"; [[ -n "$b" ]] || b=off; case "$b" in off|pgbackrest) printf '%s' "$b" ;; *) die "services.postgres: bad backup '$b' (off|pgbackrest)" ;; esac; }
pg_br_on() { [[ "$(pg_backup_mode)" == "pgbackrest" ]]; }
pg_stanza() { pg_db; }
# https://<account>.r2.cloudflarestorage.com → the host[:port] pgBackRest takes.
pg_backup_endpoint() {
  local e; e="$(cap_config backup_endpoint)"
  [[ -n "$e" ]] || die "services.postgres: backup=pgbackrest needs backup_endpoint (https://<account>.r2.cloudflarestorage.com)"
  e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
  [[ "$e" =~ ^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+(:[0-9]{1,5})?)/?$ ]] \
    || die "services.postgres: bad backup_endpoint '$e' (https://<host>, no path)"
  printf '%s' "${BASH_REMATCH[1]}"
}
pg_backup_bucket() {
  local b; b="$(cap_config backup_bucket)"
  [[ -n "$b" ]] || die "services.postgres: backup=pgbackrest needs backup_bucket"
  [[ "$b" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "services.postgres: bad backup_bucket '$b'"
  printf '%s' "$b"
}
pg_node_name() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-' | head -c 63; }
pg_backup_path() {
  local p; p="$(cap_config backup_path)"
  [[ -n "$p" ]] || p="/$(pg_node_name)/$(pg_db)"
  [[ "$p" =~ ^(/[A-Za-z0-9._-]+)+$ && ! "$p" =~ (^|/)\.\.?(/|$) && ${#p} -le 200 ]] \
    || die "services.postgres: bad backup_path '$p' (/segment[/segment…], no . or ..)"
  printf '%s' "$p"
}
pg_backup_region() { local r; r="$(cap_config backup_region)"; [[ -n "$r" ]] || r=auto; [[ "$r" =~ ^[a-z0-9-]{1,32}$ ]] || die "services.postgres: bad backup_region '$r'"; printf '%s' "$r"; }
pg_backup_full_weeks() {
  local w; w="$(cap_config backup_retention_full_weeks)"; [[ -n "$w" ]] || w=2
  if ! [[ "$w" =~ ^[0-9]{1,2}$ ]] || (( 10#$w < 1 || 10#$w > 52 )); then die "services.postgres: bad backup_retention_full_weeks '$w' (1-52)"; fi
  printf '%s' "$(( 10#$w ))"
}
pg_backup_retention_days() { printf '%s' "$(( $(pg_backup_full_weeks) * 7 ))"; }
pg_backup_monthly_keep() {
  local n; n="$(cap_config backup_monthly_keep)"; [[ -n "$n" ]] || n=12
  if ! [[ "$n" =~ ^[0-9]{1,3}$ ]] || (( 10#$n > 120 )); then die "services.postgres: bad backup_monthly_keep '$n' (0-120)"; fi
  printf '%s' "$(( 10#$n ))"
}

# The node-built image: localhost/alwayswork-postgres:<base tag>-pgbackrest<v>-<h>,
# h over the base ref, the pgBackRest pin and the Containerfile — any of them
# changing is a new tag, so a new channel version or pin rebuilds.
pg_br_image() {
  local base tag h
  base="$(pg_base_image)"
  if [[ "$base" == *@sha256:* ]]; then tag="sha256-${base##*@sha256:}"; tag="${tag:0:19}"
  else tag="${base##*/}"; if [[ "$tag" == *:* ]]; then tag="${tag##*:}"; else tag=latest; fi; fi
  tag="$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_.-' '-' | head -c 64)"
  h="$( { printf '%s\n%s\n' "$base" "$PG_BR_VERSION"; cat "$CAP_DIR/Containerfile" 2>/dev/null; } | sha256sum | cut -c1-8)"
  printf 'localhost/alwayswork-postgres:%s-pgbackrest%s-%s' "$tag" "$PG_BR_VERSION" "$h"
}
pg_br_ensure_image() {
  WL_PULL="$(cap_config pull)" WL_BUILD=true wl_ensure_image "$(pg_br_image)" "$CAP_DIR" \
    --build-arg "BASE=$(pg_base_image)" --build-arg "PGBACKREST_VERSION=$PG_BR_VERSION"
}

# Names of the group secrets still missing (or unusable: a line break would
# end the config line). Names only — never a value.
pg_backup_missing_secrets() {
  local k v
  for k in "${PG_BR_SECRETS[@]}"; do
    v="$(sec_get "$k")"
    [[ -n "$v" && "$v" != *$'\n'* && "$v" != *$'\r'* ]] || printf '%s\n' "$k"
  done
}
# Every backup setting valid and every secret present, or a clear refusal.
pg_backup_check() {
  pg_backup_endpoint >/dev/null; pg_backup_bucket >/dev/null; pg_backup_path >/dev/null
  pg_backup_region >/dev/null; pg_backup_full_weeks >/dev/null; pg_backup_monthly_keep >/dev/null
  local missing; missing="$(pg_backup_missing_secrets)"
  if [[ -n "$missing" ]]; then
    err "services.postgres: backup=pgbackrest needs the group secret(s) $(printf '%s' "$missing" | paste -sd, - | sed 's/,/, /g') — put them with the control plane's secrets API (docs/SERVICES.md); WAL archiving stays off until they arrive"
    return 1
  fi
}

pg_br_dir()         { printf '%s' "$(pg_root)/pgbackrest"; }
pg_br_conf()        { printf '%s' "$(pg_br_dir)/pgbackrest.conf"; }
pg_br_status_file() { printf '%s' "$(pg_root)/backup-status.json"; }
pg_br_stanza_mark() { printf '%s' "$(pg_root)/pgbackrest.stanza"; }
pg_drill_dir()      { printf '%s' "$(pg_root)/drill"; }
pg_restore_lock()   { printf '%s' "$(pg_root)/restore.lock"; }

# The whole pgBackRest configuration. Its three secrets are in here and
# nowhere else (pgBackRest reads repo keys and the cipher pass from its
# config file; they are redacted from its own logs).
pg_br_conf_text() {
  local path days keep
  path="$(pg_backup_path)"; days="$(pg_backup_retention_days)"; keep="$(pg_backup_monthly_keep)"
  local key secret cipher
  key="$(sec_get PGBACKREST_R2_ACCESS_KEY_ID)"; secret="$(sec_get PGBACKREST_R2_SECRET_ACCESS_KEY)"; cipher="$(sec_get PGBACKREST_CIPHER_PASS)"
  local -a repos=(1); (( keep > 0 )) && repos+=(2)
  local r
  printf '%s\n' "# Managed by alwayswork (services.postgres, backup=pgbackrest); rewritten on apply." \
    "# 0600: holds the R2 access key and the repository cipher passphrase." "[global]"
  for r in "${repos[@]}"; do
    printf '%s\n' "repo$r-type=s3" "repo$r-s3-endpoint=$(pg_backup_endpoint)" "repo$r-s3-bucket=$(pg_backup_bucket)" \
      "repo$r-s3-region=$(pg_backup_region)" "repo$r-s3-uri-style=path" \
      "repo$r-s3-key=$key" "repo$r-s3-key-secret=$secret" \
      "repo$r-cipher-type=aes-256-cbc" "repo$r-cipher-pass=$cipher" "repo$r-bundle=y"
    if [[ "$r" == 1 ]]; then
      printf '%s\n' "repo1-path=$path" "repo1-retention-full-type=time" "repo1-retention-full=$days"
    else
      printf '%s\n' "repo2-path=$path-monthly" "repo2-retention-full-type=count" "repo2-retention-full=$keep" \
        "repo2-retention-archive-type=full" "repo2-retention-archive=1"
    fi
  done
  printf '%s\n' "start-fast=y" "compress-type=zst" "process-max=2" "archive-async=n" \
    "log-level-console=info" "log-level-file=off" "lock-path=/tmp/pgbackrest" \
    "" "[$(pg_stanza)]" "pg1-path=$PG_PGDATA" "pg1-socket-path=/var/run/postgresql" "pg1-user=postgres"
}
# Render into <dir>/pgbackrest.conf (dir 0700, file 0600). An identical file
# is left alone: the running container owns it (:U) and a rewrite would hand
# it back to root under a live archive_command.
pg_br_render() {
  local dir="${1:-$(pg_br_dir)}" dest tmp
  dest="$dir/pgbackrest.conf"
  if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] render %s (0600)\n' "$dest" >&2; return 0; fi
  ensure_dir "$dir"; chmod 700 "$dir"
  tmp="$(mktemp "$dir/.pgbackrest.conf.XXXXXX")" || die "services.postgres: cannot stage pgbackrest.conf"
  chmod 600 "$tmp"
  pg_br_conf_text > "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  mv -f "$tmp" "$dest"; chmod 600 "$dest"
}

# Secret values out of anything printed or recorded.
pg_br_redact() {
  local text k v
  text="$(cat)"
  for k in "${PG_BR_SECRETS[@]}"; do
    v="$(sec_get "$k")"
    [[ -n "$v" ]] && text="${text//"$v"/***}"
  done
  printf '%s\n' "$text"
}
# One short line for aw.facts: the last ERROR line (else the last line),
# redacted, printable, at most 200 characters.
pg_short_error() {
  local line
  line="$(grep -E 'ERROR|FATAL|AW_DRILL_FAIL|error' "$1" 2>/dev/null | tail -1)"
  [[ -n "$line" ]] || line="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1)"
  [[ -n "$line" ]] || line="${2:-failed without output}"
  printf '%s' "$line" | pg_br_redact | tr -d '\000-\037' | cut -c1-200
}
pg_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# aw.facts upsert: pg_facts_put key value [key value …]. Values travel hex
# encoded, so nothing in them can break the SQL; keys are fixed identifiers.
pg_facts_put() {
  local sql="" k v
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    [[ "$k" =~ ^[a-z_]{1,63}$ ]] || return 1
    sql+="${sql:+,
}  ('$k', convert_from(decode('$(pg_hex "$v")', 'hex'), 'UTF8'), now())"
  done
  [[ -n "$sql" ]] || return 0
  printf '%s\n' "$PG_SQL_QUIET
INSERT INTO aw.facts (key, value, updated_at) VALUES
$sql
  ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;" | pg_sql "$(pg_db)"
}
# pg_br_note backup|drill <ok 1|0> <kind> <error>: the node's record of the
# last run (heartbeat), aw.facts (aw.status) and the heartbeat surface.
pg_br_note() {
  local what="$1" okv="$2" kind="$3" err="$4" at f cur b=false
  at="$(pg_now)"; [[ "$okv" == "1" ]] && b=true
  f="$(pg_br_status_file)"; cur="$(cat "$f" 2>/dev/null || true)"; [[ "$cur" == \{* ]] || cur='{}'
  ensure_dir "$(pg_root)"
  if [[ "$what" == "backup" ]]; then
    jq -c --arg at "$at" --argjson ok "$b" --arg k "$kind" --arg e "$err" '. + {lastBackupAt:$at, lastBackupOk:$ok, lastBackupKind:$k, lastBackupError:$e}' <<<"$cur" | aw_write "$f"
    pg_facts_put last_backup_at "$at" last_backup_ok "$b" last_backup_kind "$kind" last_backup_error "$err" \
      || warn "services.postgres: could not record the backup in aw.facts (is postgres up?)"
  else
    jq -c --arg at "$at" --argjson ok "$b" --arg e "$err" '. + {lastDrillAt:$at, lastDrillOk:$ok, lastDrillError:$e}' <<<"$cur" | aw_write "$f"
    pg_facts_put last_restore_drill_at "$at" last_restore_drill_ok "$b" last_restore_drill_error "$err" \
      || warn "services.postgres: could not record the drill in aw.facts (is postgres up?)"
  fi
  chmod 644 "$f" 2>/dev/null || true
  pg_report >/dev/null 2>&1 || true
}
# The heartbeat's backup object: state only, never a secret or a location.
pg_br_report_json() {
  local mode st
  mode="$(pg_backup_mode)" || return 1
  st="$(cat "$(pg_br_status_file)" 2>/dev/null || true)"; [[ "$st" == \{* ]] || st='{}'
  jq -c --arg m "$mode" '{mode:$m, lastBackupAt:(.lastBackupAt // null), lastBackupOk:(.lastBackupOk // null), lastDrillAt:(.lastDrillAt // null), lastDrillOk:(.lastDrillOk // null)}' <<<"$st"
}

# pgBackRest in the live container (uid 999, the socket, peer auth).
pg_br_exec() { pg_exec pgbackrest --stanza="$(pg_stanza)" "$@" </dev/null; }

# Stanza: created once per repository layout (idempotent in pgBackRest
# too), then `check` proves archive_command reaches the repository. The first
# success starts a full backup so PITR does not wait for Sunday.
pg_br_stanza_ensure() {
  [[ "$DRY_RUN" == "1" ]] && { info "services.postgres: dry-run — would stanza-create and check $(pg_stanza)"; return 0; }
  local want out e
  want="$(sha256sum < "$(pg_br_conf)" | cut -c1-16)"
  [[ "$(cat "$(pg_br_stanza_mark)" 2>/dev/null)" == "$want" ]] && return 0
  out="$(mktemp)"
  if pg_br_exec stanza-create >"$out" 2>&1 && pg_br_exec check >>"$out" 2>&1; then
    rm -f "$out"
    printf '%s\n' "$want" > "$(pg_br_stanza_mark)"
    ok "pgBackRest stanza $(pg_stanza) ready; WAL is archived to s3://$(pg_backup_bucket)$(pg_backup_path)"
    if [[ ! -s "$(pg_br_status_file)" ]] || ! jq -e '.lastBackupOk == true' "$(pg_br_status_file)" >/dev/null 2>&1; then
      run systemctl start --no-block "alwayswork-postgres-backup-full.service" || true
      info "services.postgres: first full backup started (alwayswork-postgres-backup-full.service)"
    fi
    return 0
  fi
  e="$(pg_short_error "$out" "stanza-create/check failed")"
  pg_br_redact < "$out" >&2; rm -f "$out"
  pg_br_note backup 0 stanza "stanza: $e"
  warn "services.postgres: pgBackRest stanza-create/check failed ($e); WAL piles up in pg_wal until the repository answers — the next apply retries"
  return 1
}

# Schedules (node-local time; Persistent catches up after downtime):
#   full     Sun 03:00          diff  Mon..Sat 03:00
#   monthly  1st of month 05:00 (repo2; off with backup_monthly_keep=0)
#   drill    Wed 04:00
PG_BR_TIMERS=(postgres-backup-full postgres-backup-diff postgres-backup-monthly postgres-restore-drill)
pg_br_timers_apply() {
  local -a on=(postgres-backup-full postgres-backup-diff postgres-restore-drill)
  wl_write_timer postgres-backup-full "PostgreSQL weekly full backup (pgBackRest)" "Sun *-*-* 03:00:00" 10m 6h \
    "$PG_BR_BIN" service backup postgres --full
  wl_write_timer postgres-backup-diff "PostgreSQL daily differential backup (pgBackRest)" "Mon..Sat *-*-* 03:00:00" 10m 6h \
    "$PG_BR_BIN" service backup postgres --diff
  if (( $(pg_backup_monthly_keep) > 0 )); then
    wl_write_timer postgres-backup-monthly "PostgreSQL monthly full backup (pgBackRest repo2)" "*-*-01 05:00:00" 10m 12h \
      "$PG_BR_BIN" service backup postgres --monthly
    on+=(postgres-backup-monthly)
  else
    wl_remove_timer postgres-backup-monthly
  fi
  wl_write_timer postgres-restore-drill "PostgreSQL weekly restore drill" "Wed *-*-* 04:00:00" 10m 45min \
    "$PG_BR_BIN" service drill postgres
  wl_apply_timers "${on[@]}"
}
# backup=off (or remove): no schedules, no secrets on disk. The repository
# and its backups stay where they are.
pg_br_disable() {
  local t
  for t in "${PG_BR_TIMERS[@]}"; do wl_remove_timer "$t" || return 1; done
  [[ -e "$(pg_br_dir)" ]] && run rm -rf "$(pg_br_dir)"
  [[ -e "$(pg_br_stanza_mark)" ]] && run rm -f "$(pg_br_stanza_mark)"
  return 0
}

# aw service backup postgres [--diff|--full|--incr|--monthly]
pg_br_backup() {
  local kind type repo=1 out e
  case "$1" in
    --full) kind="full"; type="full" ;;
    --diff) kind="diff"; type="diff" ;;
    --incr) kind="incr"; type="incr" ;;
    --monthly) kind="monthly"; type="full"; repo=2
      (( $(pg_backup_monthly_keep) > 0 )) || die "postgres: backup_monthly_keep=0 — there is no monthly repository" ;;
    *) die "usage: aw service backup postgres [--diff|--full|--incr|--monthly]" ;;
  esac
  log "postgres: pgBackRest $kind backup -> repo$repo"
  if [[ "$DRY_RUN" == "1" ]]; then info "dry-run: pgbackrest --stanza=$(pg_stanza) --repo=$repo --type=$type backup"; return 0; fi
  out="$(mktemp)"
  if pg_br_exec --repo="$repo" --type="$type" backup >"$out" 2>&1; then
    pg_br_redact < "$out" >&2; rm -f "$out"
    pg_br_note backup 1 "$kind" ""
    ok "postgres: $kind backup done (repo$repo)"
    return 0
  fi
  e="$(pg_short_error "$out" "backup failed")"
  pg_br_redact < "$out" >&2; rm -f "$out"
  pg_br_note backup 0 "$kind" "$e"
  die "postgres: $kind backup failed: $e"
}

# A throwaway container from the live image: rootless-mapped, capability-free,
# no published port, on the workload network only for the repository.
# pg_br_run <seconds> <name> <podman run args…> — bounded by timeout(1).
pg_br_run() {
  local secs="$1" name="$2"; shift 2
  local net; net="$(cap_config network)"; [[ -n "$net" ]] || net=alwayswork
  engine_build_args
  local -a cmd=(podman run --rm --name "$name" "${AW_ENGINE_ARGS[@]}" --userns=auto --user 999:999 --network "$net"
    --shm-size 256m --label "dev.alwayswork.service=postgres" --label "dev.alwayswork.job_of=$PG_ID" "$@")
  run podman rm -f --ignore "$name" >/dev/null 2>&1 || true
  local rc=0
  if have timeout; then run timeout -k 60 "$secs" "${cmd[@]}" || rc=$?; else run "${cmd[@]}" || rc=$?; fi
  run podman rm -f --ignore "$name" >/dev/null 2>&1 || true
  return "$rc"
}

# The drill's script, run as uid 999 inside the throwaway container: restore
# the latest backup and every archived WAL after it (the archive is drilled
# too), start PostgreSQL socket-only with archiving OFF (a drill must never
# push WAL into the repository), wait for recovery to finish, answer a query.
pg_drill_script() {
  cat <<'SH'
#!/bin/sh
# Managed by alwayswork (services.postgres): restore drill. Scratch data only.
set -eu
stanza="$1"; db="$2"; D=/var/lib/postgresql/data/pgdata
mkdir -p -m 0700 "$D"
pgbackrest --stanza="$stanza" --repo=1 --pg1-path="$D" restore
postgres -D "$D" -c archive_mode=off -c "listen_addresses=" -c unix_socket_directories=/tmp \
  -c hba_file=/etc/alwayswork/pg/pg_hba.conf >/tmp/postgres.log 2>&1 &
pid=$!
q() { psql -X -At -h /tmp -U postgres -d postgres -c "$1" </dev/null 2>/dev/null; }
i=0
until [ "$(q 'SELECT pg_is_in_recovery()')" = f ]; do
  kill -0 "$pid" 2>/dev/null || { tail -n 20 /tmp/postgres.log >&2; echo "AW_DRILL_FAIL postgres exited during recovery"; exit 1; }
  i=$((i + 1)); [ "$i" -lt 1700 ] || { echo "AW_DRILL_FAIL recovery did not finish"; exit 1; }
  sleep 1
done
n="$(q 'SELECT count(*) FROM pg_database')"
has="$(q "SELECT count(*) FROM pg_database WHERE datname = '$db'")"
pg_ctl -D "$D" -m fast -w stop >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
[ "$has" = 1 ] || { echo "AW_DRILL_FAIL database $db is not in the restore"; exit 1; }
echo "AW_DRILL_OK databases=$n"
SH
}

# aw service drill postgres — the weekly restore drill. Restores into
# <root>/drill (never the live data directory), refuses without 1.2x the
# data directory's size free, at most 30 minutes, and deletes the scratch
# copy whatever happens. The result goes to aw.facts and the heartbeat.
PG_DRILL_TIMEOUT="${PG_DRILL_TIMEOUT:-1800}"
pg_drill() {
  pg_br_on || die "postgres: restore drills need backup=pgbackrest"
  local scratch size free need out e rc=0
  scratch="$(pg_drill_dir)"
  log "postgres: restore drill (latest backup + archive -> scratch container)"
  if [[ "$DRY_RUN" == "1" ]]; then info "dry-run: pgbackrest restore into $scratch, start, SELECT count(*) FROM pg_database, delete"; return 0; fi
  pg_backup_check || { pg_br_note drill 0 "" "backup secrets missing"; die "postgres: restore drill refused"; }
  size="$(du -sk "$(pg_data)" 2>/dev/null | cut -f1)"; free="$(df -Pk "$(pg_root)" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$size" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] || { pg_br_note drill 0 "" "cannot measure disk"; die "postgres: restore drill: cannot measure disk"; }
  need=$(( size * 12 / 10 ))
  if (( free < need )); then
    e="not enough disk: $(( free / 1024 )) MiB free, $(( need / 1024 )) MiB needed (1.2x data)"
    pg_br_note drill 0 "" "$e"; die "postgres: restore drill refused: $e"
  fi
  [[ -e "$scratch" ]] && run rm -rf "$scratch"
  ensure_dir "$scratch/data"; chmod 700 "$scratch"
  pg_br_render "$scratch/conf" || { run rm -rf "$scratch"; die "postgres: restore drill: cannot render its config"; }
  pg_drill_script > "$scratch/drill.sh"; chmod 755 "$scratch/drill.sh"
  out="$(mktemp)"
  pg_br_run "$PG_DRILL_TIMEOUT" "alwayswork-postgres-drill" \
    --volume "$scratch/data:/var/lib/postgresql/data:U" \
    --volume "$scratch/conf:$PG_BR_MNT:ro,U" \
    --volume "$(pg_conf_dir):$PG_CONF_MNT:ro" \
    --volume "$scratch/drill.sh:/usr/local/bin/alwayswork-drill:ro" \
    --entrypoint /bin/sh "$(pg_image)" /usr/local/bin/alwayswork-drill "$(pg_stanza)" "$(pg_db)" >"$out" 2>&1 || rc=$?
  run rm -rf "$scratch"
  if (( rc == 0 )) && grep -q '^AW_DRILL_OK' "$out"; then
    info "$(grep '^AW_DRILL_OK' "$out" | tail -1)"; rm -f "$out"
    pg_br_note drill 1 "" ""
    ok "postgres: restore drill passed (scratch copy removed)"
    return 0
  fi
  if (( rc == 124 || rc == 137 )); then e="timed out after ${PG_DRILL_TIMEOUT}s"; else e="$(pg_short_error "$out" "drill failed (exit $rc)")"; fi
  pg_br_redact < "$out" | tail -n 40 >&2; rm -f "$out"
  pg_br_note drill 0 "" "$e"
  die "postgres: restore drill failed: $e"
}

# aw service restore postgres --to '<time>' --yes | --latest --yes
# Point-in-time recovery into the live data directory — an operator runbook
# step. The service stops, the current data directory is MOVED aside (never
# deleted), pgBackRest restores into a fresh one, the service starts and
# replays WAL to the target, promotes, and is verified. A failed restore puts
# the previous directory back. A full backup is started afterwards (new
# timeline).
PG_TIME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?( ?(Z|UTC|[+-][0-9]{2}(:?[0-9]{2})?))?$'
pg_br_restore() {
  local target="" latest=0 yes="${ASSUME_YES:-0}"
  while (( $# )); do
    case "$1" in
      --to) target="${2:-}"; shift 2 || shift ;;
      --to=*) target="${1#--to=}"; shift ;;
      --latest) latest=1; shift ;;
      --yes|-y) yes=1; shift ;;
      *) die "postgres: unknown restore option '$1'" ;;
    esac
  done
  [[ -n "$target" || "$latest" == 1 ]] || die "usage: aw service restore postgres --to '<YYYY-MM-DD HH:MM:SS+00>' --yes | --latest --yes"
  [[ -z "$target" || "$latest" == 0 ]] || die "postgres: --to and --latest are exclusive"
  [[ -z "$target" || "$target" =~ $PG_TIME_RE ]] || die "postgres: bad --to '$target' (e.g. '2026-10-17 09:30:00+00')"
  pg_br_on || die "postgres: point-in-time restore needs backup=pgbackrest (a dump restores with: aw service restore postgres <file.sql.gz>)"
  [[ "$yes" == "1" ]] || die "postgres: this replaces the live database with the backup at ${target:-the end of the archive}; the current data directory is moved aside, never deleted. Re-run with --yes"
  local stamp aside failed conf lock
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  aside="$(pg_data).before-restore-$stamp"; failed="$(pg_data).failed-restore-$stamp"
  conf="$(pg_root)/restore-conf"; lock="$(pg_restore_lock)"
  log "postgres: point-in-time restore to ${target:-the latest archived WAL}"
  local -a args=(--stanza="$(pg_stanza)" --repo=1 --pg1-path="$PG_PGDATA")
  [[ -n "$target" ]] && args+=(--type=time "--target=$target" --target-action=promote)
  if [[ "$DRY_RUN" == "1" ]]; then
    info "dry-run: stop $(pg_unit); mv $(pg_data) $aside; pgbackrest ${args[*]} restore; start; verify"
    return 0
  fi
  pg_backup_check || die "postgres: restore refused"
  [[ -e "$aside" ]] && die "postgres: $aside already exists"
  ensure_dir "$(pg_root)"; : > "$lock"
  # shellcheck disable=SC2064  # expand now: the paths are fixed for this run
  trap "rm -f '$lock'; rm -rf '$conf'" EXIT
  run systemctl stop "$(pg_unit)" || die "postgres: could not stop $(pg_unit)"
  run mv "$(pg_data)" "$aside" || { run systemctl start "$(pg_unit)"; die "postgres: could not move the data directory aside"; }
  info "previous data directory kept at $aside"
  wl_subvolume "$(pg_data)"
  [[ -e "$conf" ]] && run rm -rf "$conf"
  pg_br_render "$conf" || die "postgres: cannot render the restore config (previous data at $aside)"
  # shellcheck disable=SC2016  # $0/$@ belong to the container's shell
  if ! pg_br_run "${PG_RESTORE_TIMEOUT:-21600}" "alwayswork-postgres-restore" \
      --volume "$(pg_data):/var/lib/postgresql/data:U" \
      --volume "$conf:$PG_BR_MNT:ro,U" \
      --entrypoint /bin/sh "$(pg_image)" -c 'mkdir -p -m 0700 "$0" && exec pgbackrest "$@" restore' "$PG_PGDATA" "${args[@]}"; then
    run mv "$(pg_data)" "$failed"; run mv "$aside" "$(pg_data)"
    run systemctl start "$(pg_unit)"
    die "postgres: pgBackRest restore failed; the previous data directory is back in place and running (the failed attempt is kept at $failed)"
  fi
  run rm -rf "$conf"
  run systemctl start "$(pg_unit)" || die "postgres: could not start $(pg_unit) (previous data at $aside)"
  PG_READY_TRIES="${PG_READY_TRIES:-900}" pg_wait_ready || die "postgres: the restored server did not come up (previous data at $aside; journalctl -u $(pg_unit))"
  local i rec
  for (( i = 0; i < ${PG_READY_TRIES:-900}; i++ )); do
    rec="$(pg_exec psql -X -At -U postgres -d postgres -c 'SELECT pg_is_in_recovery()' </dev/null 2>/dev/null)" || true
    [[ "$rec" == "f" ]] && break
    sleep 2
  done
  [[ "$rec" == "f" ]] || die "postgres: still in recovery (paused short of the target?); previous data at $aside"
  local n has
  n="$(pg_exec psql -X -At -U postgres -d postgres -c 'SELECT count(*) FROM pg_database' </dev/null 2>/dev/null)" || true
  has="$(pg_exec psql -X -At -U postgres -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$(pg_db)'" </dev/null 2>/dev/null)" || true
  [[ "$has" == "1" ]] || die "postgres: restored, but database $(pg_db) is missing (previous data at $aside)"
  ok "postgres: restored to ${target:-the end of the archive} ($n databases); previous data kept at $aside — remove it once satisfied"
  run systemctl start --no-block "alwayswork-postgres-backup-full.service" || true
  info "a full backup of the new timeline has been started"
}

# --- aw service <action> postgres ------------------------------------------------------
# commands/service.sh calls <id>_<action>.
postgres_status()   { pg_status "$@"; }
postgres_logs()     { pg_logs "$@"; }
postgres_snapshot() { pg_snapshot "$@"; }
postgres_backup()   { pg_backup "$@"; }
postgres_restore()  { pg_restore "$@"; }
postgres_drill()    { pg_drill "$@"; }
postgres_upgrade()  { pg_upgrade "$@"; }
postgres_psql()     { pg_psql "$@"; }
