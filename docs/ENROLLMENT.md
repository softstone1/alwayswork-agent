# Onboarding and enrollment

How a brand-new CachyOS mini PC becomes a managed Anakut Worker.

## The constraint that shapes everything

A freshly installed worker has **no inbound reachability** and **no control
agent**. The control plane therefore cannot push to a box that has not yet
contacted it. Enrollment is always **initiated by the worker** (a pull); the
console's job is to **authorize** the worker and **deliver its configuration**.

So "turn it on and start it from the web" really means: the worker announces
itself, and you **approve it in the web**. Everything else follows from that.

## TL;DR — the happy path

```
operator                          console (Cloudflare)                 new worker
   |                                    |                                  |
   |  create join token / pick group    |                                  |
   |----------------------------------->|                                  |
   |  paste one command on the box      |                                  |
   |---------------------------------------------------------------------->|
   |                                    |   POST /v1/workers/enroll        |
   |                                    |<---------------------------------|
   |                                    |   {device_id, poll_secret}       |
   |                                    |--------------------------------->|
   |  see "pending: anakut-01"          |                                  |
   |  approve, assign profile           |                                  |
   |----------------------------------->|                                  |
   |                                    |   long-poll state -> approved    |
   |                                    |--------------------------------->|
   |                                    |   device cert + config + secrets |
   |                                    |--------------------------------->|
   |                                    |   worker self-configures, joins  |
   |  worker shows "online"             |<---------------------------------|
```

## Three onboarding modes

All three converge at the same place: after approval the worker runs the same
`aw init / bootstrap / apply` path it already has.

| Mode | Who starts it | Box needs | Best for |
|------|---------------|-----------|----------|
| **A. Join token** | operator runs one command | a shell once | a single box, first install |
| **B. Claim & approve** | worker auto-announces on first boot | enroller pre-installed | headless boxes, small fleets |
| **C. Zero-touch fleet** | golden image auto-enrolls | fleet token in the image | many identical boxes |

### Honest limitation

A stock CachyOS ISO contains no `anakut-worker`. You cannot get from a bare
ISO to zero-touch without one of:

- running **one command** on the box (mode A), or
- flashing a **customised image** that includes the enroller (modes B and C).

There is no third option, because something has to run on the machine. Mode A
is the minimum human step; modes B/C remove it by baking the agent in.

## Stage 0 — Prepare (console, optional)

- Choose a **worker group** (e.g. `agents`, `assistants`, `edge`) that maps to a
  profile and a capability/app list.
- Choose an **enrollment policy**: `require-approval` (default) or
  `auto-approve` for a trusted group.
- Modes A and C mint a **single-use, short-TTL join token** bound to the group
  and to the worker's public key. Mode B needs no token.

## Stage 1 — Get the enroller onto the box

**Mode A — join token (recommended default).** The console shows a command:

```bash
curl -fsSL https://get.anakut.com/join | sudo bash -s -- --token wj_<token>
```

The token is short-lived, single-use, and useless without the box's keypair.

**Mode B — claim on first boot.** The `anakut-worker` package installs an
`anakut-worker-enroll.service` (oneshot, runs once). On boot it announces
itself; there is no token.

**Mode C — fleet image.** Same service, with a fleet identity (fleet token, or
an mTLS client cert, or a TPM-sealed secret) baked into the image at build
time. Enrolls and is auto-approved into its group.

## Stage 2 — The worker announces itself

The worker generates an **ed25519 keypair**; the private key never leaves the
machine (`/etc/anakut-worker/identity/device.key`, mode 600).

```http
POST https://control.anakut.com/v1/workers/enroll
{
  "token":   "wj_...",           // mode A/C only
  "pubkey":  "age1.../ed25519...",
  "hostname":"anakut-01",
  "machine_id":"b4f2...",         // /etc/machine-id
  "macs":    ["aa:bb:cc:dd:ee:ff"],
  "serial":  "ABCD1234",          // DMI board serial if present
  "board":   "B550I AORUS PRO AX",
  "arch":    "x86_64",
  "os":      "CachyOS",
  "version": "0.1.0"
}

201 {
  "device_id": "w_7Qk...",
  "poll_secret":"ps_...",          // only this worker ever sees it
  "state": "pending",
  "verification_uri": "https://workers.anakut.com/pair"   // optional
}
```

`machine_id` plus the MAC list is a stable, screen-free way to identify the
machine. Nothing here is secret.

## Stage 3 — Approve in the console

The console lists pending workers with their **fingerprint**: hostname, board
model, serial, MACs, source IP, and first-seen time. The operator matches that
to the physical box (sticker, label, DHCP lease) and clicks **Approve**, then
picks the group/profile.

For a box with a local terminal, an optional **pairing code** (short, e.g.
`WDJB-MJHT`) can be printed on the worker's TTY and typed into the console to
bind the exact device. This is a convenience, never a requirement — a headless
box has no screen, and fingerprint matching covers that case.

## Stage 4 — Redemption

The worker long-polls:

```http
GET /v1/workers/w_7Qk.../state?poll_secret=ps_...
-> { "state": "pending" }
-> { "state": "approved" }
```

On approval the worker receives, in one sealed response:

- a **device credential** — an mTLS client certificate or a signed,
  short-lived token that is renewed over the channel;
- the **desired configuration** — profile, capabilities, apps, limits,
  always-on policy;
- **one-time secrets** — tunnel token, provider keys — encrypted to the
  worker's public key so the server never sees them in clear.

## Stage 5 — Self-configuration

The worker writes `/etc/anakut-worker/worker.yaml`, stores its identity, then
runs the existing machinery:

```
aw init --from-enrollment
aw bootstrap          # firewall, snapshots, secrets, always-on
aw apply              # capabilities + apps from the assigned profile
```

It joins its Cloudflare Tunnel and reports **online**. At no point does anything
listen on an inbound port.

## Stage 6 — Steady state (the real payoff)

After enrollment the worker keeps an **outbound-only persistent channel** to the
control plane — a WebSocket to a Durable Object, or a tunnel plus a control
agent. Over it:

- **worker → console**: heartbeat, health, version, capability status, metrics;
- **console → worker**: desired state — enable/disable capabilities, install
  apps, rotate secrets, run a command, change limits.

The worker reconciles idempotently with `aw apply`, which is exactly what it
already does locally. The console becomes "the `worker.yaml` in the sky".

## Stage 7 — Revoke, rotate, re-enroll

- **Revoke**: the console marks the device revoked; its credential is refused
  and the channel drops. Re-enrolling mints a new keypair.
- **Rotate**: device credentials rotate on a schedule over the channel.
- **Drift**: if the hardware fingerprint changes materially, require
  re-approval.

## Security model

| Concern | Control |
|---------|---------|
| Reachability | no inbound ports at any stage; everything is outbound |
| Join token | single-use, short TTL, bound to group **and** worker pubkey |
| Approval | explicit human action in an Access-protected console |
| Device identity | ed25519 keypair, private key never leaves the box |
| Secret delivery | sealed to the device public key; never logged in clear |
| Abuse | rate-limit enrollment; alert on unexpected pending devices |
| Transport | TLS to `control.anakut.com`; console behind Cloudflare Access |
| Optional | TPM-sealed identity (this hardware has no TPM) |

Enrollment is **fail-closed**: an unapproved worker can do nothing but wait, and
a worker whose credential is revoked is refused on the next heartbeat.

## Mapping to the platform

| Piece | Where |
|-------|-------|
| Enrollment API | Cloudflare Worker `control.anakut.com` |
| Per-worker state | Durable Object (one per device) |
| Registry / search | D1 table `workers` |
| Console + approval | existing web app, behind Cloudflare Access |
| Worker side | new `aw enroll` command + `anakut-worker-enroll.service` |
| After approval | reuse `aw init/bootstrap/apply` and the capability catalog |

## Build order

1. **MVP — mode A.** `POST /v1/workers/enroll` (token + pubkey) returns a device
   credential and profile; `aw enroll --token` writes identity and config, then
   bootstraps. Console page lists workers and can revoke. This closes the loop
   end to end.
2. **Mode B.** Add `state: pending` + approval + long-poll redemption, and the
   first-boot service.
3. **Steady state.** Persistent channel + desired-state push.
4. **Mode C.** Fleet identity baked into a golden image, auto-approve into a
   group.
5. **Hardening.** Credential rotation, fingerprint drift, rate limits, alerts.

## Open decisions

- **Console vs API first** — a CLI-only MVP (`aw enroll` + a token from the API)
  could ship before any UI.
- **Channel transport** — raw WebSocket to a Durable Object, or rely on
  `cloudflared` plus a control endpoint. The tunnel is already a capability,
  so reusing it avoids a second connection.
- **Identity primitive** — mTLS certificate vs signed bearer token. mTLS is
  stronger; a token is simpler against Workers.
- **Auto-approve scope** — only ever within a group that already has a fleet
  identity, never globally.
