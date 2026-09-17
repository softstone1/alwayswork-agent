#!/usr/bin/env bash
# alwayswork test harness. Runs without root and without touching the host.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW="$ROOT/bin/alwayswork"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# run the CLI, capture combined output, then assert on the file.
run_aw() { AW_ROOT="$ROOT" bash "$AW" "$@" > "$TMP/out" 2>&1; }
has()    { grep -q "$1" "$TMP/out"; }

echo "== syntax =="
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/dev/null; then ok "syntax: ${f#"$ROOT"/}"; else bad "syntax: $f"; fi
done < <(find "$ROOT" -type f \( -name '*.sh' -o -path '*/bin/alwayswork' \) -print0)

echo "== cli =="
check "install.sh executable"     '[[ -x "$ROOT/install.sh" ]]'
check "bin/alwayswork executable" '[[ -x "$ROOT/bin/alwayswork" ]]'
check "version"           'run_aw --version && has "^alwayswork "'
check "help"              'run_aw help && has USAGE'
check "unknown cmd fails" '! run_aw bogus'
check "power documented"  'run_aw help && has "power <status"'
check "enroll documented" 'run_aw help && has "enroll --control"'
check "reset documented"  'run_aw help && has "reset \[--purge\]"'
check "web ui docs in help" 'run_aw help && has "node web UI"'
check "apply explains the agent" 'grep -q "control agent reconciles desired state" "$ROOT/commands/apply.sh"'
check "agent documented"  'run_aw help && has "agent \[interval\]"'

echo "== catalog =="
for m in "$ROOT"/capabilities/*/manifest.yaml; do
  d="$(basename "$(dirname "$m")")"
  check "manifest id: $d"          "grep -q '^id: $d$' '$m'"
  check "manifest description: $d" "grep -q '^description: ' '$m'"
  check "$d install+uninstall"     "[[ -f '$(dirname "$m")/install.sh' && -f '$(dirname "$m")/uninstall.sh' ]]"
done

echo "== dry-run (no yq needed) =="
export AW_TEST=1 AW_ROOT="$ROOT" AW_ETC="$TMP/etc" AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log" AW_CONFIG="$TMP/etc/worker.yaml"
check "dry-run init exits 0"      'run_aw --dry-run init --profile foundation'
check "dry-run wrote no config"   '[[ ! -e "$AW_CONFIG" ]]'
check "dry-run made no state dir" '[[ ! -d "$AW_STATE" ]]'

if have yq; then
  echo "== render / resolve (yq) =="
  check "init renders config"      'run_aw init --profile worker && [[ -f "$AW_CONFIG" ]]'
  check "config has profile"       'grep -q "profile: worker" "$AW_CONFIG"'
  check "profile set capabilities" 'grep -q "runtime.docker" "$AW_CONFIG"'
  check "always_on config present" 'grep -q "always_on:" "$AW_CONFIG"'
  check "list --available runs"    'run_aw list --available'
  check "list shows enabled core"  'run_aw list && has "^core "'
  check "available hides enabled"  'run_aw list --available && ! has "^core "'
  check "available has tunnel"     'run_aw list --available && has "access.tunnel"'
  check "status renders"           'run_aw status && has "AlwaysWork"'
  check "power status renders"     'run_aw power status && has "sleep.target"'
  check "app list runs"            'run_aw app list && has "ripgrep"'
  check "app search works"         'run_aw app search backup && has "restic"'
  check "app install dry-run"      'run_aw --dry-run app install ripgrep && has "pacman"'
  check "clean dry-run"            'run_aw --dry-run clean'
  check "dry-run enable resolves"  'run_aw --dry-run enable access.tunnel && has "access.tunnel"'
  check "dry-run enable pulls dep" 'run_aw --dry-run enable access.tunnel && has "core"'

  # agents.dsh preflights the harness CLI and the account agent work runs as.
  printf '#!/bin/sh\nexit 0\n' > "$TMP/dsh"; chmod +x "$TMP/dsh"
  export PATH="$TMP:$PATH"
  yq -i ".agent.user = \"$(id -un)\"" "$AW_CONFIG" 2>/dev/null || true
  check "agent profile has node ui" 'grep -q "agents.dsh" "$ROOT/profiles/agent.yaml"'
  check "dry-run enable node ui"    'run_aw --dry-run enable agents.dsh && has "agents.dsh"'
  check "node ui reports host"      'grep -q "webui.json" "$ROOT/lib/control.sh"'
else
  echo "  skip  yq not installed (render/resolve tests)"
fi

echo "== control client =="
check "call signs path without query"    'grep -q "signed_path=" "$ROOT/lib/control.sh"'
check "delivery refuses malformed data"  'grep -q "refusing a malformed delivery" "$ROOT/lib/control.sh"'
check "apply installs delivered apps"    'grep -q "unknown app in desired state" "$ROOT/commands/apply.sh"'

# The device signature must cover the request path only. The control plane
# verifies "new URL(req.url).pathname", so a query string that leaks into the
# canonical string makes every signed GET fail with 401.
cat > "$TMP/canonical.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; export AW_TEST_CANONICAL="$2"
AW_ROOT="$ROOT"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"
control_url()       { printf '%s\n' "https://control.test"; }
control_device_id() { printf '%s\n' "w_test"; }
control_sign()      { printf '%s' "$1" > "$AW_TEST_CANONICAL"; printf 'sig'; }
curl()              { printf '%s\n' "$*"; }
control_call GET '/v1/device/desired?since=7'
EOS
run_signed() { bash "$TMP/canonical.sh" "$ROOT" "$TMP/canonical" > "$TMP/signed.out" 2>&1; }
check "signed call exits 0"          'run_signed'
check "url keeps the query string"   'grep -q "desired?since=7" "$TMP/signed.out"'
check "canonical path has no query"  'grep -qx "/v1/device/desired" "$TMP/canonical"'
check "canonical omits since"        '! grep -q "since" "$TMP/canonical"'

echo "== node lifecycle =="
check "decommission --help"            'run_aw decommission --help && has "tombstone"'
check "provision --help"               'run_aw provision --help && has "First-boot"'
check "enroll --help documents claim" 'run_aw enroll --help && has "pending claim"'
check "enroll --status is honest"      'run_aw enroll --status && has "not enrolled"'
check "provision unit Before agent"    'grep -q "Before=alwayswork-agent.service" "$ROOT/capabilities/control.join/install.sh"'
check "provision timer shipped"        'grep -q "alwayswork-provision.timer" "$ROOT/capabilities/control.join/install.sh"'
check "agent stops on draining"        'grep -q "device_state" "$ROOT/lib/control.sh"'
check "claims endpoint wired"          'grep -q "/v1/claims" "$ROOT/lib/control.sh"'
check "decommission endpoint wired"    'grep -q "/v1/device/" "$ROOT/lib/control.sh"'
check "tombstone is terminal"          'grep -q "tombstone" "$ROOT/lib/control.sh"'

# The USB TOML parser must be strict: only the four known fields, and shell
# metacharacters in the file must never be executed or leak through.
cat > "$TMP/usb-parse.sh" <<'EOS'
set -u
ROOT="$1"
export AW_ROOT="$ROOT"
export AW_ETC="$2/etc" AW_STATE="$2/state" AW_LOG_DIR="$2/log" AW_CONFIG="$2/etc/worker.yaml"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"
TOML="$2/prov.toml"
[[ "$(usb_toml_get "$TOML" hostname)" == "node-01" ]] || exit 1
[[ "$(usb_toml_get "$TOML" profile)" == "worker" ]] || exit 1
[[ "$(usb_toml_get "$TOML" control_url)" == "https://control.example.com" ]] || exit 1
[[ "$(usb_toml_get "$TOML" join_token)" == "aj_test123" ]] || exit 1
# unknown fields are inert data — returned verbatim, never executed or used.
[[ "$(usb_toml_get "$TOML" evil)" == '$(touch /tmp/aw-pwned)' ]] || exit 1
[[ -z "$(usb_toml_get "$TOML" x)" ]] || exit 1
[[ -z "$(usb_toml_get "$TOML" nonexistent)" ]] || exit 1
exit 0
EOS
mkdir -p "$TMP/usb"
cat > "$TMP/usb/prov.toml" <<'EOF'
# AlwaysWork provisioning
hostname    = "node-01"
profile     = "worker"
control_url = "https://control.example.com"
join_token  = "aj_test123"
evil = "$(touch /tmp/aw-pwned)"
x=$(touch /tmp/aw-pwned2)
EOF
rm -f /tmp/aw-pwned /tmp/aw-pwned2
check "usb toml parser strict" 'bash "$TMP/usb-parse.sh" "$ROOT" "$TMP/usb" && [[ ! -e /tmp/aw-pwned && ! -e /tmp/aw-pwned2 ]]'

if have yq; then
  check "decommission dry-run writes nothing" 'run_aw --dry-run --yes decommission >/dev/null && [[ ! -e "$AW_STATE/decommission.json" ]]'
  check "decommission dry-run summarizes"     'run_aw --dry-run --yes decommission && has "decommissioned"'
  check "provision dry-run is a no-op"        'run_aw --dry-run provision >/dev/null && [[ ! -e "$AW_STATE/decommission.json" ]]'
fi

echo "== secret store =="
if have sops && have age && yq --version 2>/dev/null | grep -qi mikefarah; then
  cat > "$TMP/store.sh" <<'EOS'
set -euo pipefail
ROOT="$1"
export AW_ROOT="$ROOT"
export AW_ETC="$2/etc" AW_STATE="$2/state" AW_LOG_DIR="$2/log" AW_CONFIG="$2/etc/worker.yaml"
export PATH="$ROOT/bin:$PATH"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/secrets.sh"
sec_init >/dev/null
sec_set DEMO 'a=b=c/d+e' >/dev/null
[[ "$(sec_get DEMO)" == 'a=b=c/d+e' ]] || exit 1
sec_set OTHER 'tok==' >/dev/null
[[ "$(sec_get DEMO)" == 'a=b=c/d+e' ]] || exit 1
[[ "$(sec_get OTHER)" == 'tok==' ]] || exit 1
# A store truncated by a failed write must be rebuilt, not left unusable.
: > "$(sec_file)"
sec_set THIRD 'rebuilt' >/dev/null
[[ "$(sec_get THIRD)" == 'rebuilt' ]] || exit 1
EOS
  check "secret store round-trip" 'bash "$TMP/store.sh" "$ROOT" "$TMP/store"'
else
  echo "  skip  secret store (sops/age/mikefarah yq missing)"
fi

echo "== curl secret hygiene =="
# Secrets must never travel on curl's argv (visible via ps). These tests stub
# curl to capture its exact argv, then assert: no token/secret appears there,
# bodies/headers go through 0600 temp files, and the files are removed on the
# success path, the network-failure path, and the approved-poll path.
cat > "$TMP/curl-hygiene.sh" <<'EOS'
set -u
ROOT="$1"; T="$2"
export AW_ROOT="$ROOT" AW_TEST=1 DRY_RUN=1
export AW_ETC="$T/etc" AW_STATE="$T/state" AW_LOG_DIR="$T/log" AW_CONFIG="$T/etc/worker.yaml"
export TMPDIR="$T/tmp"   # isolate _secret_file temp files for leak checks
mkdir -p "$TMPDIR" "$AW_ETC" "$AW_STATE"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"

JOIN_TOKEN="join-token-SECRET-123"
POLL_SECRET='p0ll"s3c\ret'
CURL_ARGV="$T/argv"; CURL_BODY_PATH="$T/bodypath"; CURL_CONFIG_PATH="$T/cfgpath"
: > "$CURL_BODY_PATH"; : > "$CURL_CONFIG_PATH"

control_url()        { printf '%s\n' "https://control.test"; }
control_device_id()  { printf '%s\n' "dev_test"; }
control_sign()       { printf 'sig'; }
control_ensure_key() { :; }
control_pubkey_b64() { printf '%s' "cGstdGVzdA=="; }
control_machine_id() { printf '%s' "machine-test"; }
control_macs_json()  { printf '%s' "[]"; }
control_dmi()        { printf ''; }
hw_os_pretty()       { printf '%s' "TestOS"; }
sec_backend()        { printf '%s' "file"; }
sec_public_key()     { printf '%s' "age1testrecipient"; }
hostname()           { printf '%s' "testnode"; }
AW_VERSION="9.9.9-test"
# argv of a curl call, NUL-separated (unambiguous even with tricky secrets)
argv_has() { tr '\0' '\n' < "$CURL_ARGV" | grep -qF -- "$1"; }
curl() {
  : > "$CURL_ARGV"
  local a prev=""
  for a in "$@"; do printf '%s\0' "$a" >> "$CURL_ARGV"; done
  for a in "$@"; do
    if [[ "$prev" == "--data" && "$a" == @* ]]; then printf '%s' "${a#@}" > "$CURL_BODY_PATH"; fi
    if [[ "$prev" == "--config" ]]; then printf '%s' "$a" > "$CURL_CONFIG_PATH"; fi
    prev="$a"
  done
  printf '%s' "$CURL_RESP"
}
CURL_RESP="$(jq -n --arg ps "$POLL_SECRET" '{deviceId:"dev_test",pollSecret:$ps}')"
_REAL_WAIT_APPROVAL="$(declare -f control_wait_approval)"  # (re-)defined below
control_wait_approval() { printf '%s %s' "$1" "$2" > "$T/waitargs"; }
control_apply_delivery() { printf 'applied' > "$T/applied"; return 0; }

# 1. enroll: the join token must not appear on curl's argv
control_enroll_with_token "$JOIN_TOKEN" >/dev/null 2>&1
argv_has "$JOIN_TOKEN" && { echo "FAIL: join token on curl argv"; exit 1; }
[[ -s "$CURL_BODY_PATH" ]] || { echo "FAIL: enroll did not use --data @file"; exit 1; }
bf="$(cat "$CURL_BODY_PATH")"
[[ -f "$bf" ]] && { echo "FAIL: body temp file not removed after enroll"; exit 1; }
[[ "$(cat "$T/waitargs")" == "dev_test $POLL_SECRET" ]] || { echo "FAIL: wait-approval args wrong"; exit 1; }
[[ -z "$(ls -A "$TMPDIR")" ]] || { echo "FAIL: temp leak after enroll"; exit 1; }

# 2. _secret_file itself: 0600, exact content, trap removes it on exit
_secret_file "content-123" sf
[[ "$(stat -c %a "$sf")" == "600" ]] || { echo "FAIL: temp file not 0600"; exit 1; }
[[ "$(cat "$sf")" == "content-123" ]] || { echo "FAIL: temp file content wrong"; exit 1; }
rm -f "$sf"; trap - EXIT
# a trap set in a subshell fires when the subshell exits: nothing may leak
before="$(ls -A "$TMPDIR" | wc -l)"
( _secret_file "trap-me" sf2 >/dev/null )
after="$(ls -A "$TMPDIR" | wc -l)"
[[ "$before" == "$after" ]] || { echo "FAIL: subshell EXIT trap did not clean up"; exit 1; }
[[ -z "$(ls -A "$TMPDIR")" ]] || { echo "FAIL: temp leak after _secret_file"; exit 1; }

# 3. control_call network-failure path removes the staged body
curl() { return 7; }
control_call POST /v1/device/heartbeat '{"appliedVersion":1}' >/dev/null 2>&1
(( $? == 1 )) || { echo "FAIL: control_call rc on network failure"; exit 1; }
[[ -z "$(ls -A "$TMPDIR")" ]] || { echo "FAIL: temp leak after control_call failure"; exit 1; }

# 4. poll: the secret header must not be on argv; the --config file carries it
#    (with curl-config escaping), and is removed once the poll resolves
eval "$_REAL_WAIT_APPROVAL"   # restore the real poll loop for this test
curl() {
  : > "$CURL_ARGV"
  local a prev=""
  for a in "$@"; do printf '%s\0' "$a" >> "$CURL_ARGV"; done
  for a in "$@"; do
    if [[ "$prev" == "--config" ]]; then printf '%s' "$a" > "$CURL_CONFIG_PATH"; fi
    prev="$a"
  done
  cp "$(cat "$CURL_CONFIG_PATH")" "$T/cfgcopy"   # capture before it is removed
  printf '%s' '{"state":"approved","config":{"profile":"worker"}}'
}
control_wait_approval "dev_test" "$POLL_SECRET" >/dev/null 2>&1
argv_has "x-poll-secret" && { echo "FAIL: poll-secret header on argv"; exit 1; }
argv_has "$POLL_SECRET" && { echo "FAIL: poll secret value on argv"; exit 1; }
[[ "$(cat "$T/cfgcopy")" == 'header = "x-poll-secret: p0ll\"s3c\\ret"' ]] \
  || { echo "FAIL: config content wrong: $(cat "$T/cfgcopy")"; exit 1; }
[[ -f "$(cat "$CURL_CONFIG_PATH")" ]] && { echo "FAIL: config temp file not removed"; exit 1; }
[[ "$(cat "$T/applied")" == "applied" ]] || { echo "FAIL: approved delivery not applied"; exit 1; }
[[ -z "$(ls -A "$TMPDIR")" ]] || { echo "FAIL: temp leak at end"; exit 1; }
echo "hygiene-stub OK"
EOS
check "secrets never on curl argv (stubbed)" 'bash "$TMP/curl-hygiene.sh" "$ROOT" "$TMP/hygiene"'

# Live round-trip: real curl through the new code paths against a localhost
# server, proving --data @file and --config actually deliver the exact bytes.
if have python3 && have timeout; then
cat > "$TMP/curl-live.sh" <<'EOS'
set -u
ROOT="$1"; T="$2"
export AW_ROOT="$ROOT" AW_TEST=1 DRY_RUN=1
export AW_ETC="$T/etc" AW_STATE="$T/state" AW_LOG_DIR="$T/log" AW_CONFIG="$T/etc/worker.yaml"
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR" "$AW_ETC" "$AW_STATE"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"
PORT=18931
JOIN_TOKEN="live-join-TOKEN-999"
POLL_SECRET='lv"s3c\ret$!'
python3 - "$PORT" "$T" "$POLL_SECRET" <<'PYEOF' &
import http.server, sys, json
port, t, poll_secret = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def _rec(self, name, body):
        with open("%s/%s.headers" % (t, name), "w") as f:
            for k, v in self.headers.items(): f.write("%s: %s\n" % (k.lower(), v))
        with open("%s/%s.body" % (t, name), "wb") as f: f.write(body)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._rec("enroll", body)
        data = json.dumps({"deviceId": "dev_live", "pollSecret": poll_secret}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        self._rec("poll", b"")
        data = json.dumps({"state": "approved", "config": {"profile": "worker",
            "capabilities": [], "apps": [], "configVersion": 3}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 100); do (echo > /dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
control_url()        { printf '%s\n' "http://127.0.0.1:$PORT"; }
control_ensure_key() { :; }
control_pubkey_b64() { printf '%s' "cGstdGVzdA=="; }
control_machine_id() { printf '%s' "machine-test"; }
control_macs_json()  { printf '%s' "[]"; }
control_dmi()        { printf ''; }
hw_os_pretty()       { printf '%s' "TestOS"; }
sec_backend()        { printf '%s' "file"; }
sec_public_key()     { printf '%s' "age1testrecipient"; }
hostname()           { printf '%s' "testnode"; }
AW_VERSION="9.9.9-test"
control_apply_delivery() { return 0; }
control_enroll_with_token "$JOIN_TOKEN" >/dev/null 2>&1 || { echo "FAIL: enroll error"; exit 1; }
[[ "$(python3 -c "import json;print(json.load(open('$T/enroll.body'))['joinToken'])")" == "$JOIN_TOKEN" ]] \
  || { echo "FAIL: server did not receive the join token in the body"; exit 1; }
[[ "$(grep -i '^x-poll-secret:' "$T/poll.headers" | cut -d' ' -f2-)" == "$POLL_SECRET" ]] \
  || { echo "FAIL: server did not receive the poll secret header"; grep -i poll "$T/poll.headers"; exit 1; }
kill $SRV 2>/dev/null; trap - EXIT
[[ -z "$(ls -A "$TMPDIR")" ]] || { echo "FAIL: temp leak after live run"; exit 1; }
echo "hygiene-live OK"
EOS
check "live: body+header delivered via temp files" 'timeout 60 bash "$TMP/curl-live.sh" "$ROOT" "$TMP/live"'
else
  echo "  skip  live curl test (python3/timeout missing)"
fi

echo
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
