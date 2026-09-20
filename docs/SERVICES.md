# Services

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


**Web admin.** `services.postgres` runs a `pgweb` side-car by default
(`alwayswork-postgres-admin`: pinned image, read-only, loopback port 8081,
connects as the application role over the workload network). It is the
service's `http` surface, reached as `<node>-postgres-admin.<base>` behind
Access — **Open** on the postgres row in the console. `aw enable
services.postgres --admin off` removes it; `--admin_port` moves it. as workloads

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
| Health | `pg_isready` every 30 s; a failing check stops the container and systemd restarts it; reported on heartbeat |
| Reach | published to `127.0.0.1:5432` only; reported to the control plane as `expose.services`, which adds `<node>-postgres.<base>` → `tcp://127.0.0.1:5432` to the node's tunnel |

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
     --host kitchen-postgres.alwayswork.space --port 5432 --database shop --user shop --password '<POSTGRES_APP_PASSWORD>' \
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
