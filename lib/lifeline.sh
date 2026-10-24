# shellcheck shell=bash
# alwayswork · lifeline: recovering the agent without a person (docs/RECOVERY.md
# in the control plane).
#
# The agent is one loop; when something it waits on hangs, the node goes
# silent. Three layers keep that from needing a human:
#   1. the agent unit's WatchdogSec restarts a loop that stops pinging;
#   2. doctor runs out of band (lib/health.sh), never inside the heartbeat;
#   3. this lifeline, a separate timer that does not depend on the agent:
#      - restarts the agent when its heartbeats stopped, and
#      - runs the control plane's signed recovery commands.
#
# Recovery commands are fixed verbs (restart-agent, reinstall-agent), each
# signed by the pinned control-plane key in the AW-RECOVERY-V1 domain over
# device id, command id, action and expiry. They are run once per command
# id. There is no way to send this node a command line.

LIFELINE_STALE_SEC="${AW_LIFELINE_STALE_SEC:-900}"
LIFELINE_ACTIONS=(restart-agent reinstall-agent)

lifeline_state() { printf '%s\n' "$AW_STATE/lifeline.json"; }
lifeline_done_file() { printf '%s\n' "$AW_STATE/recovery-done"; }

# lifeline_note <action> <why> — the last thing the lifeline did, for doctor.
lifeline_note() {
  jq -nc --arg a "$1" --arg w "$2" --argjson at "$(date +%s)" '{action:$a, why:$w, at:$at}' | aw_write "$(lifeline_state)" 2>/dev/null || true
}

lifeline_restart_agent() {
  log "lifeline: restarting the agent ($1)"
  run systemctl restart alwayswork-agent.service
}

# Layer 3a: heartbeats stopped while the agent claims to run.
lifeline_local_check() {
  local last now last_action_at
  systemctl is-active --quiet alwayswork-agent.service 2>/dev/null || return 0
  last="$(cat "$AW_STATE/last-heartbeat" 2>/dev/null || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  now="$(date +%s)"
  (( last > 0 && now - last > LIFELINE_STALE_SEC )) || return 0
  # At most one local restart per stale window: a node that is offline for
  # a network reason must not be restarted every two minutes.
  last_action_at="$(jq -r '.at // 0' "$(lifeline_state)" 2>/dev/null || echo 0)"
  [[ "$last_action_at" =~ ^[0-9]+$ ]] || last_action_at=0
  (( now - last_action_at > LIFELINE_STALE_SEC )) || return 0
  lifeline_restart_agent "no successful heartbeat for $(( (now - last) / 60 )) minutes"
  lifeline_note restart-agent "stale heartbeat"
}

# lifeline_verify <command-json> — 0 when the command is authentic, for this
# node, a known verb, unexpired and never run before.
lifeline_verify() {
  local cmd="$1" id action exp kid sig pinned now tmp vrc=0
  id="$(jq -r '.id // ""' <<<"$cmd")"; action="$(jq -r '.action // ""' <<<"$cmd")"
  exp="$(jq -r '.expiresAt // 0' <<<"$cmd")"; kid="$(jq -r '.kid // ""' <<<"$cmd")"; sig="$(jq -r '.sig // ""' <<<"$cmd")"
  [[ "$id" =~ ^rc_[A-Za-z0-9_-]{6,40}$ ]] || { err "lifeline: malformed recovery command id; refusing"; return 1; }
  local a known=0; for a in "${LIFELINE_ACTIONS[@]}"; do [[ "$a" == "$action" ]] && known=1; done
  (( known )) || { err "lifeline: unknown recovery action '$action'; refusing"; return 1; }
  [[ "$exp" =~ ^[0-9]+$ ]] || { err "lifeline: malformed expiry; refusing"; return 1; }
  now="$(date +%s%3N)"
  (( exp > now )) || { err "lifeline: recovery command $id expired; refusing"; return 1; }
  pinned="$(jq -r '.kid // ""' "$(control_pubkey_file)" 2>/dev/null)"
  [[ -n "$pinned" && "$kid" == "$pinned" ]] || { err "lifeline: recovery key id does not match the pinned control-plane key; refusing"; return 1; }
  if grep -qx "$id" "$(lifeline_done_file)" 2>/dev/null; then return 2; fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/aw-rc.XXXXXX")" || return 1
  printf 'AW-RECOVERY-V1\n%s\n%s\n%s\n%s' "$(control_device_id)" "$id" "$action" "$exp" > "$tmp"
  control_verify_pinned "$tmp" "$sig" || vrc=$?
  rm -f "$tmp"
  (( vrc == 0 )) || { err "lifeline: RECOVERY SIGNATURE INVALID for $id; refusing"; return 1; }
  return 0
}

lifeline_ack() { # <id> <ok true|false> <detail>
  control_call POST "/v1/device/recovery/$1/ack" "$(jq -nc --argjson ok "$2" --arg d "$3" '{ok:$ok, detail:$d}')" >/dev/null \
    || warn "lifeline: could not report recovery $1 (it is retried while the command is open)"
}

# Layer 3b: the control plane's signed recovery command, if any.
lifeline_poll() {
  local resp cmd id action vrc=0 ok=true detail
  control_clock_trusted 2>/dev/null || return 0
  resp="$(control_call GET /v1/device/recovery)" || return 0
  cmd="$(jq -c '.command // null' <<<"$resp" 2>/dev/null)" || return 0
  [[ -n "$cmd" && "$cmd" != "null" ]] || return 0
  id="$(jq -r '.id' <<<"$cmd")"; action="$(jq -r '.action' <<<"$cmd")"
  lifeline_verify "$cmd" || vrc=$?
  if (( vrc == 2 )); then lifeline_ack "$id" true "already run on this node"; return 0; fi
  (( vrc == 0 )) || return 1
  printf '%s\n' "$id" >> "$(lifeline_done_file)"
  case "$action" in
    restart-agent)
      if lifeline_restart_agent "operator request $id"; then detail="agent restarted"; else ok=false; detail="systemctl restart failed"; fi ;;
    reinstall-agent)
      log "lifeline: reinstalling the agent the control plane pins (operator request $id)"
      if AW_AGENT_FORCE=1 upd_agent_upgrade; then
        lifeline_restart_agent "after reinstall" || true
        detail="agent reinstalled at $(upd_agent_installed | head -c 12)"
      else ok=false; detail="reinstall failed (see update.log)"; fi ;;
  esac
  lifeline_note "$action" "operator request $id"
  lifeline_ack "$id" "$ok" "$detail"
}

lifeline_run() {
  control_enrolled 2>/dev/null || return 0
  control_pending 2>/dev/null && return 0
  lifeline_local_check
  lifeline_poll
}
