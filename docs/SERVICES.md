# Services as workloads

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.

The node side of `docs/SYSTEM_SPEC.md` §12.7 (control repo). A node's
capacity is for agents *and* for the traditional services an application
needs. Both run on the same container contract (`lib/workload.sh`,
`docs/WORKLOADS.md`); what differs for a service is state and reach.

## `services.postgres`

```bash
sudo aw enable services.postgres                 # PostgreSQL 16 on 127.0.0.1:5432
sudo aw enable services.postgres --version 17 --db shop --user shop --memory_mb 3072
```

What it does:

| | |
|---|---|
| Image | `docker.io/library/postgres:<version>` (or `image` override, digest form welcome) |
| Runs as | uid 999 from the start, `cap-drop ALL`, `no-new-privileges`, `userns=auto`, cgroup budget (`memory_mb`) |
| Data | `/var/lib/alwayswork/services/postgres/data` — a btrfs subvolume where the host has btrfs |
| First start | creates `POSTGRES_DB` and the app role (`user`) as its owner; both passwords generated into the sealed store (`POSTGRES_PASSWORD`, `POSTGRES_APP_PASSWORD`), never printed |
| Every apply | TLS certificate, managed `pg_hba.conf`, declared `roles`, the `aw` schema and the heartbeat's `postgres` object are reconciled |
| Health | `pg_isready` every 30 s; a failing check stops the container and systemd restarts it; reported on heartbeat |
| Reach | published to `127.0.0.1:5432` only; reported to the control plane as `expose.services`, which adds `<node>-postgres.<base>` → `tcp://127.0.0.1:5432` to the node's tunnel |

Config keys beyond the basics: `roles`, `tls`, `hostnames`, `admin`,
`admin_port`, `memory_mb` (see the header of
`capabilities/services.postgres/postgres.sh`).

### TLS

`tls` is `on` by default. On apply the node keeps a private CA under
`/var/lib/alwayswork/services/postgres/tls/` (EC P-256, 10 years; `ca.key`
0600 root-only in a 0700 directory, **never mounted** into the container)
and a server certificate signed by it (2 years; SAN `DNS:localhost`,
`IP:127.0.0.1` plus every name in `hostnames`, a comma list — put the tunnel
name `<node>-postgres.<base>` there for `verify-full`). The server
certificate (not the CA) is reissued when it is within 30 days of expiry,
no longer verifies against the CA, or the names change. Only `tls/server/`
is mounted, read-only with `:U`: under `userns=auto` the container's uid 999
maps to a host range chosen at start, so podman hands the files to that uid
on every start, which is what PostgreSQL requires of a 0600 key. Postgres
starts with `ssl=on`, `ssl_min_protocol_version=TLSv1.2` and
`password_encryption=scram-sha-256`. A changed certificate or hba changes the
unit (a digest label) and restarts the container. `openssl` is required on
the node while `tls=on`.

### Client authentication (managed `pg_hba.conf`)

Always rendered by the node and passed with `hba_file`, so the image's own
rules never apply:

```
local    all  postgres             peer
hostssl  all  all      0.0.0.0/0   scram-sha-256
hostssl  all  all      ::/0        scram-sha-256
```

The socket is `peer` for the superuser only: the image's init scripts,
`aw service psql` and the node's reconcile all run as uid 999 (`postgres`)
inside the container, so no password and no `trust` is needed. TCP is
password-only, and TLS-only while `tls=on`; `tls=off` renders `host` instead
of `hostssl` and logs a warning. There is never a `trust` rule on TCP.

### Roles

`roles` declares login roles: a comma list of `name` or `name:owner` (at most
8; names `^[a-z_][a-z0-9_]{0,46}$` so `PG_ROLE_<NAME>_PASSWORD` stays a valid
64-character env name; `postgres` and `pg_*` refused; at most one `:owner`,
which becomes owner of `db`). Every apply, once the server answers: missing
roles are created `LOGIN`, every declared role's password is set from the
sealed secret `PG_ROLE_<NAME uppercased>_PASSWORD` (generated, 40 characters,
when absent), and a role removed from the list is set `NOLOGIN` — never
dropped. The SQL is piped to `psql` over the socket on stdin; a password is
sent hex-encoded in a psql variable and decoded server-side into
`ALTER ROLE … PASSWORD`, with statement logging turned off for the session,
so it never appears in argv, a log line or the server log. The legacy `user`
role keeps working: its password stays `POSTGRES_APP_PASSWORD`, and it owns
`db` unless a role is declared `:owner`.

```bash
sudo aw enable services.postgres --db shop --roles shop_app:owner,shop_ro --hostnames kitchen-postgres.alwayswork.space
```

### Secrets

| Key | Made by | A delivered group secret of the same name |
|---|---|---|
| `POSTGRES_PASSWORD` (superuser) | the node | is skipped (warning names the key only) — node-owned |
| `POSTGRES_APP_PASSWORD` (legacy `user`) | the node | is skipped — node-owned |
| `PG_ROLE_<NAME>_PASSWORD` | the node when absent | **wins**; the next apply ALTERs the role (how the control plane rotates) |

Node-owned keys are listed (names only) in
`/var/lib/alwayswork/secrets-node-owned.list`.

### `aw.status`

Every apply (re)creates, in `db`, owned by `postgres`: the table
`aw.facts(key, value, updated_at)` and the one-row view `aw.status` —
`server_version`, `connections`, `max_connections`, `db_size_bytes`,
`archived_count`, `last_archived_at`, `last_failed_at`,
`archive_lag_seconds` (null while archiving is off), and from `aw.facts`:
`disk_free_bytes`, `disk_total_bytes` (the data directory, refreshed on apply
and by the healthcheck, which never fails on it), `last_backup_at`,
`last_backup_ok`, `last_restore_drill_at`, `last_restore_drill_ok` (null until
backups report them), `updated_at`. Every declared role gets `USAGE` on
schema `aw` and `SELECT` on `aw.status` (not on `aw.facts`).

### Heartbeat

The `postgres` entry of `expose.services` carries an extra object:

```json
"postgres": {
  "database": "shop",
  "tls": { "caPem": "-----BEGIN CERTIFICATE-----…", "caSha256": "<sha256 of the CA cert DER, 64 hex>" },
  "roles": [ { "name": "shop_app", "secretSha256": "<first 16 hex of sha256(password)>" } ]
}
```

`tls` is omitted while `tls=off`. `roles` lists only declared roles whose
last reconcile succeeded with the password fingerprinted, so the control
plane can tell a rotation landed. Nothing secret is in it: the CA
certificate is public and a password appears only as that fingerprint.

### Web admin

`admin` is **off** by default — a browser path into a production database
is opted into. `--admin pgweb` (or `on`) runs the `pgweb` side-car
(`alwayswork-postgres-admin`: pinned image, read-only, loopback port 8081,
connects as the application role over the workload network with
`sslmode=require` while `tls=on`). It is the service's `http` surface,
reached as `<node>-postgres-admin.<base>` behind Access; `--admin_port`
moves it.

Operations — the same audited path an agent uses through its tools:

```bash
aw service list                           # every service, health
aw service status postgres
aw service logs postgres [lines]
aw service snapshot postgres [label]      # CHECKPOINT + read-only btrfs snapshot of the data subvolume
aw service backup postgres                # pg_dumpall | gzip -> backups/ (last 14 kept; backup.restic ships them offsite)
aw service restore postgres <file.sql.gz>
aw service upgrade postgres 17            # snapshot + dump + pin the new major, then prints the pg_upgrade sequence
aw service psql postgres -c 'select 1'
```

`aw disable services.postgres` removes the unit and container and keeps
the data, snapshots and dumps; `AW_PURGE=1` removes them too.

## Reaching it from an application on Cloudflare (Hyperdrive)

1. The node is approved into a group with **public exposure**; the control
   plane adds `<node>-postgres.<base>` to its tunnel and DNS automatically once
   the node reports the service.
2. In Zero Trust, add a **service-token policy** to the wildcard node
   application (the same `*.<base>` app that gates node UIs) and create a
   service token for the app.
3. Create the Hyperdrive config against the private origin:

   ```bash
   npx wrangler hyperdrive create shop-db \
     --host kitchen-postgres.alwayswork.space --port 5432 --database shop --user shop_app --password '<PG_ROLE_SHOP_APP_PASSWORD>' \
     --access-client-id '<service token id>' --access-client-secret '<service token secret>'
   ```

4. Bind it in the app's `wrangler.jsonc` and connect with
   `env.HYPERDRIVE.connectionString` (pg, postgres.js, Drizzle, Prisma).

Hyperdrive pools connections and caches queries at the edge; the tunnel is
the only path in; Access is the only thing that opens it. A developer's
laptop reaches the same hostname with
`cloudflared access tcp --hostname kitchen-postgres.alwayswork.space --url localhost:5432`.

## Reliability, honestly

A Postgres on one node is durable (subvolume, snapshots, dumps, offsite
backups) and supervised (healthcheck, heartbeat, alerts), but not highly
available. The first scaling step is a read replica on a second node driven
by the agent (designed); until then, treat it like a managed single-node
database with very good backups.

## The agent as DBA

The harness's `alwayswork` plugin exposes `aw service …` as tools, and a
runbook skill per service explains the sequences (install, major upgrade,
restore drill, tuning for the node's RAM). "Upgrade the database to 17 and
confirm the app still works" is then an objective the agent executes with
snapshots to fall back on.

## Adding another service

Copy `capabilities/services.postgres`: a manifest (`requires: [core,
runtime.podman]`), `<id>.sh` with `<id>_workload_vars` filling the `WL_*`
variables and the `<id>_status|logs|backup|…` operations, hooks that call
`wl_apply_unit` / `wl_report_service` / `wl_remove_unit`. Redis, MinIO,
PostgREST and n8n fit the same shape.

## PostgreSQL as an app package

Target package: PostgreSQL component, persistent data volume, private PostgreSQL
interface, optional HTTP admin component, exporter metadata, backup/diagnostic
operations and recovery runbooks. A Connection grants a consumer (for example a
Cloudflare Worker through Hyperdrive) scoped database access. The node's collector
reads declared exporter/log sources and forwards telemetry outward; the control AI
uses scoped queries and deterministic operations. This adapter contract is planned.
A database needs no embedded AI or MCP server to participate.
