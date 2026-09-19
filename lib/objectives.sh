# shellcheck shell=bash
# alwayswork · objectives and the host bridge (SYSTEM_SPEC §5.5).
#
# An objective is intent, signed into desired state by the control plane and
# executed by the node's harness. The harness runs in a container; the only
# thing the two share is the harness workspace, so the channel is files:
#
#   /workspace/.alwayswork/objectives/<id>.json          the objective (from the agent)
#   /workspace/.alwayswork/objectives/<id>.result.json   {state, summary}   (from the harness)
#   /workspace/.alwayswork/requests/<uuid>.json          {op, args}         (from the harness)
#   /workspace/.alwayswork/results/<uuid>.json           {ok, rc, output}   (from the agent)
# (results live in their own directory so the request directory is empty
# once served — that is what the path unit watches)
#
# The agent writes objectives from every verified delivery, reports results
# on every heartbeat, and serves REQUESTS — an allowlisted set of `aw`
# operations (`service status|logs|snapshot|backup`, `doctor`, `status`) —
# from a systemd path unit that fires when a request file appears. There is
# still no exec channel: the harness asks for a named operation, never a
# command line.

obj_root()      { printf '%s/workspaces/dsh/.alwayswork' "$AW_STATE"; }
obj_dir()       { printf '%s/objectives' "$(obj_root)"; }
obj_req_dir()   { printf '%s/requests' "$(obj_root)"; }
obj_res_dir()   { printf '%s/results' "$(obj_root)"; }
obj_state_dir() { printf '%s/objectives' "$AW_STATE"; }

obj_ensure_dirs() {
  ensure_dir "$(obj_dir)"; ensure_dir "$(obj_req_dir)"; ensure_dir "$(obj_res_dir)"; ensure_dir "$(obj_state_dir)"
  # The harness runs as uid 1000 inside userns=auto; :U on the workspace mount
  # maps ownership, but files the agent creates as root must be group/other
  # writable for the result files to land. Directory sticky bit keeps it tidy.
  [[ "$DRY_RUN" == "1" ]] || chmod 1777 "$(obj_dir)" "$(obj_req_dir)" "$(obj_res_dir)" 2>/dev/null || true
}

# obj_apply_from_delivery <delivery-json>: materialise open objectives, drop
# files for ones the control plane no longer lists (cancelled), never touch a
# result the harness already wrote.
obj_apply_from_delivery() {
  local json="$1" id f n
  jq -e '.objectives | type == "array"' >/dev/null 2>&1 <<<"$json" || return 0
  obj_ensure_dirs
  n="$(jq -r '.objectives | length' <<<"$json")"
  local -a open=()
  while IFS= read -r id; do
    [[ "$id" =~ ^obj_[A-Za-z0-9_-]{4,64}$ ]] || continue
    open+=("$id")
    f="$(obj_dir)/$id.json"
    if [[ ! -f "$f" ]]; then
      log "control: objective $id received"
      jq -c --arg id "$id" '.objectives[] | select(.id == $id) | {id, text, timeoutSec, createdAt, state:"pending"}' <<<"$json" \
        | aw_write "$f"
      [[ "$DRY_RUN" == "1" ]] || chmod 0666 "$f" 2>/dev/null || true
    fi
  done < <(jq -r '.objectives[].id' <<<"$json")
  # Anything on disk that is not open any more (cancelled, or finished and
  # acknowledged) is retired from the harness's view.
  for f in "$(obj_dir)"/obj_*.json; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.result.json ]] && continue
    id="$(basename "$f" .json)"
    local keep=0 o
    for o in "${open[@]:-}"; do [[ "$o" == "$id" ]] && keep=1; done
    if (( ! keep )); then run rm -f "$f" "$(obj_dir)/$id.result.json"; fi
  done
  (( n > 0 )) && info "control: $n open objective(s) for the harness"
  return 0
}

# The heartbeat's `objectives` array: every result the harness wrote, plus
# "running" for objectives whose file the harness has touched (state field).
obj_reports_json() {
  local d f id state summary at
  d="$(obj_dir)"
  [[ -d "$d" ]] || { printf '[]'; return 0; }
  for f in "$d"/obj_*.result.json; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .result.json)"
    state="$(jq -r '.state // ""' "$f" 2>/dev/null)"
    case "$state" in running|done|failed) ;; *) continue ;; esac
    summary="$(jq -r '.summary // ""' "$f" 2>/dev/null | head -c 4000)"
    at="$(( $(stat -c %Y "$f" 2>/dev/null || date +%s) * 1000 ))"
    jq -nc --arg id "$id" --arg s "$state" --arg m "$summary" --argjson at "$at" '{id:$id, state:$s, summary:$m, at:$at}'
  done | jq -sc '.'
}

# --- the host bridge ------------------------------------------------------------
# Allowlisted operations the harness may ask the node for. Each maps to an
# `aw` invocation with fixed shape; arguments are validated, never spliced.
obj_bridge_serve_once() {
  local d r f id op out rc
  d="$(obj_req_dir)"; r="$(obj_res_dir)"
  [[ -d "$d" ]] || return 0
  ensure_dir "$r"
  for f in "$d"/*.json; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .json)"
    [[ "$id" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { run rm -f "$f"; continue; }
    op="$(jq -r '.op // ""' "$f" 2>/dev/null)"
    out=""; rc=0
    case "$op" in
      status)           out="$(NO_COLOR=1 "$AW_ROOT/bin/alwayswork" --json status 2>&1)" || rc=$? ;;
      doctor)           out="$(ASSUME_YES=1 NO_COLOR=1 "$AW_ROOT/bin/alwayswork" doctor 2>&1)" || rc=$? ;;
      services)         out="$(NO_COLOR=1 "$AW_ROOT/bin/alwayswork" service list 2>&1)" || rc=$? ;;
      packages)         out="$(NO_COLOR=1 "$AW_ROOT/bin/alwayswork" package list 2>&1)" || rc=$? ;;
      service.status|service.logs|service.snapshot|service.backup)
        local svc; svc="$(jq -r '.args[0] // ""' "$f" 2>/dev/null)"
        if [[ "$svc" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
          out="$(NO_COLOR=1 "$AW_ROOT/bin/alwayswork" service "${op#service.}" "$svc" 2>&1)" || rc=$?
        else out="bad service id"; rc=2; fi ;;
      *) out="unknown op: $op (allowed: status, doctor, services, packages, service.status|logs|snapshot|backup <id>)"; rc=2 ;;
    esac
    log "bridge: $op -> rc $rc"
    jq -nc --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" --arg out "$(printf '%s' "$out" | head -c 20000)" --argjson rc "$rc" \
      '{ok:$ok, rc:$rc, output:$out}' > "$r/$id.json"
    chmod 0666 "$r/$id.json" 2>/dev/null || true
    run rm -f "$f"
  done
  # Results older than a day are noise.
  find "$r" -name '*.json' -mmin +1440 -delete 2>/dev/null || true
}

# Units: a path unit fires the bridge the moment a request lands.
obj_install_units() {
  local d; d="$(obj_req_dir)"
  aw_write /etc/systemd/system/alwayswork-bridge.service <<UNIT
[Unit]
Description=AlwaysWork: serve an allowlisted request from the node's harness

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alwayswork bridge --once
UNIT
  aw_write /etc/systemd/system/alwayswork-bridge.path <<UNIT
[Unit]
Description=AlwaysWork: watch the harness request directory

[Path]
DirectoryNotEmpty=$d
MakeDirectory=yes
DirectoryMode=1777

[Install]
WantedBy=multi-user.target
UNIT
  run systemctl daemon-reload
  run systemctl enable --now alwayswork-bridge.path 2>/dev/null || true
}
