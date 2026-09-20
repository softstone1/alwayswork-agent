# Apps and tools

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


`aw app` installs tools on demand from a curated catalog; `aw clean` removes
what is no longer used. Neither is part of the bootstrap, so a fresh worker
stays minimal.

## Catalog

```bash
aw app list                    # everything, with an installed marker
aw app list containers         # one category
aw app search backup           # match id or description
sudo aw app install ripgrep lazygit
sudo aw app remove lazygit
```

Categories: `cli`, `dev`, `agents`, `containers`, `network`,
`security`, `monitoring`, `media`, `storage`.

The shipped catalog lives at `catalog/apps.yaml`. To add your own without
forking, copy it to `/etc/alwayswork/apps.yaml` — user entries are searched
first and can override shipped ones.

## Adding an entry

```yaml
apps:
  my-tool:
    name: My Tool
    description: What it does
    category: cli
    manager: pacman          # pacman | paru | npm | pipx
    packages: [my-tool]
```

Managers install the way you would expect: `pacman` for repository packages,
`paru` for the AUR, `npm` (global) and `pipx` for language
toolchains.

## Cleanup

```bash
sudo aw clean
```

Controlled entirely by `cleanup.*` in `worker.yaml`:

| Key | Default | Effect |
|-----|---------|--------|
| `orphans` | true | remove unneeded dependencies (`pacman -Qtdq`) |
| `package_cache` | true | keep the last 2 versions (`paccache -rk2`) |
| `journal` | true | vacuum the journal to 200M |
| `containers` | true | prune unused images |
| `volumes` | **false** | prune unused volumes (destructive; opt in) |
| `tmp` | true | delete stale `/tmp` entries |
| `max_age_days` | 2 | age threshold for `/tmp` cleanup |

Set `cleanup.volumes: true` only when you are sure no stopped container
holds data you need. `aw clean` never touches running containers, images
in use, the secret store, or agent workspaces.

## Relationship to capabilities

- A **capability** is infrastructure with lifecycle hooks: a runtime, a tunnel,
  the agent control plane. It can open ports and run services.
- An **app** is a package you want on the box. It has no hooks and no state.

If something needs a service, firewall rule or config, write a capability.
If it is just a tool, add it to the catalog.

## Host packages versus application packages

This command manages **host packages**. The historical word `app` in `aw app` is
not the new product App (a deployment of an application package). Preserve CLI
compatibility, but expose this catalog under machine host setup. Do not offer nano,
gh or a language toolchain as an independently running app. Environment dependency
resolution/builds are a separate planned package pipeline; they do not use host
`aw app install` behind the scenes.
