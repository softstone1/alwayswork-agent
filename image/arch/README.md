# Unattended Arch image for mini PCs

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


`image/arch/` builds a bootable ISO that turns a **blank** mini PC into an
enrolled AlwaysWork node with nothing typed (SYSTEM_SPEC §4.4). It is the
Arch-family counterpart of the Ubuntu autoinstall carrier the console
generates.

```
sudo image/arch/build.sh --out out/ [--provision fleet.toml]
```

What the ISO does at boot (`installer.sh`, run by
`alwayswork-installer.service` in the live system):

1. Waits for the network, then finds `alwayswork/provision.toml` — embedded
   at build time with `--provision`, or on any FAT stick plugged in.
2. Reads `disk` (`"/dev/nvme0n1"`, or `"auto"` = the largest non-removable
   disk), `hostname`, `control_url`, `join_token`, `profile`. **Wipes that
   disk.** No file, no `disk` → stops with a message; a live shell stays on
   tty2.
3. GPT: 1 GiB ESP + btrfs (`@`, `@home`, `@var`, `@snapshots`, zstd),
   `pacstrap` base + `linux-lts` + the agent's dependencies, systemd-boot
   with a fallback entry, snapper config for `/` (what `aw update`'s
   probation rolls back to).
4. Copies the bundled agent to `/opt/alwayswork`, plants the provision file
   at `/var/lib/alwayswork/provision.toml`, enables
   `alwayswork-firstboot.service`.
5. Reboots. First boot runs the agent installer in zero-touch mode with the
   token (`install.sh --yes --control … --token …`), then shreds the file.
   The node is pending or active in the console a minute later.

Fleet variant: build once with `--provision fleet.toml` carrying a fleet
token (`maxUses > 1`) and `disk = "auto"`; flash every box with the same
stick.

**Kernel**: `linux-lts` from the Arch repos. To make the box CachyOS
(their repos, `linux-cachyos-lts`, x86-64-v3 packages), add the CachyOS
repository after first boot per their documentation; the agent treats both
as the Arch family. Baking the CachyOS repos into the image is a planned
follow-up.

**Status**: the build runs in CI (`image-arch` workflow, `archlinux`
container, privileged) and the ISO is attached to the run; booting it on
hardware is the operator's verification step — this repository's tests do
not boot ISOs.
