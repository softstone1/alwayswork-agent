# Writing a capability

A capability is any directory containing a `manifest.yaml`. Copy the shape
below and register it:

```bash
mkdir -p my-capability
# ... create manifest.yaml + install.sh ...
sudo aw capability add ./my-capability
sudo aw enable my.id
```

## manifest.yaml

```yaml
id: my.id                       # must match the directory name you register
name: Human readable name
description: One line shown by 'aw list'
version: 1
requires: [core]                # installed first (topological)
profiles: [full]                # informational
```

## Hooks

| File | When | Contract |
|------|------|----------|
| `preflight.sh` | before install | `die` if a precondition is missing |
| `install.sh` | enable / apply / bootstrap | idempotent; safe to re-run |
| `uninstall.sh` | disable | remove what install added |
| `healthcheck.sh` | `aw doctor` | exit 0 when healthy |

Hooks are sourced in a subshell with `CAP_ID` and `CAP_DIR` set, and may
use every helper defined in `lib/`.

## Helper cheatsheet

```bash
# config
cfg_get '.some.path' default
cfg_bool  '.some.flag' false
cfg_set_str '.capabilities.config.my.id.key' "value"
cap_config key                 # reads .capabilities.config.$CAP_ID.key

# secrets (sops + age)
sec_has KEY  &&  sec_get KEY
sec_set KEY "value"

# firewall (tracked so disable can undo it)
fw_allow_port "$CAP_ID" 8080 tcp
fw_close_port "$CAP_ID" 8080 tcp
fw_allow_iface "$CAP_ID" tailscale0

# containers
engine_run <name> <image> [args...]
engine_run_once <name> <image> [args...]
engine_rm <name>

# files & misc
aw_write /etc/example.conf <<'EOF'
...
EOF
aw_random_hex
run pacman -S --needed --noconfirm <pkg>
```

Use `run` for every mutating command so `--dry-run` works.

## Rules

1. **Idempotent.** Enabling twice must be a no-op, not an error.
2. **Reversible.** If `disable` cannot fully undo it, say so in
   `uninstall.sh` and never delete user data.
3. **No inbound by default.** If you need a port, call `fw_allow_port` and
   prefer binding to `127.0.0.1` and fronting it with `access.tunnel`.
4. **No plaintext secrets.** Read from the store; never write a key into git.
5. **No engine socket.** Never bind-mount `/var/run/docker.sock`.
6. **Declare dependencies.** If you need a runtime, `requires` it or check
   `engine_present` in `preflight.sh`.
