# Objectives and the host bridge

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
