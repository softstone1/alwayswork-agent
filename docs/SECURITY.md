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

## SSH policies (`hardening.ssh`)

Applied by `aw bootstrap` on interactive installs and, on tunnel-managed
nodes, by the control agent once the node is active and its tunnel is up
(docs/ENROLLMENT.md, "Lockdown, deferred"). Port 22 is opened in the
firewall only by `lan`, and only for the LAN subnet.

| Policy | sshd | Listens on | Firewall | Authentication |
|--------|------|------------|----------|----------------|
| `disabled` (default) | disabled and stopped | — | nothing opened | — |
| `tailscale` | enabled | all interfaces | only `tailscale0` is allowed in (needs `access.tailscale`) | system default |
| `lan` | enabled | the LAN address (`10-alwayswork-lan.conf`) | 22 opened for the LAN subnet only | system default |
| `tunnel` | enabled | `127.0.0.1` and `::1` only (`10-alwayswork-tunnel.conf`) | nothing opened, ever | `PasswordAuthentication no`; short-lived certificates via `TrustedUserCAKeys /etc/ssh/alwayswork_access_ca.pub` |

With `tunnel`, the only way in is the Cloudflare Access SSH ingress
(`<node>-ssh.<base>` -> `ssh://127.0.0.1:22`). The Access SSH CA public key
arrives in the signed desired-state delivery as a top-level
`access.sshCa` string (OpenSSH public key format) and is written to
`/etc/ssh/alwayswork_access_ca.pub` (0644); an absent or `null` `access`
leaves the file alone, and anything that is not a single
`ssh-ed25519` / `ecdsa-*` / `ssh-rsa` key line is refused with a warning.
No `authorized_keys` are ever written. `aw doctor` grades `tunnel` as
passing when every port-22 listener is bound to loopback.

## Clock guard

Signed device requests carry a timestamp the control plane checks against a
300 s window, so the agent refuses to sign anything until the clock is
trusted: `timedatectl` reports NTP synchronised, or the wall clock is later
than a floor baked into the agent (the date the guard shipped; a reading
before it is provably wrong). `aw enroll` refuses with the same rule, the
agent unit orders itself after `time-sync.target`, and the heartbeat reports
`health.clockSynced`.

## Control-plane trust boundary

The agent talks to the control plane over mutually authenticated HTTPS
(device identity key + short-lived token), but TLS alone does not decide
what the node *runs*. Every desired-state delivery is additionally signed
by the control plane with a dedicated Ed25519 **delivery key** that the
node pins at enrollment; a compromised proxy or stolen TLS session cannot
forge deliveries.

- **Pinning.** Enrollment (`aw enroll`) pins the delivery key into
  `$AW_STATE/control-pubkey.json` (mode `0600`), keyed by key id
  (`ck-` + 12 hex chars of the key's SHA-256). Nodes that enrolled before
  pinning existed fetch the key once over TLS from `GET /v1/control-key`
  (one-time TOFU migration). A pinned key never changes silently: a
  different key id is refused loudly, never overwritten in-band.
- **Verification.** Every `/v1/device/desired` response must carry the
  `x-aw-sig-kid`, `x-aw-sig-seq`, `x-aw-sig-exp`, and `x-aw-sig` headers.
  The node checks the key id against its pin, rebuilds the canonical
  string (`AW-DESIRED-V1`, device id, sequence, expiry, SHA-256 of the
  exact response bytes), and verifies the Ed25519 signature with
  `openssl`. Expiry skew allowance is 60 seconds.
- **Freshness and rollback.** The signed sequence is monotonic. A
  delivery is refused when its sequence is older than the last applied
  version, and an `approved` delivery is applied only when
  `config.configVersion` equals the signed sequence. The node keeps its
  last-known-good config and sends no acknowledgement on any failure.
- **Rotation.** Delivery keys rotate only through explicit re-enrollment:
  `aw reset --purge` drops the pin along with enrollment state, and the
  next enrollment pins the new key. There is no silent rotation path.
- **Signed drain order.** After decommission, a node receives only a
  terminal 401 — except for one deliberate carve-out: a node whose stored
  state is `draining` may still fetch a *signed* drain order, which is
  verified exactly like any delivery before the node wipes itself. A bare
  401 never triggers a wipe, and a revoked (non-draining) tombstoned node
  stops without wiping. The drain order carries the node's monotonic
  sequence, so it can never be mistaken for a rollback.

## Threat model

| Threat | Mitigation |
|--------|------------|
| Exposed service on the WAN | nothing listens publicly; tunnel is outbound-only |
| Stolen disk | **not covered by default** — decide on LUKS at install time |
| Malicious agent output | ephemeral containers, `cap-drop ALL`, no socket, resource caps, egress proxy recommended |
| Leaked API keys | sops+age store, mode 600, never in git or images |
| Forged control-plane delivery (compromised proxy / stolen TLS session) | Ed25519-signed deliveries, key pinned at enrollment, sequence + expiry; unsigned, tampered, expired, or rolled-back deliveries are refused and keep last-known-good config |
| Replay of an old signed delivery | monotonic sequence: older-than-applied deliveries are refused, never acknowledged |
| Wipe triggered by a bare tombstone response | only a *verified signed* drain order wipes; a 401 alone stops the node without wiping |
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
