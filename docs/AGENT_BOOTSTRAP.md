# Agent-driven bootstrap

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Nodes, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


The box should bootstrap itself. A human installs the worker once (or flashes
an image); from then on an **AI agent** running on the machine does the work —
enrolling, applying its profile, fixing problems and reporting back — with no
manual follow-up.

## The principle

Automation scripts are brittle; an agent is adaptive. So the control plane
delivers **desired state**, and the agent on the box decides how to reach it
using the tools it already has (`aw`, the shell, the package manager).
The agent is the reconciliation engine.

```
  control plane  --desired state-->  agent on box  --`aw`-->  the machine
        ^                                  |
        +---------- health + report -------+
```

## Zero-touch flow

1. **Seed.** One line installs `alwayswork` and the agent harness
   (DSH, opencode, or any harness). On a fleet this is baked into the image.
2. **Enroll.** The agent runs the bootstrap objective: `aw enroll --control URL`
   (with a join token, or claim-and-approve). The box announces itself.
3. **Approve.** An operator approves it in the console, or the group
   auto-approves a fleet token.
4. **Configure.** The worker receives its profile, capabilities, apps and
   sealed secrets, applies them with `aw apply`, and joins its tunnel.
5. **Report.** `aw agent` keeps running: heartbeat, long-poll for new
   desired state, reconcile on change.
6. **Operate.** The console can later change the group, rotate a secret, or
   hand the agent a new objective ("install n8n", "the tunnel is down"). The
   agent executes and reports.

Steps 2-5 are already implemented on the machine side:

```bash
sudo aw enroll --control https://alwayswork.space --token aj_...
sudo aw enable control.join          # systemd unit running: aw agent 60
sudo aw agent 60                     # or run it in the foreground
```

## The agent's tools

The agent drives the box through `aw` (shell tool) and, when it needs
control-plane operations, through a plugin that exposes them as first-class
tools. For DSH that is a Cordis tool plugin
(`dsh-plugin-alwayswork`) registering:

| Tool | Purpose |
|------|---------|
| `alwayswork_enroll` | announce this worker and wait for approval |
| `alwayswork_status` | control-plane + local status |
| `alwayswork_doctor` | scored audit; the agent fixes what it finds |
| `alwayswork_apply` | reconcile to the assigned desired state |
| `alwayswork_install_app` | install from the curated catalog |
| `alwayswork_report` | push a one-line status back to the console |

With those tools the agent can complete onboarding end to end, then keep the
box healthy.

## Why this is safe

- Enrollment is still **host-initiated and approved**; the agent cannot conjure
  access it was not granted.
- Desired state is **declarative**; the agent may choose how to apply it, but
  the control plane authors what it should be.
- Every operator action is **audited**; every device request is signed.
- The worker is **fail-closed**: pending or revoked devices can do nothing but
  wait or be refused.

## Fleet

For many boxes, bake `alwayswork` + the harness + a fleet enrollment
token into the image. First boot: the agent enrolls, the group auto-approves,
and the box configures itself. Nobody touches it.

## Agent roles

Distinguish the privileged node agent (deterministic reconciliation) from an app's
optional AI agent component. The control-plane assistant coordinates typed changes
and objectives. App agents receive only scoped tools and connections; the presence
of an AI harness never grants node-admin authority.
