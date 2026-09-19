# Workloads: the agent harness as a container

The node side of `docs/SYSTEM_SPEC.md` §12 (control repo). Every agent
harness on a node runs as a **standard OCI container**; the node OS is a
substrate — a CachyOS desktop, an Ubuntu Server VPS and an Arch mini PC all
run the same image.

## What `agents.dsh` does now

`aw enable agents.dsh` (or a group that lists it in desired state):

1. Pulls in `runtime.podman` (the manifest requires it; `aw apply` persists
   resolved dependencies) and makes sure `/etc/subuid` and `/etc/subgid`
   carry a `containers:` range for `userns=auto`.
2. Creates the workspace `/var/lib/alwayswork/workspaces/dsh` — a btrfs
   subvolume when the host has btrfs, a directory otherwise — and the harness
   home `/var/lib/alwayswork/dsh/home`.
3. Renders `/etc/alwayswork/dsh.env` (0600) from the sealed secret store:
   `DSH_TRUSTED_HOST`, `DSH_PORT`, every secret named `DSH_*` (prefix
   stripped) and the well-known provider variables (`DEEPSEEK_API_KEY`,
   `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`,
   `GEMINI_API_KEY`, `AI_GATEWAY_TOKEN`, `AI_GATEWAY_URL`, `OPENAI_BASE_URL`,
   `ANTHROPIC_BASE_URL`).
4. Pulls the pinned image `ghcr.io/softstone1/alwayswork-dsh:<dsh version>`;
   if the pull fails (air-gapped, CI not run yet) it builds
   `capabilities/agents.dsh/Containerfile` locally — the same file CI
   builds, so the image is identical.
5. Writes and starts `alwayswork-dsh.service`, a system unit running one
   rootful Podman container:

   | Flag | Why |
   |---|---|
   | `--userns=auto` | container root is an otherwise unused, unprivileged host uid range; two workloads never share ids |
   | `--cap-drop ALL --security-opt no-new-privileges` | from `engine_build_args` (`.hardening.container_hardening`) |
   | `--cpus / --memory / --pids-limit` | the node's `.limits` budget |
   | `--read-only --tmpfs /tmp` | only `/workspace` and `/home/dsh` are writable |
   | `--publish 127.0.0.1:<port>:<port>` | loopback only; the tunnel stays the public path |
   | `--env-file /etc/alwayswork/dsh.env` | secrets never on a command line |
   | `--volume …:/workspace:U`, `…:/home/dsh:U` | chowned into the container's uid range |

   `Type=notify` + `--sdnotify=conmon`, `Restart=always`; the unit is
   rewritten on every `aw apply` but the container is restarted only when
   the unit actually changed.
6. Retires the pre-container `alwayswork-webui.service` if present (the
   operator's old sessions stay in that account's home; nothing is deleted)
   and reports `{host, port}` in `webui.json` for the heartbeat, as before.

## The image

`capabilities/agents.dsh/Containerfile`: `node:22-bookworm-slim`, the pinned
`@deepseek-ai/dsh` tarball fetched and **sha512-verified before npm sees
it** (same pin as `ensure.sh`), git, ripgrep, curl, jq, openssh-client,
socat, tini; user `dsh` (uid 1000); `/workspace` and `/home/dsh` volumes.

The entrypoint starts the harness on `127.0.0.1:$DSH_PORT` (upstream
refuses `0.0.0.0` on purpose) with node's `--expose-internals` (its web
profile's HMR plugin needs it) and a `socat` forwarder from the container's
own interface to that loopback port, which is what podman publishes. If
either process dies the container exits and systemd restarts it.

`.github/workflows/image.yml` builds the image on every change to the
Containerfile/entrypoint/pin, smoke-tests that the UI answers, and pushes
`ghcr.io/<owner>/alwayswork-dsh:<version>` (+ `:latest` on `main`).

## Configuration

Capability config (`aw enable agents.dsh --key value`, or delivered by the
control plane under `.capabilities.config.agents.dsh`):

| Key | Default | Meaning |
|---|---|---|
| `mode` | `container` | `host` keeps the legacy on-host install (no podman; nodes without user namespaces) |
| `image` | `ghcr.io/softstone1/alwayswork-dsh:<dsh_version>` | any image ref, digest form welcome |
| `dsh_version` | the pin in `ensure.sh` | picks the tag on the default repo (and the version a local build bakes) |
| `port` | `3080` | loopback port on the node |
| `host` | `<hostname>.<baseDomain>` | the trusted public hostname |
| `network` | default bridge | `none` isolates the harness from the network entirely |
| `build` | — | `true` forces a local build instead of a pull |
| `pull` | — | `always` re-pulls even when the image exists |

`aw disable agents.dsh` removes the unit and container and keeps the
workspace, home and image; `AW_PURGE=1 aw disable agents.dsh` removes them.

## What is next (spec §12)

- A browser container (`tools.browser`: Chromium + noVNC) next to the
  harness, on the same contract.
- Workload specs from the control plane (`kind`, `engine`, `resources`,
  `network: egress-proxy`, `credentials: ai-gateway`) and sibling images for
  other engines.
- Per-task btrfs snapshots of `/workspace`.
