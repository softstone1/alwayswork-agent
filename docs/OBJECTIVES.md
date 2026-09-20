# Objectives and the host bridge

> **App-model revision (September 2026):** the [canonical app model](https://github.com/softstone1/alwayswork-control/blob/main/docs/APP_MODEL.md)
> defines Apps, Packages, Components, Instances, Machines, Volumes, Connections and
> Interfaces. Existing CLI names, capability IDs, `workload` metadata and host
> `apps` configuration remain compatibility contracts. This document describes
> existing mechanics; the new runtime features are planned unless stated otherwise.


The node side of `docs/SYSTEM_SPEC.md` §5.5 (control repo). An objective is
**intent**, signed into desired state by the control plane and executed by
the node's harness. The harness runs in a container; the only thing it
shares with the node's agent is its workspace, so the channel is files.

```
/var/lib/alwayswork/workspaces/dsh/.alwayswork/     (= /workspace/.alwayswork in the container)
  objectives/<id>.json           the objective  {id, text, timeoutSec, createdAt}   ← agent
  objectives/<id>.result.json    {state: running|done|failed, summary}              ← harness
  requests/<uuid>.json           {op, args}                                          ← harness
  results/<uuid>.json            {ok, rc, output}                                    ← agent
```

- On every verified delivery the agent materialises the open objectives
  and retires the ones the control plane no longer lists (done, cancelled).
- On every heartbeat the agent reports every result file as
  `objectives: [{id, state, summary, at}]`.
- **The bridge**: `alwayswork-bridge.path` fires `aw bridge --once` the
  moment a request file appears. Allowed operations: `status`, `doctor`,
  `services`, `service.status|logs|snapshot|backup <id>`. Arguments are
  validated, never spliced into a command line; anything else is refused
  with `ok: false`. Results land in `results/` so the watched directory
  empties.

The harness side is `dsh-plugin-alwayswork` (`alwayswork_objectives`,
`alwayswork_objective_update`, `alwayswork_service`, …) with the
`alwayswork-operator` skill. There is still no exec channel anywhere.

## AI and typed operations

The control assistant and manual UI must share typed, permission-checked operations.
Existing objectives and bridge operations are the compatibility execution path.
Package operation metadata is discovery, not authorization. SQL, MCP and HTTP
adapters must enforce the same scope and audit contract; no unrestricted host shell
or provider credential access is implied. The node provides deterministic handlers,
not an LLM dependency for restart, reconciliation, backups or security enforcement.
