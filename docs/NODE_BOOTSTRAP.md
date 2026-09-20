# Node bootstrap — design and workflow

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Machines, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


How a bare machine becomes a managed AlwaysWork node: enrolled, converged,
reachable at its own hostname, and running an agent UI an operator can drive
from anywhere. This is the target design; §10 lists what is missing today.

## 1. What a node is

A node is a machine with:

* **an identity** — an Ed25519 keypair generated on the box (private key never
  leaves `/etc/alwayswork/identity/device.key`), plus an age key that encrypts
  the local secret store,
* **a desired state** — `/etc/alwayswork/worker.yaml`, written from the control
  plane and reconciled by `aw apply`,
* **an agent** — `alwayswork-agent.service`, which heartbeats and reconciles,
* **a role** — the group it belongs to (profile, capabilities, apps, secrets),
* **optionally a public name** — `<node>.alwayswork.space`, outbound-only through
  a Cloudflare Tunnel.

## 2. Goals

1. **One command on the box**, no console visit, for the automation path.
2. **No inbound ports.** Every connection the node makes is outbound.
3. **The control plane never needs the node's private keys.** Its secrets are
   sealed to the node's age key.
4. **Idempotent and resumable.** Re-running anything is safe; a half-finished
   bootstrap continues at the next tick.
5. **Reversible.** Revocation is immediate; updates are snapshot-gated.
6. **Every node gets its own UI** at its own hostname, gated by Zero Trust.

Non-goals: orchestrating workloads inside the node (that is the agent's job),
multi-tenant isolation, Windows/macOS nodes.

## 3. Trust model

| Secret | Lives | Purpose |
| --- | --- | --- |
| Join token | console → operator → one box | authorise exactly one enrollment |
| Device private key | node, 0600 | sign every device request |
| Age private key | node, 0600 | decrypt the secret store and sealed deliveries |
| Poll secret | node, returned once | redeem the enrollment |
| Group secrets | D1 (AES-256-GCM) → sealed per node | e.g. tunnel token |
| Tunnel token | node secret store | run cloudflared |
| Node UI token | node process memory | authenticate the node's own web UI |

* Device requests are **signed**: `METHOD\nPATH\nTIMESTAMP\nNONCE\nSHA256(body)`.
  The path is bare — a query string is transmitted but never signed.
* The Durable Object owns **nonce replay** and rate limiting.
* **Join tokens** are stored hashed, single-use, with a TTL and a group.
* Node hostnames sit behind **Cloudflare Access**; the node additionally runs its
  own DNS-rebinding fence on `/api`.

## 4. Components

```
console (alwayswork.space/console)      control plane Worker 'alwayswork'
  groups · tokens · secrets · audit       Hono + DeviceDO + D1
        |                                        ^
        | provisions                             | signed device requests
        v                                        |
node edge Worker 'alwayswork-node'          alwayswork-agent (on the node)
  custom domain per node                         | aw apply
  Workers VPC -> tunnel_id                       v
        |                                    capabilities · apps · secrets
        v
  cloudflared (node) --> http://127.0.0.1:3080 (dsh web)
```

## 5. Workflow

### Stage 0 — Prepare (console, optional)

Create a group (desired-state template) and mint a join token, or rely on
auto-approve. A group carries `profile`, `capabilities`, `apps`, `secrets`,
`limits`, `alwaysOn`, and — new — `expose`.

### Stage 1 — Install (on the box, one command)

```bash
curl -fsSL https://alwayswork.space/install.sh | sudo bash -s -- --token aj_… [--hostname kitchen]
```

The served script fetches the agent tarball from the control plane and runs
the agent's own `install.sh --yes --control <url> --token <t> [--hostname
<h>] [--profile <p>]` in zero-touch mode. That installer bundles yq, installs
the base packages, sets the hostname, generates the age key, installs
`control.join` (agent unit, provision timer, USB hotplug rule) and calls `aw
enroll --token`. It never bootstraps or hardens: the lockdown is deferred
until the tunnel is verified.

Every carrier — cloud-init on a VPS, Ubuntu autoinstall on a bare mini PC,
`alwayswork/provision.toml` on a USB stick — is that same command. With a
token for a group that needs a human approval the installer waits
`AW_ENROLL_WAIT` seconds (90) and then returns, leaving the node *pending*
on disk; `aw provision` (the timer) polls once per run and completes
enrolment after the console click.

### Stage 2 — Announce

The node generates its Ed25519 key and posts its public facts:

```
POST /v1/enroll
{ publicKey, ageRecipient, hostname, machineId, macs, serial, board,
  arch, os, agentVersion, joinToken }
-> { deviceId, pollSecret, state: "approved" | "pending" }
```

The server resolves the token to a group, records the node, and bumps its
config version. With auto-approve it is `approved` immediately; otherwise the
console shows it as `pending` for a human to assign a group.

### Stage 3 — Redeem and converge

```
GET /v1/enroll/:id      (x-poll-secret) -> { state, config, sealedSecrets }
```

1. `state != approved` or `config == null` → refuse; never apply a fallback.
2. Write profile, capabilities and apps into `worker.yaml`.
3. Unseal `sealedSecrets` with the age key, `sec_set` each one.
4. `aw apply` — firewall, power, capabilities in dependency order, apps.
5. Only then record and ack the config version.

### Stage 4 — Expose

Exposure is the **control plane's** job, not the node's. On approval, when the
group sets `expose.webUi.enabled`:

1. Pick the hostname (`<label>.alwayswork.space`, uniquified).
2. Ensure the node's tunnel exists.
3. Attach a `vpc_networks` binding plus a `custom_domain` route on the
   `alwayswork-node` Worker. **The custom domain makes Cloudflare create the DNS
   record**, so provisioning needs no DNS-scoped credential.
4. Rely on one **wildcard Access application** (`*.alwayswork.space`) for Zero
   Trust, so a new node needs no Access work at all.
5. Deliver the tunnel token inside the **signed desired-state** document as a
   top-level `tunnel` object (`{ "token": "<cloudflared token>",
   "hostname": "<label>.alwayswork.space" }`); the agent consumes it from
   *only* that verified channel — never an unsigned path. `access.tunnel` on
   the node installs the cloudflared service from it.

### Stage 5 — The node's UI

An `agents.dsh` capability installs a managed `dsh web` for the node user:

```ini
ExecStart=… dsh web --host 127.0.0.1 --port 3080 --no-open --trusted-host <node host>
Restart=always
```

The node reads the printed authenticated URL and reports it on heartbeat, so the
console can offer **Open UI** without anyone touching a terminal.

### Stage 6 — Steady state

Every ~60 s: heartbeat `{ appliedVersion, health, webUi }`; if the desired
version moved, fetch, apply, ack. Failures back off; the node tolerates the
control plane being unreachable and keeps serving.

### Stage 7 — Retire

Two exits. **Revoke** in the console → the node's next request is refused →
it stops `control.join` and touches nothing else (forensic state).
**Decommission** → the control plane tombstones the id and delivers a signed
drain order → the node drains capabilities, wipes identity and secrets, then
restores the machine from its ledger (`docs/DECOMMISSION.md`) and removes
itself. The control plane removes the tunnel and DNS records and the audit
trail records the act.

## 6. Desired state

```yaml
profile: agent
capabilities: [core, runtime.docker, access.tunnel, agents.dsh, control.join]
apps: [ripgrep, lazygit]
expose:
  webUi:
    enabled: true
    host: always2.alwayswork.space   # assigned by the control plane
    port: 3080
```

The control plane owns `expose`; the node never invents a hostname. A version
bump is the only signal the agent needs — reconcile is always full.

## 7. Why the edge is a Worker, not a bare CNAME

A bare tunnel CNAME needs a DNS-scoped credential. A Workers custom domain makes
Cloudflare create the record, and the VPC binding reaches the node's loopback
service through the tunnel the node already runs. One Worker serves every node,
dispatching on Host; at scale the binding becomes `network_id: "cf1:network"`
so a single binding covers the whole fleet.

Consequence to design around: Workers VPC routes by the **fetch URL**, so the
origin sees the loopback authority. That is why the node's request fence passes
and why the node's UI cookie is bound to `127.0.0.1:<port>`.

## 8. Lifecycle operations

| Operation | Trigger | Effect |
| --- | --- | --- |
| Approve | console | assigns group, bumps version, provisions exposure |
| Change group | console | bumps version, new capabilities/apps/secrets |
| Rotate secret | console | re-seal to every node in the group, bump |
| Update | desired state `update` | snapshot, `pacman -Syu`, healthcheck, rollback |
| Restart service | desired state | `systemctl restart` on the next tick |
| Revoke | console | node is refused; exposure removed |

## 9. Failure modes

| Failure | Behaviour |
| --- | --- |
| Control plane down | agent retries with backoff; node keeps running |
| Delivery malformed | refuse and stay unacked; never fall back to defaults |
| Secret write fails | rebuild the store from scratch; never truncate |
| cloudflared down | systemd restarts it; tunnel reconnects; node stays up |
| Apply fails mid-way | version unacked, retried next tick |
| DNS not yet live | node still serves locally; exposure retried by the control plane |
| Bad update | snapshot rollback |

## 10. Current state vs. gaps

The system-wide status table lives in the control repo,
`docs/SYSTEM_SPEC.md` §15. Node-side summary:

Working today: install, enrollment, signed requests, sealed secrets, desired
state, capability/app install, tunnel + cloudflared (provisioned by the
control plane on approval), deferred lockdown, `agents.dsh` managed web UI
with `--trusted-host`, `webUi` on heartbeat and the console's Open UI,
`install.sh` served by the control plane, `--token/--hostname/--profile/
--control` zero-touch flags with a bounded, resumable approval wait, USB
`alwayswork/provision.toml` at boot and on hotplug, drain order → tombstone → wipe, ledger and **restore** on decommission,
typed **health** heartbeat, clock guard, SSH policy `tunnel`.

Gaps, in build order:

1. **Node portal + `expose.services`** — a page per node with a card per
   loopback service (terminal, automations, files), each behind a per-path
   Access policy. Today the only exposed service is the agent engine's UI.
2. **Node-side session mint** — verify the Access JWT on the node and mint
   the engine's UI cookie locally, so the per-node proxy Worker (and its
   hand-edited `wrangler.jsonc`) can be retired. Spec §10, decision B.
3. **Objectives** — a signed task in desired state, executed by the node's
   agent, reported in heartbeat. Spec §5.5.
4. **Custom installer image** with the agent baked in. Blank mini PCs are
   covered today by the console's Ubuntu autoinstall carrier (stock Ubuntu
   Server ISO + a `CIDATA` stick); an Arch/CachyOS archiso profile is the
   remaining gap. Spec §4.4.
5. **Control key rotation** without re-enrollment (`nextKey` signed by the
   pinned key). **Reinstall matching** so a rebuilt box replaces its old
   identity instead of appearing twice.
6. **Device-scoped secrets and package pins**; **packages** as signed
   manifests with rollout waves. Spec §9.
7. **Update channel/window** in desired state.

## 11. Decisions to confirm

1. **Default bootstrap mode** — join token (automation) or claim-and-approve
   (human)? Suggested: token when a token is passed, approve otherwise.
2. **Access shape** — one wildcard app for the fleet, or per node? Suggested:
   wildcard, per-node exceptions only.
3. **May the control plane hold a node's UI token?** Suggested: yes, encrypted,
   because the control plane already delivers the node's secrets.
4. **Which user runs `dsh web`** — the installing user, or a dedicated
   `alwayswork` account? Suggested: the installing user, recorded in
   `worker.yaml` as `agent.user`.
5. **Exposure default** — does every node get a public UI, or only groups that
   ask? Suggested: only groups that ask (`expose.webUi.enabled`).

## Foundation scope

Provision the node foundation first: identity, runtime, tunnel, host policy and
reconciliation. Shared observability/security services belong here as supported
capabilities. Application packages are deployed separately after readiness; app
software dependencies do not expand the host bootstrap tool list.
