# Workloads: the agent harness as a container

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Machines, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


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
tini; user `dsh` (uid 1000); `/workspace` and `/home/dsh` volumes.

The entrypoint starts the harness on `127.0.0.1:$DSH_PORT` (upstream
refuses `0.0.0.0` on purpose) with node's `--expose-internals` (its web
profile's HMR plugin needs it), and the **gate** on the container's own
interface — which is what podman publishes. If either process dies the
container exits and systemd restarts it.

## The gate: node-side session mint (spec §10 B)

`capabilities/agents.dsh/gate.mjs` (zero dependencies) is the reverse
proxy in front of the harness. The harness only trusts its own signed
browser-session cookie; a request that arrives through the tunnel was
authenticated by Cloudflare Access at the edge but carries none. The gate
closes that gap on the node, so the per-node proxy Worker is no longer
needed:

1. Verifies `Cf-Access-Jwt-Assertion` (or the `CF_Authorization` cookie)
   as an RS256 JWT against the team's JWKS
   (`https://<team>/cdn-cgi/access/certs`, cached 10 min): issuer, the
   node-UI application's AUD, expiry.
2. Or verifies an `aw-session` cookie signed by the control plane's
   Ed25519 key, which the node pinned at enrolment (`aw-session=v1.<payload>.<sig>`,
   payload `{sub, host, exp}`, host must equal the request authority) — the
   tenant path (spec §12.6).
3. Mints the harness's cookie `dsh-auth-<sha256(authority)>` from the secret
   in `~/.dsh/.credentials.yaml` (record `client-connection/browser-session`),
   strips any stale `dsh-auth-*` cookie, and proxies HTTP and WebSocket
   upgrades to `127.0.0.1:$DSH_PORT`.
4. Anything else is a 401. With neither `AW_ACCESS_TEAM_DOMAIN`+`AW_ACCESS_AUD`
   nor `AW_CONTROL_PUBKEY_FILE` configured it refuses everything and says
   so. `/_aw/health` answers 204 without auth for the node's healthcheck.

The facts it needs arrive in signed desired state as `access.teamDomain`
and `access.uiAud` (the control plane's `ACCESS_TEAM_DOMAIN` and
`ACCESS_NODE_UI_AUD`, or a group's own `access.uiAud`); the agent records
them under `.access.*` and renders them into `dsh.env`. The pinned control
key is mounted read-only at `/run/alwayswork/control-pubkey.json`.
`tests/gate.test.mjs` exercises all of it against a fake JWKS and harness.

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

## `tools.browser`: the agent's browser (spec §12.5)

```bash
sudo aw enable tools.browser            # Chromium + noVNC, profile kept
```

The same contract: image `ghcr.io/softstone1/alwayswork-browser`, uid
1000, `cap-drop ALL`, `userns=auto`, 2 GB budget (`memory_mb`), profile on
`/var/lib/alwayswork/browser/profile` (a subvolume). Two doors:

| | Where | Who |
|---|---|---|
| CDP (`:9222`) | `http://alwayswork-browser:9222` on the node's `alwayswork` podman network; the harness gets `BROWSER_CDP_URL` / `PLAYWRIGHT_CDP_URL` in its env | the agent (Playwright, Puppeteer, any CDP client) |
| noVNC (`:6080`) | `127.0.0.1:6080/vnc.html` on the node; reported as the `browser` service, so `<node>-browser.<base>` through the tunnel behind Access | a human, to watch or take over |

The container is the sandbox (`userns=auto`), so Chromium runs with
`--no-sandbox`; nothing on the node is exposed but the two loopback ports.
Logins persist in the profile; a `start_url` can be pinned in config.

All workloads join the node-local `alwayswork` podman network (created by
`runtime.podman`): containers resolve each other by name, nothing is
published to the host except what each workload puts on `127.0.0.1`.
`network: none` isolates a workload entirely.

## What is next (spec §12)

- Workload specs from the control plane (`kind`, `engine`, `resources`,
  `network: egress-proxy`, `credentials: ai-gateway`) and sibling images for
  other engines.
- Per-task btrfs snapshots of `/workspace`.

## Surfaces

How a workload is reached (`SYSTEM_SPEC.md` §12.8). A capability declares
each with `wl_report_surface <workload> <id> <kind> <port> [path] [name] [primary]`
(`kind`: `http` | `vnc` | `tcp` | `cdp` | `ssh`); a package with
`publish[].kind` / `publish[].name`. Files land in
`/var/lib/alwayswork/services/<id>.json`, ride the heartbeat as
`expose.services`, and the control plane routes `<node>-<id>.<base>` to
each — the harness's primary UI stays `<node>.<base>`. The console shows
one Open / Watch / Connect per workload row.

## Images, versions and channels

Every workload capability declares in its `manifest.yaml` where its image
comes from and how its version is chosen:

```yaml
workload:
  image:
    repo: ghcr.io/softstone1/alwayswork-dsh
    version: { source: npm, package: "@deepseek-ai/dsh", channel: latest, config: dsh_version, pinned: "0.1.5-rc.2" }
```

- `source: npm` — the package's npm dist-tags (`latest`, `next`) name the
  channel versions; CI bakes an image for each one every day (`image.yml`
  schedule), verified against the registry's integrity, so a channel only
  ever points at a version that has an image.
- `source: ghcr` — the image's own tags (the browser: build dates).
- `source: pinned` — the pin only (Postgres major, a side-car).

The control plane resolves each repo's channels and tells every node in the
heartbeat answer (`images`); the node keeps that as `image-targets.json`.
`wl_want_version`: explicit config (`dsh_version`) → the channel
(`channel: latest | next | pinned`, per capability config) → the pin.
A node never pulls on its own clock: it reports `health.imageUpdates`
(running vs wanted) and the console shows *image update*; **Update** (or a
wave) runs `aw update`, which upgrades the agent, packages, then
re-converges workloads — only the containers whose unit changed restart —
and gates on health. A failed gate reverts to the previous channel versions
first, then to the file snapshot.

## Desired-state removal

An updated control plane can remove or restore workloads on an individual node.
`aw apply` compares the resolved desired capability set with
`$AW_STATE/applied-capabilities.json`, uninstalls absent workload capabilities,
and retains dependencies and persistent data. The journal advances only after
successful convergence, so failed removals are retried. An agent from before
this change must be upgraded before relying on remote workload removal.

## Apps, components and instances

The current workload helper is the runtime adapter for app components. Existing
units such as `alwayswork-dsh` and paths under `workspaces/dsh` are singletons;
multiple packages targeting agents.dsh do not create independent apps. The next
runtime migration must scope units, volume ownership, interfaces and reports by
app/component/instance identity and preserve old data explicitly.

Base OS/userspace, runtime and dependency packages form the component environment.
The node host OS remains independent. Resource changes declare live/restart/migration
requirements. Compose describes component relationships, never an unvalidated host
execution escape. Keep persistent volumes outside disposable instance state.
