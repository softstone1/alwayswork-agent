# shellcheck shell=bash
# alwayswork · safe unattended updates (SYSTEM_SPEC §13.1).
#
# A rolling-release node nobody watches needs four things a plain `pacman
# -Syu` does not give it:
#   1. an update LOCK + package-manager guard: only `aw update` upgrades
#      (a pacman/apt hook refuses transactions that do not hold the lock,
#      except the agent's own capability installs, which set AW_PKG_GUARD_OK)
#   2. a HEALTH GATE after the upgrade: doctor score, tunnel up, a heartbeat
#      accepted — retried for a bounded time; on failure the file-level
#      changes are undone from the pre-update snapshot (`snapper undochange`,
#      no reboot) and the gate runs again
#   3. BOOT PROBATION: after an update the next boots re-run the gate; a box
#      that comes back unhealthy twice rolls back to the pre-update snapshot
#      (`snapper rollback` + one reboot) instead of staying broken
#   4. WAVES from the control plane: a rollout id in desired state asks this
#      node to update now; the result is reported on heartbeat so the next
#      wave waits for this one to be healthy (control repo, rollouts)
# What this cannot do: recover a kernel that does not boot at all. That is
# the bootloader's job (grub-btrfs / systemd-boot boot counting), documented
# in docs/UPDATES.md as the one manual step for a mini PC.

upd_lock_dir()       { printf '%s' "${AW_RUN_DIR:-/run/alwayswork}"; }
upd_lock_file()      { printf '%s/update.lock' "$(upd_lock_dir)"; }
upd_probation_file() { printf '%s/update-probation.json' "$AW_STATE"; }
upd_result_file()    { printf '%s/update-result.json' "$AW_STATE"; }
upd_min_score()      { cfg_get '.updates.min_doctor_score' 70; }
upd_gate_seconds()   { cfg_get '.updates.gate_seconds' 180; }
upd_guard_enabled()  { cfg_bool '.updates.guard' true; }

# --- lock + guard ------------------------------------------------------------
upd_lock() {
  ensure_dir "$(upd_lock_dir)"
  [[ "$DRY_RUN" == "1" ]] && return 0
  exec 9>"$(upd_lock_file)"
  flock -n 9 || die "another aw update is running"
  printf '%s\n' "$$" >&9
  export AW_PKG_GUARD_OK=1
}
upd_lock_held() { [[ "${AW_PKG_GUARD_OK:-0}" == "1" ]] && return 0; [[ -f "$(upd_lock_file)" ]] && ! flock -n "$(upd_lock_file)" true 2>/dev/null; }

# `aw update --guard`: the package-manager hook. Exit 0 = allowed.
upd_guard() {
  upd_guard_enabled || return 0
  if upd_lock_held; then return 0; fi
  err "alwayswork: package transactions on this node go through 'aw update' (or the agent); refusing"
  err "  (disable with: aw config set .updates.guard false)"
  return 1
}

# Hooks: pacman (Arch family) and apt (Debian family). Both run the guard
# before any transaction; the agent's own installs pass because they set
# AW_PKG_GUARD_OK in the environment the package manager inherits.
upd_install_guard_hooks() {
  upd_guard_enabled || return 0
  case "$(distro_family)" in
    arch)
      aw_write /etc/pacman.d/hooks/00-alwayswork-guard.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = AlwaysWork: only 'aw update' may change packages on this node
When = PreTransaction
Exec = /usr/local/bin/alwayswork update --guard
AbortOnFail
HOOK
      ;;
    debian)
      aw_write /etc/apt/apt.conf.d/99alwayswork-guard <<'CONF'
// AlwaysWork: only 'aw update' (or the agent) may change packages on this node.
DPkg::Pre-Invoke { "/usr/local/bin/alwayswork update --guard || exit 1"; };
CONF
      ;;
  esac
}

# --- the health gate ---------------------------------------------------------
# Returns 0 when the node is healthy: doctor >= min score, cloudflared active
# when the node is tunnel-managed, and one heartbeat accepted when enrolled.
upd_health_probe() {
  local score
  # Test seam: the suite cannot run doctor, tunnels or heartbeats.
  case "${AW_TEST_HEALTH:-}" in ok) return 0 ;; bad) return 1 ;; esac
  ASSUME_YES=1 NO_COLOR=1 "$AW_ROOT/bin/alwayswork" doctor >/dev/null 2>&1 </dev/null || true
  score="$(jq -r '.score // 0' "$(health_doctor_cache)" 2>/dev/null || printf 0)"
  [[ "$score" =~ ^[0-9]+$ ]] || score=0
  if (( score < $(upd_min_score) )); then warn "update gate: doctor score $score < $(upd_min_score)"; return 1; fi
  if declare -F tunnel_managed >/dev/null && tunnel_managed && ! systemctl is-active --quiet cloudflared 2>/dev/null; then
    warn "update gate: cloudflared is not active"; return 1
  fi
  if control_enrolled && ! control_pending; then
    if ! AW_UPDATE_GATE=1 "$AW_ROOT/bin/alwayswork" agent --once >/dev/null 2>&1 </dev/null; then
      warn "update gate: heartbeat not accepted"; return 1
    fi
  fi
  return 0
}

upd_health_gate() {
  local deadline now
  [[ "$DRY_RUN" == "1" ]] && { info "update gate: dry-run (doctor >= $(upd_min_score), tunnel, heartbeat)"; return 0; }
  deadline=$(( $(date +%s) + $(upd_gate_seconds) ))
  [[ -n "${AW_TEST_HEALTH:-}" ]] && deadline=$(( $(date +%s) ))
  log "update gate: waiting up to $(upd_gate_seconds)s for doctor >= $(upd_min_score), tunnel and a heartbeat"
  while :; do
    upd_health_probe && { ok "update gate passed"; return 0; }
    now="$(date +%s)"
    (( now >= deadline )) && { err "update gate failed"; return 1; }
    sleep 10
  done
}

# Undo the file-level changes since the pre-update snapshot (no reboot).
# snapper's undochange reverts /, including the package database, which is
# enough for a userspace regression; a bad kernel needs the boot path.
upd_undo_to_snapshot() {
  local snap="$1"
  [[ -n "$snap" ]] || { warn "update: no pre-update snapshot to undo to"; return 1; }
  snap_available || return 1
  log "update: undoing file changes since snapshot $snap (snapper undochange)"
  run snapper -c "$(snap_config)" undochange "$snap..0" || return 1
  ok "update: files restored to snapshot $snap"
}

# --- probation -------------------------------------------------------------------
upd_probation_start() {
  local snap="$1" rollout="${2:-}"
  ensure_dir "$AW_STATE"
  [[ "$DRY_RUN" == "1" ]] && return 0
  jq -n --arg s "$snap" --arg r "$rollout" --argjson at "$(( $(date +%s) * 1000 ))" \
    '{snapshot:$s, rollout:$r, startedAt:$at, boots:0, rolledBack:false}' > "$(upd_probation_file)"
}
upd_probation_clear() { run rm -f "$(upd_probation_file)"; }

# `aw update --boot-check`: run by alwayswork-boot-check.service on every
# boot. Cheap when there is no probation. Under probation: healthy -> clear;
# unhealthy twice -> roll back to the pre-update snapshot and reboot once.
upd_boot_check() {
  local f snap boots rolled
  f="$(upd_probation_file)"
  [[ -f "$f" ]] || { info "boot check: no update on probation"; return 0; }
  snap="$(jq -r '.snapshot // ""' "$f")"; boots="$(jq -r '.boots // 0' "$f")"; rolled="$(jq -r '.rolledBack // false' "$f")"
  log "boot check: update on probation (snapshot ${snap:-none}, boot $((boots + 1)))"
  if upd_health_gate; then
    ok "boot check: healthy after update; probation cleared"
    upd_record_result ok "healthy after reboot"
    upd_probation_clear
    return 0
  fi
  boots=$(( boots + 1 ))
  jq --argjson b "$boots" '.boots = $b' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  if (( boots < 2 )); then
    warn "boot check: unhealthy; one more boot before rolling back"
    return 1
  fi
  if [[ "$rolled" == "true" || -z "$snap" || "${AW_TEST:-0}" == "1" ]] || ! snap_available; then
    err "boot check: unhealthy after update and no rollback possible (snapshot: ${snap:-none}, rolledBack: $rolled)"
    upd_record_result failed "unhealthy after update; manual rollback needed"
    return 1
  fi
  err "boot check: unhealthy on two boots; rolling back to snapshot $snap and rebooting"
  jq '.rolledBack = true' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  upd_record_result rolled_back "rolled back to snapshot $snap after two unhealthy boots"
  snap_rollback "$snap" || { err "boot check: snapper rollback failed"; return 1; }
  [[ "${AW_TEST:-0}" == "1" ]] || run systemctl reboot
}

# The result the heartbeat carries (health.update): what the control plane's
# rollout waits for before the next wave.
upd_record_result() {
  local state="$1" summary="${2:-}" rollout
  rollout="$(jq -r '.rollout // ""' "$(upd_probation_file)" 2>/dev/null || true)"
  [[ -n "$rollout" ]] || rollout="$(jq -r '.rolloutId // ""' "$(upd_result_file)" 2>/dev/null || true)"
  [[ "$DRY_RUN" == "1" ]] && return 0
  ensure_dir "$AW_STATE"
  jq -n --arg r "$rollout" --arg s "$state" --arg m "$summary" --argjson at "$(( $(date +%s) * 1000 ))" \
    '{state:$s, summary:$m, at:$at} + (if $r == "" then {} else {rolloutId:$r} end)' > "$(upd_result_file)"
}
upd_result_json() { [[ -s "$(upd_result_file)" ]] && jq -c . "$(upd_result_file)" 2>/dev/null || printf 'null'; }

# Units: the boot check after the agent, and a weekly timer only when the
# operator opted out of control-plane waves (updates.mode: local).
upd_install_units() {
  aw_write /etc/systemd/system/alwayswork-boot-check.service <<'UNIT'
[Unit]
Description=AlwaysWork: verify health after an update (boot probation)
After=network-online.target alwayswork-agent.service cloudflared.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alwayswork update --boot-check
# Give the tunnel and the agent a moment before judging.
ExecStartPre=/bin/sleep 45

[Install]
WantedBy=multi-user.target
UNIT
  run systemctl daemon-reload
  run systemctl enable alwayswork-boot-check.service
}

# --- rollouts from the control plane --------------------------------------------
# Desired state carries `update: { rolloutId, requestedAt }` for a node in the
# current wave. Run the update once per id, detached from the agent (the
# agent must keep heart-beating while packages change), and report.
upd_apply_from_delivery() {
  local json="$1" id last
  jq -e '.update | type == "object"' >/dev/null 2>&1 <<<"$json" || return 0
  id="$(jq -r '.update.rolloutId // ""' <<<"$json")"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 0
  last="$(jq -r '.rolloutId // ""' "$(upd_result_file)" 2>/dev/null || true)"
  [[ "$id" == "$last" ]] && return 0
  log "control: rollout $id asks this node to update now"
  [[ "$DRY_RUN" == "1" ]] && return 0
  ensure_dir "$AW_STATE"
  jq -n --arg r "$id" --argjson at "$(( $(date +%s) * 1000 ))" '{rolloutId:$r, state:"running", summary:"update started", at:$at}' > "$(upd_result_file)"
  [[ "${AW_TEST:-0}" == "1" ]] && { info "control: (test) update not spawned"; return 0; }
  if have systemd-run; then
    systemd-run --unit "alwayswork-update-$id" --collect --quiet \
      /usr/local/bin/alwayswork update --yes --rollout "$id" \
      || { warn "control: could not start the update unit"; upd_record_result failed "could not start update"; }
  else
    ( /usr/local/bin/alwayswork update --yes --rollout "$id" ) >/dev/null 2>&1 &
  fi
}
