# AlwaysWork

**Install a secured foundation on any Arch- or Debian-family Linux mini PC, then grow it one capability at a time.**

AlwaysWork turns a mini PC into a self-hosted AlwaysWork node. The installer
lays down a *complete, locked-down foundation* — firewall, snapshots, encrypted
secrets, safe updates, and a status/audit CLI. Everything beyond that (container
runtime, tunnel, agents, automations, backups) is an opt-in **capability** you
enable when you need it, and cleanly disable when you do not.

```
  foundation   ->   enable <capability>   ->   enable <capability>   ->   ...
  (secured)         (runtime.docker)          (access.tunnel)
```

## Install

```bash
# On a fresh CachyOS install:
curl -fsSL https://raw.githubusercontent.com/softstone1/alwayswork-agent/main/install.sh | sudo bash

# or from a checkout:
git clone https://github.com/softstone1/alwayswork-agent && cd alwayswork-agent
sudo ./install.sh --dry-run     # print every action first
sudo ./install.sh
```

Then lay the foundation and pick a starting point:

```bash
sudo aw init --profile foundation   # writes /etc/alwayswork/worker.yaml
sudo aw bootstrap                   # secure the box + install the foundation
sudo aw doctor                      # scored security + health audit
```

Grow it whenever you want:

```bash
sudo aw list --available
sudo aw enable runtime.docker
sudo aw enable access.tunnel --domain worker.example.com
sudo aw enable agents.core backup.restic obs.uptime
sudo aw disable agents.core            # clean, tracked teardown
```

## Foundation vs. capabilities

The **foundation** is what `bootstrap` always installs — it is what makes a
machine a safe worker node:

- default-deny firewall, **no inbound ports**
- SSH disabled, or bound to Tailscale only
- container socket never exposed to workloads
- encrypted secret store (sops + age)
- btrfs/snapper snapshots + one-command update with rollback
- `doctor` security audit, `status`, structured logging

Everything else is a **capability** — a self-describing module with a manifest, an
install script and an uninstall script. Adding tooling is configuration, not a fork.

| Capability | What it adds |
|------------|--------------|
| `runtime.docker` / `runtime.podman` | Container runtime with hardened defaults |
| `services.postgres` | PostgreSQL as a workload container: data subvolume, healthcheck, snapshots, dumps, `aw service …`; reached by apps through Hyperdrive — see `docs/SERVICES.md` |
| `agents.dsh` | The node's agent harness (DeepSeek Harness web UI) as a standard workload container: `userns=auto`, read-only rootfs, cgroup budget, loopback only — see `docs/WORKLOADS.md` |
| `access.tunnel` | Cloudflare Tunnel, outbound-only public access |
| `access.tailscale` | Private admin plane |
| `agents.core` | Agent dispatcher + hardened worker pool |
| `assistant.n8n` | Automation hub (email/calendar/webhooks) |
| `backup.restic` | Encrypted offsite backups |
| `obs.uptime` | Uptime monitoring + alerts |
| `dev.toolchain` | Runtimes for building/testing on-box |

## Apps and cleanup

The bootstrap stays minimal. Tools are installed on demand from a curated
catalog of 74 common apps, and anything no longer used can be removed:

```bash
aw app list containers          # browse by category
aw app search backup
sudo aw app install ripgrep lazygit btop
sudo aw app remove lazygit
sudo aw clean                   # orphans, caches, journal, stale images
```

Add your own entries without forking by copying `catalog/apps.yaml` to
`/etc/alwayswork/apps.yaml`. See `docs/APPS.md`.

## Onboarding a new worker

A fresh box has no inbound access and no agent, so enrollment is always
**initiated by the worker** and **authorized from the console**. Pick a mode:

| Mode | How it starts | Best for |
|------|---------------|----------|
| Join token | install, then `sudo aw enroll --control <url> --token <t>` | one box, first install |
| Claim & approve | first-boot service announces itself | headless boxes, small fleets |
| Fleet image | golden image with a fleet identity | many identical boxes |

The worker generates a keypair, announces itself, waits as **pending**, and on
approval receives a device credential plus its desired configuration. It then
self-configures with the same `init` / `bootstrap` / `apply` path and joins an
outbound-only channel. No inbound port is ever opened.

Full protocol, API sketch and security model: `docs/ENROLLMENT.md`.

## Zero-touch install (plug-and-play)

A fresh machine becomes a working node with exactly two human actions:

```bash
# 1. Run the single install entry point (as root, with internet):
curl -fsSL https://alwayswork.space/install.sh | sudo bash
# 2. Approve the pending node once in the web console.
```

That is the whole list. The bootstrapper installs the agent non-interactively
and enrolls the box — it registers a **pending claim** and waits. After the
console approval, the agent does everything else by itself:

```
install -> pending -> (console approval) -> active -> lockdown
```

The same entry point has four carriers, all generated by the console's
**Add node** flow so nothing is assembled by hand (control repo,
`docs/SYSTEM_SPEC.md` §4). Every carrier ends up running the agent's own
installer with `--yes --control <url> [--token <t>] [--hostname <h>]
[--profile <p>]`, so there is exactly one enrol sequence:

| Carrier | For | How |
|---|---|---|
| One-liner with a token | any box you can type on | `curl -fsSL https://alwayswork.space/install.sh \| sudo bash -s -- --token <t>` — with a token the node skips the claim and can auto-approve into its group |
| cloud-init | a VPS | paste the generated user-data into the provider; it runs the same line on first boot (log: `/var/log/alwayswork-bootstrap.log`) |
| Ubuntu autoinstall | a **bare mini PC** | write the stock Ubuntu Server ISO to one stick and the generated `user-data` (+ empty `meta-data`) to a FAT stick labelled `CIDATA`; boot with both, the installer runs unattended and first boot runs the same line |
| USB `provision.toml` | a mini PC that already has the agent (golden image, re-join after decommission) | `alwayswork/provision.toml` on a FAT stick; `aw provision` finds it at boot **and** when the stick is plugged in (udev rule), and enrolls |

With a token for a group that does **not** auto-approve, the install waits a
bounded time (`AW_ENROLL_WAIT`, 90 s in zero-touch mode), then leaves the
node **pending** on disk and returns: cloud-init, autoinstall and the USB
provision service never hang. The provision timer completes enrolment on its
own after the console click (`aw enroll --status` shows the state; `aw
enroll` resumes it by hand).

**Automatic tunnel from desired-state.** The control plane provisions the
Cloudflare Tunnel (tunnel + DNS) and delivers the token inside the *signed*
desired-state document as a top-level `tunnel` object:

```json
{ "tunnel": { "token": "<cloudflared tunnel token>",
              "hostname": "<node-hostname>.<baseDomain>" } }
```

On receipt the agent stores the token in its encrypted secret store (0600,
never on a command line or in a log) and reconciles `cloudflared`: started on
first receipt, restarted when the token rotates. A delivery with no `tunnel`
section — or an explicit `"tunnel": null` — leaves any existing tunnel state
alone; a null/absent field never tears cloudflared down. The token is consumed **only**
from this verified channel — if signature verification fails, nothing is
applied.

One-time control-plane setup, on the operator's own machine:
`npx wrangler secret put CLOUDFLARE_API_TOKEN`. Its plaintext lives in authd
as a use-only credential — no agent can retrieve or set it, and the deploy
pipeline does not set it. Everything after that step, per node, is just the
two human actions above.

**Deferred lockdown.** The installer never hardens SSH: cutting it at install
time would strand the box before the tunnel is verified. The lockdown (public
SSH off, firewall default-deny, per the `hardening.ssh` policy) happens later,
automatically, once signed desired-state marks the node active *and* the tunnel
is up — the tunnel is the only way back in after sshd goes down, so the agent
defers the lockdown (and retries) until `cloudflared` is running. The node
reaches "active and reachable" with no SSH session and no human in the loop.

**Manual override.** `sudo aw secrets set CLOUDFLARE_TUNNEL_TOKEN <token>` (or
`... --stdin` to keep the value off the command line) still works as an
explicit local fallback for nodes with no delivery yet. Conflict rule: a
verified delivered token **always replaces** the stored one — the control plane
must be able to rotate tokens centrally, and a sticky local value would
silently break rotation.

### Plug-and-play acceptance bar

Fresh Ubuntu 24.04 or Arch/CachyOS, root + internet. The only human actions
are (1) running the install entry point above and (2) approving the pending
node in the console. Everything else — dependencies, install,
enrollment/claim, tunnel + DNS provisioning, signed desired-state application,
final lockdown — must happen with no SSH session and no further commands.

## Staying connected

The node must come back on its own from a reboot, a power cut, a network
change or a control-plane redeploy. The agent unit starts after the network
and time sync are up and backs off exponentially on failures; `cloudflared`
restarts on its own unit; tunnel tokens are rotated through signed desired
state. Two guards keep a recovering box honest: the agent **refuses to sign
anything until its clock is trusted** (a mini PC without a battery clock
boots in 1970 and would otherwise fail every request), and every heartbeat
carries a typed **health** report (load, memory, disk, temperature, tunnel
and UI reachability, `doctor` score) so the console can tell online from
stale from unhealthy without guessing.

## Leaving the fleet

Two ways out, both from the console or the box:

| Command | What it does |
|---|---|
| **Revoke** | Immediate, non-destructive. The identity is tombstoned and the agent stops. Nothing on the box is touched — use it when you want a forensic state. |
| **Decommission** | Permanent. Drain capabilities, tombstone the identity, wipe keys and secrets, then **restore the machine**: SSH and firewall back to their prior state, packages AlwaysWork installed removed, units and files deleted, cloudflared, node, the agent engine and finally `aw` itself gone. The box is the PC it was before. |

Restore works from a **ledger** the installer and every capability append to
before changing anything (`/var/lib/alwayswork/ledger.jsonl`), replayed in
reverse. `aw decommission --keep-foundation` keeps the hardening;
`--keep-agent` keeps AlwaysWork installed but unenrolled, ready to re-join.
Details: `docs/DECOMMISSION.md`.

## Reaching a node

Everything enters through the tunnel and Cloudflare Access; nothing listens
on the LAN. The options, from the everyday to the break-glass:

| Option | Gives |
|---|---|
| The node's web UI at `<node>.alwayswork.space` | the agent engine; later a portal with a card per service (terminal, automations, files) |
| Objectives in desired state | a signed task the node's agent executes and reports back — the way fleets and automations talk to a node |
| SSH over the tunnel (`hardening.ssh: tunnel`) | real SSH at `<node>-ssh.alwayswork.space` with Access short-lived certificates: sshd bound to loopback, no keys on the box, every session logged |
| Tailscale (`hardening.ssh: tailscale`) | a separate private plane, optional |

`hardening.ssh: lan` exists for operator-managed boxes and is never used on a
managed node.

## Design principles

| Principle | Meaning |
|-----------|---------|
| **Declarative** | `/etc/alwayswork/worker.yaml` is desired state; `apply` reconciles to it. |
| **Foundation first** | Always boot a secure, working node before adding surface area. |
| **Opt-in surface** | Nothing opens a port or installs a service until you enable it. |
| **Flexible runtime** | Docker, Podman, or none. Limits are tunable defaults, not walls. |
| **Reversible** | Snapshots before updates; every capability can be cleanly removed. |
| **Portable** | Bash + a handful of packages. x86_64 or aarch64, Arch- or Debian-family systems. |

See `docs/DESIGN.md`, `docs/CAPABILITIES.md`, `docs/WORKLOADS.md`, `docs/SERVICES.md`, `docs/UPDATES.md`, `docs/SECURITY.md`,
`docs/ROLLOUT.md`, `docs/ENROLLMENT.md`, `docs/DECOMMISSION.md` and
`docs/AGENT_BOOTSTRAP.md`. The system-wide design — node, control plane,
edge, console — is the control repo's `docs/SYSTEM_SPEC.md`.

## Commands

```
aw init [--profile P]                 Write worker config
aw bootstrap                          Secure the box + install foundation
aw apply                              Reconcile installed capabilities to config
aw enable <cap>...                    Install + persist capability (with deps)
aw disable <cap>...                   Cleanly remove capability
aw list [--available]                 Show capabilities
aw status                             Node, engine and capability status
aw doctor                             Security + health audit (scored)
aw update [--rollout ID]              Snapshot, upgrade, health gate, boot probation (docs/UPDATES.md)
aw snapshot <list|create|rollback>
aw secrets <init|set|get|list|env>
aw capability add <path>              Register an out-of-tree capability
aw app list | search | install | remove
aw clean                              Remove orphans, caches and junk
aw enroll --control URL [--token T]   Announce this worker to a control plane
aw agent [interval]                   Report + reconcile with the control plane
aw provision                          First-boot: USB file, pending claim, or resume
aw decommission [--keep-foundation|--keep-agent] [--local]
                                      Leave the fleet and restore the machine
aw reset [--purge]                    Forget the control identity, keep everything else
aw help
```

Every mutating command supports `--dry-run` and `--yes`.

## License

MIT
