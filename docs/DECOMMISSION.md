# Decommission and restore

**Goal:** leaving the fleet returns the machine to what it was before
AlwaysWork touched it. Not "unenrolled", not "hardened but idle" — the
same PC, with the same SSH state, the same firewall state, and none of the
packages, units, files or binaries AlwaysWork added.

This is the node side of `docs/SYSTEM_SPEC.md` §3.5 and §8 in the control
repo.

## Phases

`aw decommission` (and the signed drain order the control agent acts on)
runs these phases in order. Each is idempotent and recorded in the marker
file, so an interrupted run resumes at the next boot or tick.

| Phase | What it does |
|---|---|
| **drain** | Uninstall every enabled capability except `core`, `control.join`, `access.tunnel`, `access.tailscale`, in reverse dependency order. |
| **revoke** | Ask the control plane to tombstone the device id (skipped with `--local`, queued if unreachable). |
| **wipe** | Shred the device key and age key; delete the secret store, tunnel token, control config, claim, UI state. |
| **restore** | Replay the ledger in reverse (below). Then remove the remaining capabilities, cloudflared, node.js, the agent engine, and finally `aw` itself and the ledger. |
| **report** | Print what happened and where the control plane stands. |

Flags:

| Flag | Effect |
|---|---|
| *(default)* | All phases. The box is a normal PC afterwards. |
| `--keep-foundation` | Skip the firewall and SSH restore; keep the hardened base and `aw`, unenrolled. |
| `--keep-agent` | Skip restore entirely (the pre-ledger behaviour): AlwaysWork stays installed, ready to re-join. |
| `--local` | Do not contact the control plane; the operator removes the node in the console. |

A drain order delivered by the control plane may carry
`"restore": false`; the agent then behaves as `--keep-agent`. Absent, the
default (full restore) applies.

## The ledger

`/var/lib/alwayswork/ledger.jsonl` — one JSON object per line, appended
**before** the change is made, by the installer, `aw bootstrap`,
`aw enable`, and every capability hook that goes through the shared
helpers. Prior file contents are kept under
`/var/lib/alwayswork/ledger.d/<sha256>`.

```jsonc
{ "t": 1758…, "by": "install",           "kind": "pkg",      "name": "ufw",  "priorInstalled": false }
{ "t": 1758…, "by": "bootstrap",         "kind": "firewall", "backend": "ufw", "priorActive": false, "priorRules": "sha256…" }
{ "t": 1758…, "by": "bootstrap",         "kind": "ssh",      "priorEnabled": true, "priorActive": true }
{ "t": 1758…, "by": "agents.dsh",        "kind": "file",     "path": "/etc/systemd/system/alwayswork-webui.service", "existed": false }
{ "t": 1758…, "by": "agents.dsh",        "kind": "unit",     "name": "alwayswork-webui.service" }
{ "t": 1758…, "by": "control.join",      "kind": "service",  "name": "sshd", "priorEnabled": true, "priorActive": true }
{ "t": 1758…, "by": "provision",         "kind": "hostname", "prior": "ubuntu" }
```

Kinds and how restore undoes them:

| Kind | Recorded | Restore |
|---|---|---|
| `file` | `path`, `existed`, `sha` of prior content (copy kept) | Prior content written back, or the file deleted. |
| `unit` | `name` | `systemctl disable --now`, unit file deleted, daemon reloaded. |
| `pkg` | `name`, `priorInstalled` | Removed only when `priorInstalled` is false. |
| `service` | `name`, `priorEnabled`, `priorActive` | Both states restored. |
| `firewall` | `backend`, `priorActive`, `priorRules` (export kept) | Rules restored; backend disabled if it was inactive. |
| `ssh` | `priorEnabled`, `priorActive`, drop-ins we wrote | Drop-ins removed; state restored. |
| `hostname` | `prior` | `hostnamectl set-hostname` back. |
| `dir` | `path`, `existed` | Removed when we created it and it is now empty. |

Rules:

- **Reverse order.** The last change is undone first, so a unit is stopped
  before its file is removed and a capability's files go before the
  runtime it depended on.
- **Only ours.** A package that was already installed is never removed. A
  file that existed is restored, never deleted.
- **Idempotent.** Every entry is marked `restored` in the marker file as it
  is undone; a re-run skips done entries.
- **Loud, not fatal.** A single failed entry is logged and skipped; the
  rest of the restore continues and the failure appears in the report.
- **Self last.** `aw` removes `/opt/alwayswork`, `/usr/local/bin/aw`, the
  `alwayswork` link and the ledger as the final step, from a copy of itself
  already loaded in memory.

## What the installer records

`install.sh` runs before `aw` exists, so it appends its own entries with
the same format: the distro packages it installs (with `priorInstalled`
checked first), the bundled `yq`, `/opt/alwayswork`, the two links in
`/usr/local/bin`, and the provision timer and units.

## Verifying it

`tests/run.sh` covers the ledger helpers and a dry-run restore against a
synthetic ledger. The end-to-end proof is an image test (designed, control
`docs/SYSTEM_SPEC.md` §4.4): install on a pristine image, decommission,
then diff the filesystem, package list and unit list against the image.
