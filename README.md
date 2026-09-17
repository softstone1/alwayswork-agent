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
section leaves any existing tunnel state alone. The token is consumed **only**
from this verified channel — if signature verification fails, nothing is
applied.

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

## Design principles

| Principle | Meaning |
|-----------|---------|
| **Declarative** | `/etc/alwayswork/worker.yaml` is desired state; `apply` reconciles to it. |
| **Foundation first** | Always boot a secure, working node before adding surface area. |
| **Opt-in surface** | Nothing opens a port or installs a service until you enable it. |
| **Flexible runtime** | Docker, Podman, or none. Limits are tunable defaults, not walls. |
| **Reversible** | Snapshots before updates; every capability can be cleanly removed. |
| **Portable** | Bash + a handful of packages. x86_64 or aarch64, Arch- or Debian-family systems. |

See `docs/DESIGN.md`, `docs/CAPABILITIES.md`, `docs/SECURITY.md`,
`docs/ROLLOUT.md`, `docs/ENROLLMENT.md` and `docs/AGENT_BOOTSTRAP.md`.

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
aw update                             Snapshot, upgrade, verify, roll back on failure
aw snapshot <list|create|rollback>
aw secrets <init|set|get|list|env>
aw capability add <path>              Register an out-of-tree capability
aw app list | search | install | remove
aw clean                              Remove orphans, caches and junk
aw enroll --control URL [--token T]   Announce this worker to a control plane
aw agent [interval]                   Report + reconcile with the control plane
aw help
```

Every mutating command supports `--dry-run` and `--yes`.

## License

MIT
