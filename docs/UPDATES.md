# Safe unattended updates

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


The node side of `docs/SYSTEM_SPEC.md` §13.1 (control repo). A rolling
release on a box nobody watches is only safe if an update that goes wrong
undoes itself. `lib/updates.sh` gives `aw update` four layers:

| Layer | Mechanism |
|---|---|
| **Only `aw update` upgrades — unattended** | a pacman hook (`/etc/pacman.d/hooks/00-alwayswork-guard.hook`) / apt hook (`/etc/apt/apt.conf.d/99alwayswork-guard`) runs `aw update --guard` before every transaction and aborts unless the update lock is held. The agent's own capability installs pass (they set `AW_PKG_GUARD_OK`), and so does an operator running pacman/apt from a terminal (the guard is against timers, cron and scripts, not people; `.updates.guard: strict` refuses everyone). `aw config set .updates.guard false` turns it off. |
| **Health gate** | after `pkg_upgrade`: `aw doctor` ≥ `updates.min_doctor_score` (70), `cloudflared` active on tunnel-managed nodes, one heartbeat accepted — retried for `updates.gate_seconds` (180). On failure the file-level changes since the pre-update snapshot are undone (`snapper undochange <pre>..0`, no reboot) and the gate runs again. |
| **Boot probation** | after a successful update the node is *on probation*: `alwayswork-boot-check.service` re-runs the gate on the next boots. Healthy → probation cleared. Unhealthy on **two** boots → `snapper rollback <pre-update snapshot>` and one reboot. |
| **Waves** | the control plane delivers `update: { rolloutId }` to the nodes of the current wave; the node runs `aw update --rollout <id>` detached (`systemd-run`) and reports `health.update = { rolloutId, state, summary, at }` on heartbeat. The next wave waits for this one to be healthy. |

| **The agent itself** | before packages, `aw update` compares `/opt/alwayswork/COMMIT` with the commit the control plane ships (every heartbeat answer carries `agent.commit`, kept in `$AW_STATE/agent-target`). When behind it downloads `<control>/agent.tar.gz` — the same tarball the one-liner installs — and re-runs that tarball's `install.sh --yes --skip-deps --from …` over `/opt/alwayswork`: the installer recognises an enrolled node and upgrades in place (files, `aw apply`, agent restart; identity kept). `aw update --agent` forces it; `--no-agent` or `updates.agent: false` skips it. The heartbeat reports `agentCommit` and `agentOutdated`. |

States in `health.update.state`: `running`, `ok`, `failed`, `rolled_back`.

An agent too old to have `aw update` at all is upgraded the same way by
hand: run the install one-liner on the box again (`curl -fsSL
<control>/install.sh | sudo bash`) — no token, identity kept.

## What it cannot do

A kernel that does not boot at all never reaches the boot check. That
last inch is the bootloader's:

- **systemd-boot**: enable boot counting (`boot-complete.target`) so a
  failed boot falls back to the previous entry; the boot check then runs
  on the fallback kernel.
- **GRUB + btrfs**: install `grub-btrfs` so every snapper snapshot is a
  boot entry; a stranded box is a `Snapshots` menu pick away from the
  pre-update state.

Both are a one-time choice per mini PC and are part of the unattended
image (spec §4.4).

## Using it

```bash
sudo aw update                  # snapshot -> agent (if behind) -> upgrade -> gate -> probation
sudo aw update --agent          # only the agent, now, even if it looks current
sudo aw update --no-agent       # packages only
sudo aw update --boot-check     # what the boot unit runs
sudo aw update --guard          # what the package hook runs (exit 0 = allowed)
```

Config (`/etc/alwayswork/worker.yaml`):

```yaml
updates:
  guard: true             # package-manager hook on
  min_doctor_score: 70
  gate_seconds: 180
```

Kernel choice for nodes: `linux-cachyos-lts` keeps the CachyOS patches on
an LTS base and takes most of the churn out of the rolling release.

## App releases and machine updates

Keep machine agent/host updates distinct from app release changes. App software
changes build/resolve package artifacts; resource-only changes need not rebuild an
image. Report compatibility and restart requirements. Data migration/restore is not
implied by reverting an image. Existing aw update behavior below remains the v1
contract; do not silently change the upgrade scope during the model migration.


## Scoped control-plane updates (protocol 2)

Nodes advertise `health.updateProtocol: 2`. The console offers Agent, Host packages,
and Full node maintenance. Agent updates take the update lock and verify health;
they do not run the host package-manager upgrade. The installer still re-applies
desired state, so changed service definitions can restart. Full maintenance retains
the existing agent/package/image convergence behavior. Host-package updates use
`--scope system`, skip the agent installer, and retain reconciliation/health checks.

A signed update can contain `scope` and an exact `agentCommit`. The archive is
requested by commit and its response metadata must match before installation.
Retries use a new execution ID, so an earlier attempt cannot finish the new one.
The control plane additionally verifies the reported installed commit before
advancing a scoped agent rollout. Old nodes first use the legacy full update; the
console states that broader scope. Cancellation stops future waves, not a running
package manager. Health failure remains failure unless recovery is actually proven.

The canonical app model now also defines configuration, credentials/access grants
and the Cloudflare-native control-plane service map. These target contracts do not
turn existing group-wide secret delivery into per-component isolation.
