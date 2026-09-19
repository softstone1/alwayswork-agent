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

## Implementation notes

Where `lib/ledger.sh` had to be more specific than the contract above, and
why:

- **One entry per thing.** `aw apply` converges on every agent tick and
  re-runs every capability's install hook, so a naive append-before-change
  would grow the ledger by dozens of lines a minute. Each recorder first
  checks for an existing entry with the same kind and identity (`path`,
  `name`, or the kind alone for `firewall`, `ssh` and `hostname`) and
  records nothing when one exists. The first entry — the state before
  AlwaysWork touched the thing — is therefore what restore returns to.
- **`unit` entries also carry `existed`, `priorEnabled`, `priorActive`.**
  A unit file that already existed (say, a distro-shipped
  `cloudflared.service` we overwrote) is not deleted on restore: the `file`
  entry recorded alongside it writes the prior content back and the unit
  entry restores its enabled/active state. A unit we created is disabled,
  stopped, deleted, and systemd reloaded, as the table says.
- **Firewall restore is file-based.** The backend export (`ufw status
  verbose`, `nft list ruleset`, `firewall-cmd --list-all`) is kept under
  `ledger.d` for the operator, but ufw and firewalld are put back from the
  files they load their state from, recorded as `file` entries right after
  the `firewall` entry (`/etc/default/ufw`, `/etc/ufw/ufw.conf`,
  `/etc/ufw/user*.rules`; `/etc/firewalld/firewalld.conf`). On the reverse
  replay those files come back first, then the firewall entry reloads the
  backend (or disables it when it was inactive). nftables is restored by
  flushing and loading the kept export.
- **`--keep-foundation` keeps more than the two kinds.** Besides `firewall`
  and `ssh` it keeps `service` entries for `sshd` and every entry recorded
  `by` `install` or `core`: removing `jq`, `ufw` or `/opt/alwayswork` would
  contradict keeping `aw` and the hardened base. The capabilities drain kept
  are uninstalled except `core`.
- **`control.join` is never hook-uninstalled during restore.** Its uninstall
  hook stops `alwayswork-agent.service`, which may be the very process
  running the restore (a drain order acts inside the agent; a resumed run
  acts inside `alwayswork-provision.service`). The ledger undoes its units
  instead, and a unit that is running the restore is only *disabled*; the
  process exits on its own when the run is over, and `Restart=on-failure`
  does not bring it back.
- **`jq` goes last.** The replay itself runs on `jq`. When the installer
  recorded it (`priorInstalled: false`) its entry is deferred to the very
  end and marked restored *before* removal, since afterwards the marker can
  no longer be updated.
- **A failed entry keeps `aw` around.** The replay continues past a failed
  entry, the count is written to the marker (`restore_failed`) and the
  report says "restore incomplete". The restore phase is not marked done
  and `aw` does not remove itself, so `aw decommission` can be re-run: only
  the entries not yet marked `restored` are attempted again.
- **Resume keeps the mode.** `full`, `keep-foundation` or `keep-agent` is
  pinned in the marker (`mode`) when a run starts, so a run resumed at the
  next boot or tick honours the original choice. A marker without a mode
  predates the ledger; its run resumes as `keep-agent`.
- **The installer records without `jq`.** `install.sh` writes the same JSON
  by hand (its values are package names and paths), checks
  `pacman -Qi` / `dpkg-query -s` first, and deduplicates with a substring
  match. A pre-existing `/usr/local/bin/aw` is recorded as `existed: true`
  without a copy and left in place. The installer writes no units (the
  `control.join` capability does), so it records none. The self-removal
  step also removes `/var/log/alwayswork` and the two `/usr/local/bin`
  links when they still point into `/opt/alwayswork`.
- **Self-removal guard.** `ledger_self_remove` refuses when `AW_ROOT` is
  not under `/opt` or when `AW_TEST=1`, unless
  `AW_LEDGER_ALLOW_SELF_REMOVE=1` is set; a dry-run prints the plan only.
