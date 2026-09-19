# Safe unattended updates

The node side of `docs/SYSTEM_SPEC.md` §13.1 (control repo). A rolling
release on a box nobody watches is only safe if an update that goes wrong
undoes itself. `lib/updates.sh` gives `aw update` four layers:

| Layer | Mechanism |
|---|---|
| **Only `aw update` upgrades** | a pacman hook (`/etc/pacman.d/hooks/00-alwayswork-guard.hook`) / apt hook (`/etc/apt/apt.conf.d/99alwayswork-guard`) runs `aw update --guard` before every transaction and aborts unless the update lock is held. The agent's own capability installs pass (they set `AW_PKG_GUARD_OK`). `aw config set .updates.guard false` turns it off. |
| **Health gate** | after `pkg_upgrade`: `aw doctor` ≥ `updates.min_doctor_score` (70), `cloudflared` active on tunnel-managed nodes, one heartbeat accepted — retried for `updates.gate_seconds` (180). On failure the file-level changes since the pre-update snapshot are undone (`snapper undochange <pre>..0`, no reboot) and the gate runs again. |
| **Boot probation** | after a successful update the node is *on probation*: `alwayswork-boot-check.service` re-runs the gate on the next boots. Healthy → probation cleared. Unhealthy on **two** boots → `snapper rollback <pre-update snapshot>` and one reboot. |
| **Waves** | the control plane delivers `update: { rolloutId }` to the nodes of the current wave; the node runs `aw update --rollout <id>` detached (`systemd-run`) and reports `health.update = { rolloutId, state, summary, at }` on heartbeat. The next wave waits for this one to be healthy. |

States in `health.update.state`: `running`, `ok`, `failed`, `rolled_back`.

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
sudo aw update                  # snapshot -> upgrade -> gate -> probation
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
