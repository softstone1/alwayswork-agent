#!/usr/bin/env bash
# No host mutation: command boundaries are stubbed, effects recorded locally.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log" AW_ROOT="$ROOT" DRY_RUN=0 AW_TEST=0
mkdir -p "$AW_STATE" "$AW_LOG_DIR"
source "$ROOT/lib/updates.sh"
source "$ROOT/commands/update.sh"
info() { :; }; log() { :; }; ok() { :; }; warn() { :; }; err() { :; }
die() { echo "$*" >&2; return 1; }
require_root() { :; }; cfg_require() { :; }; cfg_need() { :; }; aw_state_init() { :; }
cfg_bool() { return 1; }; ensure_dir() { mkdir -p "$1"; }
upd_lock() { echo lock >> "$TMP/events"; }
upd_agent_enabled() { return 0; }
upd_agent_upgrade() { echo agent >> "$TMP/events"; [[ "${FAIL_INSTALL:-0}" == 0 ]]; }
upd_health_gate() { echo health >> "$TMP/events"; [[ "${FAIL_HEALTH:-0}" == 0 ]]; }
pkg_upgrade() { echo packages >> "$TMP/events"; }
# Agent-only must lock, install, gate and report; never call package upgrade.
cmd_update --scope agent --rollout ro_test_1 --target-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
[[ "$(cat "$TMP/events")" == $'lock\nagent\nhealth' ]]
[[ "$(jq -r '.state + ":" + .rolloutId' "$AW_STATE/update-result.json")" == ok:ro_test_1 ]]
FAIL_HEALTH=1; export FAIL_HEALTH
if cmd_update --agent --rollout ro_test_2; then echo 'unhealthy update succeeded' >&2; exit 1; fi
[[ "$(jq -r '.state + ":" + .rolloutId' "$AW_STATE/update-result.json")" == failed:ro_test_2 ]]
unset FAIL_HEALTH
# Delivery uses an argv array, preserving scope/commit with no shell expansion.
have() { [[ "$1" == systemd-run ]]; }
systemd-run() { printf '%s\n' "$@" > "$TMP/argv"; }
upd_apply_from_delivery '{"update":{"rolloutId":"ro_delivery_1","scope":"agent","agentCommit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
grep -qx -- '--scope' "$TMP/argv"; grep -qx agent "$TMP/argv"
grep -qx -- '--target-commit' "$TMP/argv"
cp "$TMP/argv" "$TMP/first"
upd_apply_from_delivery '{"update":{"rolloutId":"ro_delivery_1","scope":"agent"}}'
cmp "$TMP/argv" "$TMP/first"
upd_apply_from_delivery '{"update":{"rolloutId":"ro_delivery_2","scope":"system"}}'
grep -qx system "$TMP/argv"
if upd_apply_from_delivery '{"update":{"rolloutId":"ro_bad","scope":"shell"}}'; then exit 1; fi
if upd_apply_from_delivery '{"update":{"rolloutId":"ro_bad","agentCommit":"../../x"}}'; then exit 1; fi
# A mismatch must fail before archive extraction or installer execution.
source "$ROOT/lib/updates.sh"
control_url() { echo https://control.test; }
curl() {
  local header="" output=""
  while [[ $# -gt 0 ]]; do case "$1" in -D) header="$2"; shift;; -o) output="$2"; shift;; esac; shift; done
  printf 'x-aw-agent-commit: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\r\n' > "$header"
  : > "$output"
}
tar() { echo 'unexpected archive extraction' >&2; exit 99; }
AW_UPDATE_TARGET_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if upd_agent_upgrade; then echo 'mismatched agent accepted' >&2; exit 1; fi
echo 'node update scope, health, delivery, retry and target checks passed'
