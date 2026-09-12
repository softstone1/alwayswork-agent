# Rolling out to many mini PCs

The bootstrap is designed to be identical on every machine; only
`worker.yaml` differs.

## One machine

```bash
curl -fsSL https://raw.githubusercontent.com/softstone1/alwayswork/main/install.sh | sudo bash
sudo aw init --profile foundation
sudo aw bootstrap
sudo aw doctor
```

## A fleet

1. Keep a per-environment config in git, e.g. `inventory/lab-01.yaml`.
2. Provision:

```bash
sudo aw init --profile foundation --force
sudo cp inventory/lab-01.yaml /etc/alwayswork/worker.yaml
sudo aw apply
sudo aw doctor
```

3. Add capabilities by editing the config + `aw apply`, or by running
   `aw enable` once and committing the resulting config back to inventory.

Because `apply` is idempotent, the same config can be re-applied at any
time (after a reinstall, a restore, or a drifted box).

## Golden images

For large fleets, install CachyOS, run `install.sh --skip-deps`, and snapshot
the image **before** `aw init`. Each machine then only needs:
`install.sh --from /opt/alwayswork && aw init --profile P && aw bootstrap`.
Do not bake secrets into the image.

## Upgrade path

```bash
# upgrade the CLI itself
sudo install.sh --from /opt/alwayswork     # or re-run the curl installer
# upgrade the system safely
sudo aw update
# reconcile after pulling a newer catalog
sudo aw apply
```

## Rollback

- System: `sudo aw snapshot list` then `sudo aw snapshot rollback <id>` and reboot.
- Capability: `sudo aw disable <cap>`.
- Full node: restore `/etc/alwayswork` and `/var/lib/alwayswork` from
  `backup.restic`.
