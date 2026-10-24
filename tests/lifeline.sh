#!/usr/bin/env bash
# The lifeline (lib/lifeline.sh): restarting a silent agent and running the
# control plane's signed recovery commands. A real Ed25519 key signs the
# commands so control_verify_pinned runs exactly as on a node; systemctl and
# the control plane are stubs.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

S="$TMP/stubs"; mkdir -p "$S"
export CALLS="$TMP/calls" AGENT_ACTIVE="$TMP/agent-active"
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$CALLS"\ncase "$*" in *is-active*alwayswork-agent*) [[ -f "$AGENT_ACTIVE" ]];; *) exit 0;; esac\n' > "$S/systemctl"; chmod +x "$S/systemctl"
export PATH="$S:$PATH"
export AW_TEST=1 DRY_RUN=0 AW_ROOT="$ROOT" AW_ETC="$TMP/etc" AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log" AW_CONFIG="$TMP/etc/worker.yaml"
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_LOG_DIR"; touch "$AGENT_ACTIVE"
DEV="dev_test123"

# The control-plane key, pinned the way enrolment pins it.
openssl genpkey -algorithm ed25519 -out "$TMP/cp.pem" 2>/dev/null
PUB="$(openssl pkey -in "$TMP/cp.pem" -pubout -outform DER 2>/dev/null | base64 -w0)"
jq -nc --arg p "$PUB" '{kid:"ck-test", publicKey:$p}' > "$AW_STATE/control-pubkey.json"

sign() { # <id> <action> <exp> [device]
  printf 'AW-RECOVERY-V1\n%s\n%s\n%s\n%s' "${4:-$DEV}" "$1" "$2" "$3" > "$TMP/msg"
  openssl pkeyutl -sign -inkey "$TMP/cp.pem" -rawin -in "$TMP/msg" 2>/dev/null | base64 -w0
}
command_json() { # <id> <action> [exp] [kid] [sig-device]
  local exp="${3:-$(( $(date +%s%3N) + 600000 ))}"
  jq -nc --arg id "$1" --arg a "$2" --argjson e "$exp" --arg k "${4:-ck-test}" --arg s "$(sign "$1" "$2" "$exp" "${5:-$DEV}")" '{command:{id:$id, action:$a, expiresAt:$e, kid:$k, sig:$s}}'
}

run_lifeline() { # [server-response]
  ( source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/control.sh"; source "$ROOT/lib/updates.sh"; source "$ROOT/lib/lifeline.sh"
    control_device_id() { echo "$DEV"; }; control_enrolled() { true; }; control_pending() { false; }; control_clock_trusted() { true; }
    control_call() { echo "control_call $1 $2 ${3:-}" >> "$CALLS"; local none='{"command":null}'; [[ "$1" == GET ]] && printf '%s' "${RESP:-$none}"; return 0; }
    upd_agent_upgrade() { echo "upgrade AW_AGENT_FORCE=${AW_AGENT_FORCE:-}" >> "$CALLS"; [[ "${UPGRADE_FAIL:-0}" != 1 ]]; }
    lifeline_run ) > "$TMP/out" 2>&1
}
calls() { cat "$CALLS" 2>/dev/null; }
reset() { : > "$CALLS"; }

echo "== lifeline: silent agent =="
date +%s > "$AW_STATE/last-heartbeat"; reset
check "a fresh heartbeat leaves the agent alone"     'run_lifeline && ! calls | grep -q "systemctl restart"'
echo $(( $(date +%s) - 1000 )) > "$AW_STATE/last-heartbeat"; reset
check "a stale heartbeat restarts the agent"         'run_lifeline && calls | grep -q "systemctl restart alwayswork-agent.service"'
reset
check "but only once per stale window"               'run_lifeline && ! calls | grep -q "systemctl restart"'
date +%s > "$AW_STATE/last-heartbeat"; rm -f "$AW_STATE/lifeline.json"

echo "== lifeline: signed recovery =="
reset
check "no command: nothing happens"                  'run_lifeline && ! calls | grep -q "systemctl restart" && ! calls | grep -q ack'
reset
check "a signed restart-agent runs and is acked ok"  'RESP="$(command_json rc_restart001 restart-agent)" run_lifeline && calls | grep -q "systemctl restart alwayswork-agent.service" && calls | grep -q "POST /v1/device/recovery/rc_restart001/ack {\"ok\":true"'
reset
check "the same command id never runs twice"         'RESP="$(command_json rc_restart001 restart-agent)" run_lifeline && ! calls | grep -q "systemctl restart" && calls | grep -q "rc_restart001/ack"'
reset
check "reinstall-agent reinstalls, then restarts"    'RESP="$(command_json rc_reinst0001 reinstall-agent)" run_lifeline && calls | grep -q "upgrade AW_AGENT_FORCE=1" && calls | grep -q "systemctl restart alwayswork-agent.service"'
reset
check "a failed reinstall is acked as failed"        'RESP="$(command_json rc_reinst0002 reinstall-agent)" UPGRADE_FAIL=1 run_lifeline; calls | grep -q "rc_reinst0002/ack {\"ok\":false"'
reset
check "a forged signature is refused"                'RESP="$(command_json rc_forged0001 restart-agent | jq -c ".command.sig = \"$(printf x%.0s {1..64} | base64 -w0)\"")" run_lifeline; ! calls | grep -q "systemctl restart" && grep -q "SIGNATURE INVALID" "$TMP/out"'
reset
check "a command signed for another node is refused" 'RESP="$(command_json rc_other00001 restart-agent "" "" dev_other)" run_lifeline; ! calls | grep -q "systemctl restart"'
reset
check "an unknown verb is refused (no command lines)" 'RESP="$(command_json rc_shell00001 "rm -rf /")" run_lifeline; ! calls | grep -q "systemctl restart" && grep -q "unknown recovery action" "$TMP/out"'
reset
check "an expired command is refused"                'RESP="$(command_json rc_expired001 restart-agent 1000)" run_lifeline; ! calls | grep -q "systemctl restart"'
reset
check "a different key id is refused"                'RESP="$(command_json rc_kid0000001 restart-agent "" ck-other)" run_lifeline; ! calls | grep -q "systemctl restart"'

echo "== self-healing units =="
J="$ROOT/capabilities/control.join/install.sh"
check "agent unit has a watchdog systemd can kill on" 'grep -q "^WatchdogSec=900$" "$J" && grep -q "^NotifyAccess=all$" "$J"'
check "the agent loop pings the watchdog"            'grep -q "control_watchdog_ping" "$ROOT/lib/control.sh" && grep -q "systemd-notify --pid" "$ROOT/lib/control.sh"'
check "lifeline timer every two minutes, bounded"   'grep -q "^OnUnitActiveSec=2min$" "$J" && grep -q "alwayswork lifeline" "$J" && grep -q "^TimeoutStartSec=900$" "$J"'
check "uninstall removes the lifeline"              'grep -q "alwayswork-lifeline.timer" "$ROOT/capabilities/control.join/uninstall.sh"'
check "doctor runs out of band with a runtime limit" 'grep -q "systemd-run --quiet --collect --unit=alwayswork-doctor --property=RuntimeMaxSec=300" "$ROOT/lib/health.sh"'

printf '       lifeline: passed %d failed %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
