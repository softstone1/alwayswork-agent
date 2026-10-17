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
# Secrets (sealed store): POSTGRES_PASSWORD (superuser) and
# POSTGRES_APP_PASSWORD are generated here and node-owned — a delivered group
# secret never replaces them. PG_ROLE_<NAME>_PASSWORD is generated when
# absent but a delivered value wins: that is how the control plane rotates,
# and the next apply ALTERs the role. Every apply reconciles roles, the `aw`
# schema (aw.facts, aw.status) and the heartbeat's `postgres` object
# (database, CA certificate, per-role password fingerprints — never a secret).

PG_ID="postgres"
PG_IMAGE_REPO_DEFAULT="docker.io/library/postgres"

pg_version() { local v; v="$(cap_config version)"; [[ -n "$v" ]] || v="$(wl_manifest_get services.postgres '.workload.image.version.pinned')"; [[ -n "$v" ]] || v=16; [[ "$v" =~ ^[0-9]{2}(\.[0-9]+)?$ ]] || die "services.postgres: bad version '$v'"; printf '%s' "$v"; }
pg_image()   { local i; i="$(cap_config image)"; [[ -n "$i" ]] || i="${PG_IMAGE_REPO_DEFAULT}:$(pg_version)"; printf '%s' "$i"; }
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
  WL_VOLUMES=("$(pg_data):/var/lib/postgresql/data:U" "$(pg_root)/init:/docker-entrypoint-initdb.d:ro" "$(pg_conf_dir):$PG_CONF_MNT:ro")
  WL_ARGS=(postgres -c "hba_file=$PG_CONF_MNT/pg_hba.conf" -c password_encryption=scram-sha-256)
  if [[ "$(pg_tls)" == "on" ]]; then
    WL_VOLUMES+=("$(pg_tls_srv_dir):$PG_TLS_MNT:ro,U")
    WL_ARGS+=(-c ssl=on -c "ssl_cert_file=$PG_TLS_MNT/server.crt" -c "ssl_key_file=$PG_TLS_MNT/server.key" -c ssl_min_protocol_version=TLSv1.2)
  fi
  WL_ENV_FILE="$(pg_env_file)"
  # A new certificate or hba is read at start: their digest in the unit
  # restarts this container when they change, like the env file's.
  local conf
  conf="$(cat "$(pg_hba_file)" "$(pg_tls_srv_dir)/server.crt" 2>/dev/null | sha256sum | cut -c1-16)"
  WL_LABELS=("dev.alwayswork.workload=$PG_ID" "dev.alwayswork.service=postgres" "dev.alwayswork.pg_conf=$conf")
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
# read without superuser — server, size, archiving, and the facts the node
# records (disk now; backups and restore drills when those land).
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
       (SELECT max(updated_at) FROM aw.facts) AS updated_at
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
# secretSha256}]}. Public material only: the CA certificate and the first 16
# hex of each password's sha256, so the control plane can tell its rotation
# landed. Roles are the ones the last reconcile set, still declared.
pg_report_json() {
  local roles='[]' names tls='null' pem declared
  declared="$(pg_roles)" || return 1
  names="$(printf '%s\n' "$declared" | cut -f1 | jq -Rsc 'split("\n") | map(select(length > 0))')"
  [[ -s "$(pg_roles_report)" ]] && roles="$(jq -c --argjson n "$names" '[.[]? | select(.name as $x | $n | index($x))]' "$(pg_roles_report)" 2>/dev/null || printf '[]')"
  if [[ "$(pg_tls)" == "on" && -s "$(pg_tls_ca_crt)" ]]; then
    pem="$(cat "$(pg_tls_ca_crt)")"
    tls="$(jq -nc --arg p "$pem"$'\n' --arg s "$(pg_tls_ca_sha256)" '{caPem:$p, caSha256:$s}')"
  fi
  jq -nc --arg db "$(pg_db)" --argjson tls "$tls" --argjson roles "$roles" \
    '{database:$db} + (if $tls == null then {} else {tls:$tls} end) + {roles:$roles}'
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
