# Packages

A package is a versioned manifest the control plane delivers to a node —
only once an operator approved it, and only inside the Ed25519-signed
desired state (`SYSTEM_SPEC.md` §9). It is the one way the control plane
changes what runs on a node. There is no exec channel: the node receives
a manifest, never a command.

## Kinds

| kind | what the node does |
|---|---|
| `oci` | Runs the image as a workload container on the contract in `WORKLOADS.md`: rootful Podman, `userns=auto`, cap-drop ALL, cgroup budget, published ports on loopback only (each reported as a service so the tunnel routes `<node>-<name>.<base>` to it), data volumes as btrfs subvolumes under `/var/lib/alwayswork/workloads/<name>/`, environment from a 0600 env file (plain `env` from the manifest plus `secrets` read *by name* from the sealed store), healthcheck the unit restarts on. |
| `capability` | Enables one of this agent's capabilities with its config — `aw enable <cap> --key value`, delivered. This is how per-capability config (a Postgres version, a port) travels in desired state. |
| `distro` | Adds apps from the curated catalog (`aw app list`) to the desired list; `aw apply` installs them. |

## What happens on the node

1. Every verified delivery carries `packages: [...]`. `lib/packages.sh`
   writes the set to `/var/lib/alwayswork/packages/desired.json`.
2. Each package is compared by **digest** with
   `packages/installed/<name>.json`; unchanged manifests are reasserted because each delivery rebuilds the
   capability/app lists. An `oci` unit only restarts if its file changed.
3. New or changed ones are installed. A failure — bad image, no podman,
   unknown capability — is recorded as `failed` with the last error line
   and reported; it never blocks the rest of the delivery or makes the
   node retry the same desired state forever.
4. Packages no longer listed are removed: the unit and its service
   reports go, the env file is deleted, **the data subvolume stays**.
5. The installed set rides every heartbeat as `health.packages`
   (name, version, digest, state, error), so the console shows exactly
   which approved record each node runs.

`aw package list` shows the set; `aw package reapply` re-runs every
delivered package after you fixed something by hand. The harness can ask
for `packages` through the bridge (`OBJECTIVES.md`).

## Writing an `oci` manifest

```json
{ "kind": "oci",
  "image": "docker.io/n8nio/n8n:1.80.0",
  "publish": [{ "port": 5678, "protocol": "http" }],
  "volumes": [{ "name": "data", "path": "/home/node/.n8n" }],
  "env": { "GENERIC_TIMEZONE": "UTC" },
  "secrets": ["N8N_ENCRYPTION_KEY"],
  "resources": { "memoryMb": 2048 },
  "health": ["wget", "-q", "-O-", "http://127.0.0.1:5678/healthz"] }
```

- Pin the image by tag at least; `@sha256:` is better. The node pulls it
  once and keeps it (`podman image exists`).
- `publish[].port` is the host loopback port; `containerPort` defaults
  to the same. The first port is reported as service `<name>`, further
  ones as `<name>-<port>`.
- `secrets` are names in the group's sealed secrets (`aw secrets`); a
  missing one is a warning, the container starts without it.
- `health` is an argv; the unit stops the container when it fails and
  systemd restarts it.
- The container runs with the same hardening as every workload; images
  that must start as root to `chown` need `user` set to their service uid
  (see how `services.postgres` uses `--user 999:999`).

## Removal and reconciliation

The control plane can exclude a package or capability workload on one node,
without changing its group's assignment. Signed desired state carries the
resulting set. The agent journals previously applied capabilities and stops
workloads removed from that set, in reverse dependency order, after resolving
the capabilities still required. Data is retained and a failed removal is retried
without acknowledging convergence. Foundation removal remains decommissioning.
Distro packages remove apps from desired configuration; they do not automatically
uninstall host packages, which may have other consumers.

Service reports belong to workload IDs, not display names. Reapplication removes
stale surfaces; removal deletes the workload's reports and private env file.
The control plane rejects new unversioned/`latest` OCI manifests and control
characters in argv/env/health fields. Unit rendering escapes systemd expansion,
including dollar signs and percent specifiers, independently of shell quoting.
