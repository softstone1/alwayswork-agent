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

A service bound anywhere but loopback or the `alwayswork` network shows up in
`health.listeners` and fails `aw doctor` ([SECURITY.md](SECURITY.md#listener-audit)).

Config keys beyond the basics: `roles`, `tls`, `hostnames`, `admin`,
`admin_port`, `memory_mb`, `backup` and the `backup_*` keys (see the header
of `capabilities/services.postgres/postgres.sh` and [Backups](#backups-pgbackrest-to-r2)).

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
backups report them), `updated_at`, then `last_backup_kind`,
`last_backup_error`, `last_restore_drill_error` (columns are only ever
appended). With `backup=pgbackrest`, `archive_lag_seconds` is the WAL lag
(`pg_stat_archiver`). Every declared role gets `USAGE` on
schema `aw` and `SELECT` on `aw.status` (not on `aw.facts`).

### Heartbeat

The `postgres` entry of `expose.services` carries an extra object:

```json
"postgres": {
  "database": "shop",
  "tls": { "caPem": "-----BEGIN CERTIFICATE-----…", "caSha256": "<sha256 of the CA cert DER, 64 hex>" },
  "roles": [ { "name": "shop_app", "secretSha256": "<first 16 hex of sha256(password)>" } ],
  "backup": { "mode": "pgbackrest", "lastBackupAt": "2026-10-17T03:04:11Z", "lastBackupOk": true,
              "lastDrillAt": "2026-10-15T04:07:52Z", "lastDrillOk": true },
  "metrics": { "at": "2026-10-17T09:30:00Z", "up": true, "serverVersion": "17.6", "uptimeSec": 86400,
               "connections": 7, "maxConnections": 100, "activeQueries": 2,
               "dbSizeBytes": 123456789, "diskFreeBytes": 52613349376, "diskTotalBytes": 107374182400,
               "cacheHitRatio": 0.9934, "xactCommit": 5000, "xactRollback": 12, "deadlocks": 0,
               "longestQuerySec": 3.2, "longestTxSec": 41.0,
               "walArchivedCount": 812, "walFailedCount": 0, "lastArchivedAt": "2026-10-17T09:29:41Z", "archiveLagSec": 19.0,
               "replicationSlots": 0 }
}
```

`tls` is omitted while `tls=off`. `roles` lists only declared roles whose
last reconcile succeeded with the password fingerprinted, so the control
plane can tell a rotation landed. Nothing secret is in it: the CA
certificate is public and a password appears only as that fingerprint.
`backup.mode` is `off` or `pgbackrest`; the times and results are null until
a run reports them (no repository location, no key).

`metrics` feeds the control plane's Databases view and travels with every
heartbeat. It is one `psql` over the container socket as `postgres` (peer,
statement logging off, bounded to 5 s) returning one `json_build_object` row
for `db`, plus `diskFreeBytes`/`diskTotalBytes` from `df` of the data
directory on the host. `at` is when it was sampled (UTC): the sample is cached
in `/var/lib/alwayswork/postgres-metrics.json` and reused for 60 s, so a fast
heartbeat never hammers the database. `connections` and `activeQueries` count
client backends (`activeQueries` and the `longest*` ages leave out the sample
itself); `cacheHitRatio` is `blks_hit / (blks_hit + blks_read)` for `db`
(null before any block is read); `longestQuerySec` / `longestTxSec` are the
oldest active statement and open transaction (null when none). `xactCommit`,
`xactRollback`, `deadlocks`, `walArchivedCount` and `walFailedCount` are
cumulative since the last statistics reset — the control plane takes deltas.
The `wal*`, `lastArchivedAt` and `archiveLagSec` fields are null while
archiving is off (`backup=off`). When the server is down or `psql` fails or
times out, `metrics` is only `{"at": …, "up": false}`. No secret, role
password or query text is ever in it.

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
aw service backup postgres                # backup=off: pg_dumpall | gzip -> backups/ (last 14 kept; backup.restic ships them offsite)
                                          # backup=pgbackrest: a differential now (--full, --incr, --monthly)
aw service restore postgres <file.sql.gz>
aw service restore postgres --to '2026-10-17 09:30:00+00' --yes   # PITR (backup=pgbackrest), see the runbook below
aw service drill postgres                 # restore drill now (backup=pgbackrest)
aw service upgrade postgres 17            # snapshot + dump + pin the new major, then prints the pg_upgrade sequence
aw service psql postgres -c 'select 1'
```

`aw disable services.postgres` removes the unit and container (and the
backup schedules and pgBackRest config) and keeps the data, snapshots and
dumps; `AW_PURGE=1` removes them too. The R2 repository is never touched by
the node outside pgBackRest's own retention.

### Backups (pgBackRest to R2)

`backup=pgbackrest` turns a dump-only database into one with continuous WAL
archiving and point-in-time recovery, to an S3 repository on Cloudflare R2,
encrypted on the node before it leaves (`aes-256-cbc`, pgBackRest's
repository cipher).

```bash
sudo aw enable services.postgres --backup pgbackrest \
  --backup_endpoint https://<account-id>.r2.cloudflarestorage.com --backup_bucket alwayswork-pg
```

| Key | Default | |
|---|---|---|
| `backup` | `off` | `off` (dumps only) or `pgbackrest` |
| `backup_endpoint` | — | `https://<account-id>.r2.cloudflarestorage.com` (required) |
| `backup_bucket` | — | the R2 bucket (required) |
| `backup_path` | `/<node>/<db>` | repository path; monthly fulls go to `<backup_path>-monthly`. Set it explicitly if the node may be renamed |
| `backup_region` | `auto` | R2 takes `auto` |
| `backup_retention_full_weeks` | `2` | PITR window in weeks (2 → 14 days) |
| `backup_monthly_keep` | `12` | monthly fulls kept; `0` = no monthly repository |

What runs:

| | |
|---|---|
| WAL | `archive_mode=on`, `archive_command='pgbackrest --stanza=<db> archive-push %p'`, `archive_timeout=60`, `wal_level=replica` — only while `backup=pgbackrest` |
| Weekly full | Sunday 03:00 node-local → repo1 |
| Daily differential | Monday–Saturday 03:00 → repo1 |
| Monthly full | 1st of the month 05:00 → repo2 |
| Restore drill | Wednesday 04:00 |

All are systemd timers (`alwayswork-postgres-backup-{full,diff,monthly}.timer`,
`alwayswork-postgres-restore-drill.timer`; `RandomizedDelaySec=10m`,
`Persistent=true`) running `aw service backup postgres --full|--diff|--monthly`
and `aw service drill postgres`. On first success of `stanza-create` +
`check` (on apply) the first full backup starts right away.

Retention. pgBackRest keeps retention per repository, so "14 days of PITR"
and "a monthly full for a year" are two repositories in the same bucket:

| | Path | Retention |
|---|---|---|
| repo1 | `<backup_path>` | `retention-full-type=time`, `retention-full=14`: every full needed to reach 14 days back is kept, with its differentials and all WAL in between — PITR anywhere in the window |
| repo2 | `<backup_path>-monthly` | `retention-full-type=count`, `retention-full=12`; WAL (`retention-archive-type=full`, `1`) only for the newest monthly plus what each older one needs to be consistent — each monthly restores to its own end point |

`archive-push` sends WAL to both repositories (pgBackRest pushes to every
configured repo); repo2 expires it at the next monthly. Differentials expire
with their full.

**Image.** pgBackRest has to run inside the PostgreSQL container:
`archive_command` runs there and a backup reads `PGDATA`. There is no
maintained image with the official PostgreSQL build and pgBackRest
(pgBackRest's own project publishes none; vendor images bundle their own
PostgreSQL builds, licences or operators), so the node builds one with
`podman build` from `capabilities/services.postgres/Containerfile`:
`FROM` exactly the image it would otherwise run (pinned major, channel
version, or `image` override — digest form welcome) plus pgBackRest
**2.59.3** from the PGDG apt repository the official image already trusts
(same signing key), resolved through `apt-archive.postgresql.org` so the
pin still installs after PGDG moves on, and checked with `pgbackrest
version`. The result is `localhost/alwayswork-postgres:<tag>-pgbackrest2.59.3-<hash>`
(hash over the base ref, the pin and the Containerfile). The container
carries `dev.alwayswork.base_image=<base>`, which is what image-update
tracking compares with the wanted image, so `aw update` and channels work as
before: a new base is a new tag and a rebuild. `pull=always` rebuilds
against a newer base on every apply.

**Secrets.** Three group secrets — delivered sealed, never generated and
never node-owned:

| Key | |
|---|---|
| `PGBACKREST_R2_ACCESS_KEY_ID` | R2 API token access key id |
| `PGBACKREST_R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `PGBACKREST_CIPHER_PASS` | repository passphrase — **keep a copy outside the fleet**: without it the backups cannot be read |

Without all three, preflight and apply refuse with the missing names and
archiving is never turned on. They reach pgBackRest only through
`/var/lib/alwayswork/services/postgres/pgbackrest/pgbackrest.conf` (0600, in
a 0700 directory, mounted read-only into the container at
`/etc/pgbackrest`), never through argv, a unit file, a log line or the
heartbeat; errors recorded in `aw.facts` are redacted. Rotating the R2 key is
a new group secret and an apply (the changed config restarts the container).
The cipher passphrase cannot be rotated in place for an existing repository:
use a new `backup_path`.

Set up R2 once per fleet:

1. Cloudflare dashboard → R2 → **Create bucket** (e.g. `alwayswork-pg`;
   location automatic). No public access.
2. R2 → **Manage API tokens** → **Create API token**: permission **Object Read
   & Write**, **Apply to specific buckets only** → that bucket. Copy the
   access key id and secret (shown once). The endpoint is
   `https://<account-id>.r2.cloudflarestorage.com`.
3. Put the three secrets on the node's group with the control plane's
   secrets API (operator auth — Access service token shown; values from a
   file, not the command line):

   ```bash
   umask 077; cat > /tmp/pg-backup-secrets.json <<'JSON'
   { "PGBACKREST_R2_ACCESS_KEY_ID": "<access key id>",
     "PGBACKREST_R2_SECRET_ACCESS_KEY": "<secret access key>",
     "PGBACKREST_CIPHER_PASS": "<openssl rand -base64 48>" }
   JSON
   curl -fsS -X PUT "https://<control>/v1/admin/groups/<group-id>/secrets" \
     -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
     -H 'content-type: application/json' --data @/tmp/pg-backup-secrets.json
   shred -u /tmp/pg-backup-secrets.json
   ```

4. Set `backup: pgbackrest` and the `backup_*` keys in the group's
   `services.postgres` config (or `aw enable … --backup pgbackrest …` on the
   node). The next delivery carries the sealed secrets and the apply turns on
   archiving, creates the stanza, checks it and starts the first full.

**Restore drill.** Weekly, `aw service drill postgres` restores the latest
backup plus all archived WAL from repo1 into
`/var/lib/alwayswork/services/postgres/drill/` inside a throwaway container
of the same image (`alwayswork-postgres-drill`: `userns=auto`, uid 999, no
capabilities, no published port, the workload network only to reach R2, its
own copy of the config), starts PostgreSQL socket-only with
`archive_mode=off` (a drill never writes to the repository), waits for
recovery to finish, runs `SELECT count(*) FROM pg_database` and checks the
configured database is there, stops, and deletes the scratch copy whatever
happened. It refuses to start with less than 1.2× the data directory free
and is cut off after 30 minutes. It never touches the live data directory.
The result is `last_restore_drill_at/ok/error` in `aw.facts` and
`lastDrillAt/Ok` on the heartbeat.

**Recovery runbook** (point-in-time):

1. Pick the target: `aw service status postgres` (last backup), or the
   moment just before the incident, in UTC, e.g. `2026-10-17 09:30:00+00`.
   Must be inside the PITR window.
2. `sudo aw service restore postgres --to '2026-10-17 09:30:00+00' --yes`
   (`--latest` replays to the end of the archive instead). Without `--yes` it
   refuses. It stops `alwayswork-postgres`, **moves** the data directory to
   `data.before-restore-<stamp>` (never deletes it), holds a lock so no apply
   restarts the service meanwhile, restores into a fresh directory with
   `pgbackrest restore --type=time --target=… --target-action=promote` in a
   throwaway container, starts the service (PostgreSQL replays WAL from R2
   to the target and promotes), waits until it is out of recovery and checks
   the database exists. A failed restore puts the previous directory back and
   starts it (the attempt is kept as `data.failed-restore-<stamp>`). If the
   node dies mid-restore, apply keeps refusing while
   `/var/lib/alwayswork/services/postgres/restore.lock` exists: re-run the
   restore, or move `data.before-restore-<stamp>` back to `data`, then delete
   the lock.
3. Verify the application, then remove `data.before-restore-<stamp>`
   yourself. A full backup of the new timeline starts automatically.
   Every promotion (a restore, or `standby=off` on a seeded node) and every
   backup runs an immediate `CHECKPOINT` first: until one completes,
   `pg_control` still names the old timeline and pgBackRest refuses the backup
   with `[058]: WAL timeline 2 does not match pg_control timeline 1`.
4. From a lost node: enable `services.postgres` on a new node with the same
   `db`, `backup_*` keys (`backup_path` set to the old node's) and group
   secrets, then run step 2 there before the application writes to it. Until
   then its apply warns that `stanza-create` does not match the repository —
   expected: pgBackRest refuses to archive a different cluster into it.

Backups on record: `sudo podman exec alwayswork-postgres pgbackrest
--stanza=<db> info`. A monthly full (repo2) is restored by hand along the
same steps, with pgBackRest's `--repo=2 --set=<backup label>` in place of
`--type=time`; the agent's runbook covers it.

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
