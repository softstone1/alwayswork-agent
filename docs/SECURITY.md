# Security model

## Defaults

| Control | Default |
|---------|---------|
| Firewall | active, **default deny inbound**, allow outbound |
| Inbound ports | **none** — public access is outbound-only via tunnel |
| SSH | disabled |
| Container socket | never exposed to capability containers |
| Secrets | age-encrypted at rest; decrypted to a runtime env file only |
| Kernel | `dmesg_restrict`, `kptr_restrict=2`, `ptrace_scope=1`, rp_filter, syncookies |
| Snapshots | btrfs/snapper before every update |

## Threat model

| Threat | Mitigation |
|--------|------------|
| Exposed service on the WAN | nothing listens publicly; tunnel is outbound-only |
| Stolen disk | **not covered by default** — decide on LUKS at install time |
| Malicious agent output | ephemeral containers, `cap-drop ALL`, no socket, resource caps, egress proxy recommended |
| Leaked API keys | sops+age store, mode 600, never in git or images |
| Bad update bricks a headless box | pre-update snapshot + documented `snapper rollback` |
| Lockout after misconfiguring the tunnel | keep a break-glass path (Tailscale or physical console) |
| Privilege escalation via container | `no-new-privileges`, `cap-drop ALL`, non-root where possible |

## What enabling a capability may change

Every capability declares its blast radius. Anything that opens a port calls
`fw_allow_port`, which records the rule so `disable` can close it again.
Container capabilities bind to `127.0.0.1` by default.

```
core               firewall, sysctl, secret store, (opt-in) update timer
runtime.*          installs/enables a container daemon
access.tunnel      installs cloudflared; opens NO inbound port
access.tailscale   opens the tailscale0 interface in the firewall
agents.core        writes a hardened runner; creates /srv workspaces
assistant.n8n      localhost:5678 container + generated encryption key
backup.restic      daily restic timer; generates a repo password
obs.uptime         localhost:3001 container
```

## Auditing

`aw doctor` scores the box: firewall state, sshd, secret-store presence and
key permissions, snapshot availability, disk headroom, pending updates, engine
socket exposure, known-vulnerable packages, and capability healthchecks. It
exits non-zero when a critical check fails, so it can gate automation.

## Recommended but not automatic

- Disk encryption (LUKS) — must be chosen before install
- Cloudflare Access identity/MFA in front of any tunnel hostname
- Egress allowlist for agent containers
- Rotating provider keys on a schedule
- 2FA on GitHub, Cloudflare and every LLM provider account
