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

# Delivery signature verification: the helper builds a real Ed25519 control
# key, pins it, signs deliveries with openssl, and runs one scenario per
# invocation, exiting 0 when the agent behaves as expected.
cat > "$TMP/verify.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; OUT="$2"
export AW_ETC="$3" AW_STATE="$4" AW_TEST=1
SCENARIO="$5"
AW_ROOT="$ROOT"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"

mkdir -p "$AW_ETC" "$AW_STATE" "$OUT"
printf '{"deviceId":"dev_test","pollSecret":"s","controlUrl":"https://control.test"}' > "$AW_ETC/control.json"

openssl genpkey -algorithm ED25519 -out "$OUT/ctrl.pem" 2>/dev/null
openssl pkey -in "$OUT/ctrl.pem" -pubout -outform DER -out "$OUT/ctrl.der" 2>/dev/null
PUB_B64="$(base64 -w0 "$OUT/ctrl.der")"
KID="ck-$(sha256sum "$OUT/ctrl.der" | cut -c1-12)"
openssl genpkey -algorithm ED25519 -out "$OUT/evil.pem" 2>/dev/null
openssl pkey -in "$OUT/evil.pem" -pubout -outform DER -out "$OUT/evil.der" 2>/dev/null
EVIL_B64="$(base64 -w0 "$OUT/evil.der")"
EVIL_KID="ck-$(sha256sum "$OUT/evil.der" | cut -c1-12)"

control_pin_pubkey "$KID" "$PUB_B64" "test" >/dev/null 2>&1

# sign_delivery <device> <seq> <exp_ms> <bodyfile> <keypem> -> base64 sig
sign_delivery() {
  local h
  h="$(sha256sum "$4" | cut -d' ' -f1)"
  printf 'AW-DESIRED-V1\n%s\n%s\n%s\n%s' "$1" "$2" "$3" "$h" > "$OUT/canonical"
  openssl pkeyutl -sign -inkey "$5" -rawin -in "$OUT/canonical" 2>/dev/null | base64 -w0
}
make_hdr() { # <kid> <seq> <exp> <sig> <outfile>
  printf 'HTTP/1.1 200 OK\r\nx-aw-sig-kid: %s\r\nx-aw-sig-seq: %s\r\nx-aw-sig-exp: %s\r\nx-aw-sig: %s\r\n\r\n' \
    "$1" "$2" "$3" "$4" > "$5"
}
EXP="$(( $(date +%s%3N) + 240000 ))"
BODY="$OUT/body.json"
HDR="$OUT/hdr.txt"
printf '{"state":"approved","sequence":7,"config":{"configVersion":7,"profile":"worker"}}' > "$BODY"

case "$SCENARIO" in
  valid)
    SIG="$(sign_delivery dev_test 7 "$EXP" "$BODY" "$OUT/ctrl.pem")"
    make_hdr "$KID" 7 "$EXP" "$SIG" "$HDR"
    control_verify_delivery "$BODY" "$HDR" 2>/dev/null ;;
  tampered)
    SIG="$(sign_delivery dev_test 7 "$EXP" "$BODY" "$OUT/ctrl.pem")"
    make_hdr "$KID" 7 "$EXP" "$SIG" "$HDR"
    sed 's/worker/attacker/' "$BODY" > "$OUT/body2.json"
    ! control_verify_delivery "$OUT/body2.json" "$HDR" 2>/dev/null ;;
  wrong-kid)
    SIG="$(sign_delivery dev_test 7 "$EXP" "$BODY" "$OUT/ctrl.pem")"
    make_hdr "$EVIL_KID" 7 "$EXP" "$SIG" "$HDR"
    ! control_verify_delivery "$BODY" "$HDR" 2>/dev/null ;;
  wrong-sig)
    SIG="$(sign_delivery dev_test 7 "$EXP" "$BODY" "$OUT/evil.pem")"
    make_hdr "$KID" 7 "$EXP" "$SIG" "$HDR"
    ! control_verify_delivery "$BODY" "$HDR" 2>/dev/null ;;
  wrong-device)
    SIG="$(sign_delivery dev_other 7 "$EXP" "$BODY" "$OUT/ctrl.pem")"
    make_hdr "$KID" 7 "$EXP" "$SIG" "$HDR"
    ! control_verify_delivery "$BODY" "$HDR" 2>/dev/null ;;
  expired)
    SIG="$(sign_delivery dev_test 7 "$(( $(date +%s%3N) - 120000 ))" "$BODY" "$OUT/ctrl.pem")"
    make_hdr "$KID" 7 "$(( $(date +%s%3N) - 120000 ))" "$SIG" "$HDR"
    ! control_verify_delivery "$BODY" "$HDR" 2>/dev/null ;;
  missing-headers)
    printf 'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n' > "$HDR"
    ! control_verify_delivery "$BODY" "$HDR" 2>/dev/null ;;
  pin-mismatch)
    ! ( control_pin_pubkey "$EVIL_KID" "$EVIL_B64" "test" ) 2>/dev/null ;;
  apply-seq-mismatch)
    cfg_set_str() { :; }
    cfg_set_expr() { :; }
    sec_backend() { printf 'none\n'; }
    MISMATCH='{"state":"approved","sequence":8,"config":{"configVersion":7,"profile":"x"}}'
    ! ( control_apply_delivery "$MISMATCH" ) 2>/dev/null ;;
  wrapper-new|wrapper-stale|wrapper-rollback)
    # End-to-end through control_verified_delivery with a mocked transport.
    case "$SCENARIO" in
      wrapper-new)      APPLIED=5; SEQ=7; WANT_RC=0 ;;
      wrapper-stale)    APPLIED=7; SEQ=7; WANT_RC=3 ;;
      wrapper-rollback) APPLIED=7; SEQ=5; WANT_RC=1 ;;
    esac
    cfg_get() { printf '%s\n' "$APPLIED"; }
    control_sign() { printf 'sig'; }
    printf '{"state":"approved","sequence":%s,"config":{"configVersion":%s}}' "$SEQ" "$SEQ" > "$OUT/wbody.json"
    MOCK_SIG="$(sign_delivery dev_test "$SEQ" "$EXP" "$OUT/wbody.json" "$OUT/ctrl.pem")"
    MOCK_KID="$KID"; MOCK_SEQ="$SEQ"; MOCK_EXP="$EXP"; MOCK_BODY="$(cat "$OUT/wbody.json")"
    curl() {
      local df="" prev="" a
      for a in "$@"; do [[ "$prev" == "-D" ]] && df="$a"; prev="$a"; done
      make_hdr "$MOCK_KID" "$MOCK_SEQ" "$MOCK_EXP" "$MOCK_SIG" "$df"
      printf '%s' "$MOCK_BODY"
    }
    OUT_BODY="$(control_verified_delivery "/v1/device/desired?since=$APPLIED" 2>/dev/null)"
    RC=$?
    [[ "$RC" == "$WANT_RC" ]] || exit 1
    [[ "$WANT_RC" == "0" && "$OUT_BODY" == "$MOCK_BODY" ]] || [[ "$WANT_RC" != "0" ]]
    ;;
  *) printf 'unknown scenario: %s\n' "$SCENARIO" >&2; exit 2 ;;
esac
EOS
run_verify() { rm -rf "$TMP/vout" "$TMP/vetc" "$TMP/vstate"; bash "$TMP/verify.sh" "$ROOT" "$TMP/vout" "$TMP/vetc" "$TMP/vstate" "$1" > "$TMP/verify.out" 2>&1; }
echo "== delivery verification =="
check "verify accepts a valid delivery"      'run_verify valid'
check "verify rejects a tampered body"       'run_verify tampered'
check "verify rejects a wrong key id"        'run_verify wrong-kid'
check "verify rejects a foreign signature"   'run_verify wrong-sig'
check "verify rejects another device's delivery" 'run_verify wrong-device'
check "verify rejects an expired delivery"   'run_verify expired'
check "verify rejects missing headers"       'run_verify missing-headers'
check "pin refuses a mismatched key"         'run_verify pin-mismatch'
check "apply refuses version/sequence mismatch" 'run_verify apply-seq-mismatch'
check "wrapper accepts a newer delivery"     'run_verify wrapper-new'
check "wrapper ignores an already-applied delivery" 'run_verify wrapper-stale'
check "wrapper refuses a rollback"           'run_verify wrapper-rollback'


echo "== node lifecycle =="
check "decommission --help"            'run_aw decommission --help && has "tombstone"'
check "provision --help"               'run_aw provision --help && has "First-boot"'
check "enroll --help documents claim" 'run_aw enroll --help && has "pending claim"'
check "enroll --status is honest"      'run_aw enroll --status && has "not enrolled"'
check "provision unit Before agent"    'grep -q "Before=alwayswork-agent.service" "$ROOT/capabilities/control.join/install.sh"'
check "provision timer shipped"        'grep -q "alwayswork-provision.timer" "$ROOT/capabilities/control.join/install.sh"'
check "agent verifies the drain order"     'grep -q "control_maybe_drain" "$ROOT/lib/control.sh"'
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

echo
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
