# Design

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


## Goal

Turn a bare CachyOS / Arch mini PC into a **secure AlwaysWork node**, then let
an operator grow it one capability at a time. The bootstrap must be idempotent,
reversible, and portable across hardware.

## Layers

```
L4  capabilities   runtime.docker  access.tunnel  agents.core  assistant.n8n ...
L3  control        bin/alwayswork + commands/ + lib/capability.sh
L2  platform       lib/{config,engine,firewall,secrets,snapshot,hardware}.sh
L1  host           CachyOS: btrfs, snapper, pacman, systemd, ufw
```

**L1 host** stays boring. alwayswork does not replace the distro's package
management, firewall, or init system; it configures them.

**L2 platform** is a set of small bash libraries, each with one job. They never
know about a specific capability.

**L3 control** is the CLI. Commands are thin: parse arguments, call libs and
capability hooks.

**L4 capabilities** are where every feature lives. A capability is a directory
with a manifest and hooks. Nothing here is compiled into the CLI.

## Desired state

`/etc/alwayswork/worker.yaml` is the single source of truth. It holds
hardening policy, engine choice, limits, access config and the enabled
capability list with per-capability config. `aw apply` reconciles the machine
to it. `aw enable` / `disable` edit the file and reconcile.

`config/defaults.yaml` provides every key so callers never need deep-merge
logic; profiles (`profiles/*.yaml`) only select a starting capability set.

## Capability contract

```
capabilities/<id>/
  manifest.yaml    id, name, description, requires[], profiles[]
  preflight.sh     optional; fail fast (missing runtime, missing secret)
  install.sh       idempotent; must be safe to re-run
  uninstall.sh     remove what install added; never delete user data
  healthcheck.sh   optional; exit 0 when healthy
```

Hooks are **sourced** inside a subshell with `CAP_ID` and `CAP_DIR` exported,
so they can call any library helper (`cfg_get`, `engine_run`,
`fw_allow_port`, `sec_get`, `aw_write`, ...). They may use `local`.

Dependencies are declared in `requires` and resolved topologically, so
`aw enable access.tunnel` never installs before `core`.

## Engine abstraction

The container runtime is a capability, not an assumption:

| Concern | Behaviour |
|---------|-----------|
| Engine | `engine.runtime` = `docker@@ | `podman@@ | `none@@ |
| Launch | `engine_run` builds hardening + limit flags and calls the engine |
| Socket | never mounted into a capability container |
| Compose | `engine_compose_cmd` degrades to `podman-compose` |

## Limits are defaults, not walls

| `limits.mode` | Effect |
|-----|--------|
| `auto` | derive per-container memory from RAM and `max_concurrent` |
| `fixed` | use `limits.defaults.memory_mb` |
| `off` | pass **no** `--memory`/`--cpus` flags at all |

Hardening (`cap-drop ALL`, `no-new-privileges`, `pids-limit`) is likewise
controlled by `hardening.container_hardening`. An operator who needs full
flexibility sets `limits.mode: off` and still keeps the firewall and secret
store.

## Safe updates

`aw update` takes a snapper snapshot first, runs the package upgrade, and
on failure prints the exact rollback command. With btrfs the previous system is
one reboot away. `hardening.auto_update` (default false) may enable a weekly
timer that runs this same path.

## Extensibility

`aw capability add <path>` copies an out-of-tree capability into
`/etc/alwayswork/capabilities.d`. Discovery walks both the shipped catalog
and the user directory, so third-party tooling never requires a fork.

## Updated product boundary

The host is a thin node foundation; it owns identity, runtime, security enforcement,
shared telemetry collection and signed reconciliation. Applications run in isolated
components. Container software dependencies belong to package environments, not the
host app installer. The first refactor classifies catalog entries without changing
wire formats. Future instance-scoped state is required before multiple independent
copies of a singleton capability can run. See the canonical app model for sequence.

## Terminology

Use Node for enrolled compute in both the console and agent documentation. Host
means its underlying OS or execution boundary (host metrics, host-level services).
An app environment is separate from the host OS. Onboarding may say “Connect a
computer or VPS.” Existing machineId fields and CLI/protocol identifiers are unchanged.
