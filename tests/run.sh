#!/usr/bin/env bash
# alwayswork test harness. Runs without root and without touching the host.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW="$ROOT/bin/alwayswork"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The CLI is distro-aware: pin an Arch-family os-release for the suite so the
# legacy dry-run assertions (which expect pacman output) stay deterministic
# on any host. The == distro == section below covers the full family matrix
# with per-probe overrides.
mkdir -p "$TMP/os"
printf 'ID=cachyos\nID_LIKE=arch\nPRETTY_NAME="CachyOS Linux"\n' > "$TMP/os/arch"
export AW_OS_RELEASE="$TMP/os/arch"

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

# The stick layout the console generates (alwayswork/provision.toml) is found
# first; the legacy top-level alwayswork.toml still works. Only already-
# mounted locations are scanned in a dry run (no block devices touched).
cat > "$TMP/usb-find.sh" <<'EOS'
set -u
ROOT="$1"; VOL="$2"
export AW_ROOT="$ROOT" AW_ETC="$3/etc" AW_STATE="$3/state" AW_LOG_DIR="$3/log" AW_CONFIG="$3/etc/worker.yaml"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"
DRY_RUN=1
_usb_toml_in "$VOL"
EOS
mkdir -p "$TMP/vol1/alwayswork" "$TMP/vol2"
printf 'join_token = "aj_x"\n' > "$TMP/vol1/alwayswork/provision.toml"
printf 'join_token = "aj_legacy"\n' > "$TMP/vol1/alwayswork.toml"
printf 'join_token = "aj_legacy"\n' > "$TMP/vol2/alwayswork.toml"
check "usb finder prefers alwayswork/provision.toml" '[[ "$(bash "$TMP/usb-find.sh" "$ROOT" "$TMP/vol1" "$TMP/usb")" == "$TMP/vol1/alwayswork/provision.toml" ]]'
check "usb finder still accepts alwayswork.toml"     '[[ "$(bash "$TMP/usb-find.sh" "$ROOT" "$TMP/vol2" "$TMP/usb")" == "$TMP/vol2/alwayswork.toml" ]]'
check "usb finder ignores an empty volume"          '! bash "$TMP/usb-find.sh" "$ROOT" "$TMP/usb" "$TMP/usb" >/dev/null'
check "control.join installs the USB hotplug rule"  'grep -q "90-alwayswork-provision.rules" "$ROOT/capabilities/control.join/install.sh" && grep -q "SYSTEMD_WANTS.*alwayswork-provision.service" "$ROOT/capabilities/control.join/install.sh"'
check "control.join uninstall removes timer + rule"  'grep -q "alwayswork-provision.timer" "$ROOT/capabilities/control.join/uninstall.sh" && grep -q "90-alwayswork-provision.rules" "$ROOT/capabilities/control.join/uninstall.sh"'

# Pending token enrolment: the flag on disk, the agent's clean exit, and the
# single place enrolment finishes.
cat > "$TMP/pending.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"
DRY_RUN=0
mkdir -p "$AW_ETC"
printf '{"deviceId":"w_1","pollSecret":"ps_1","controlUrl":"https://c","pending":true}' > "$AW_ETC/control.json"
control_enrolled || exit 1
control_pending || exit 2
control_set_pending false || exit 3
control_pending && exit 4
[[ "$(jq -r .deviceId "$AW_ETC/control.json")" == "w_1" ]] || exit 5
exit 0
EOS
check "pending enrolment flag round-trips" 'bash "$TMP/pending.sh" "$ROOT" "$TMP/pend"'
check "agent exits cleanly while pending"  'grep -q "control_pending" "$ROOT/lib/control.sh" && grep -B1 -A3 "still pending approval" "$ROOT/lib/control.sh" | grep -q "return 0"'
check "every enrol path finishes in one place" '[[ "$(grep -c "control_finish_enrolled" "$ROOT/lib/control.sh")" -ge 3 ]] && grep -q "control_enroll_resume_once" "$ROOT/commands/provision.sh"'
check "bounded approval wait is documented"    'grep -q "AW_ENROLL_WAIT" "$ROOT/lib/control.sh" && grep -q "AW_ENROLL_WAIT" "$ROOT/install.sh"'

if have yq; then
  check "decommission dry-run writes nothing" 'run_aw --dry-run --yes decommission >/dev/null && [[ ! -e "$AW_STATE/decommission.json" ]]'
  check "decommission dry-run summarizes"     'run_aw --dry-run --yes decommission && has "decommissioned"'
  check "provision dry-run is a no-op"        'run_aw --dry-run provision >/dev/null && [[ ! -e "$AW_STATE/decommission.json" ]]'
fi

echo "== ledger =="
# The footprint ledger (docs/DECOMMISSION.md): recorders capture prior
# state, restore replays in reverse. Exercised in a scratch state dir with
# stubbed package/systemd helpers; anything that would touch the host runs
# under --dry-run and is asserted on its printed plan.
cat > "$TMP/ledger-probe.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; OUT="$2"; SCENARIO="$3"
export AW_ROOT="$ROOT" AW_TEST=1 AW_ETC="$OUT/etc" AW_STATE="$OUT/state" AW_LOG_DIR="$OUT/log"
export AW_OS_RELEASE="$4"
export NO_COLOR=1
source "$ROOT/lib/core.sh"
source "$ROOT/lib/distro.sh"
source "$ROOT/lib/ledger.sh"
source "$ROOT/lib/firewall.sh"
mkdir -p "$OUT" "$AW_STATE"
L="$AW_STATE/ledger.jsonl"
synthetic() {
  cat > "$L" <<'EOL'
{"t":1,"by":"install","kind":"pkg","name":"jq","priorInstalled":false}
{"t":1,"by":"install","kind":"pkg","name":"ufw","priorInstalled":false}
{"t":1,"by":"install","kind":"pkg","name":"git","priorInstalled":true}
{"t":1,"by":"install","kind":"dir","path":"/opt/alwayswork","existed":false}
{"t":2,"by":"bootstrap","kind":"firewall","backend":"ufw","priorActive":false,"priorRules":"abc"}
{"t":2,"by":"bootstrap","kind":"ssh","unit":"sshd","priorEnabled":true,"priorActive":true,"dropins":"/etc/ssh/sshd_config.d/*alwayswork*.conf"}
{"t":3,"by":"agents.dsh","kind":"file","path":"/etc/systemd/system/alwayswork-webui.service","existed":false}
{"t":3,"by":"agents.dsh","kind":"unit","name":"alwayswork-webui.service","existed":false,"priorEnabled":false,"priorActive":false}
{"t":3,"by":"control.join","kind":"service","name":"sshd","priorEnabled":true,"priorActive":false}
{"t":4,"by":"provision","kind":"hostname","prior":"ubuntu"}
EOL
}
case "$SCENARIO" in
  record)
    AW_LEDGER_BY=test
    ledger_record pkg "name=ufw" "priorInstalled:=false" || exit 1
    ledger_record file "path=/etc/x y" "existed:=true" "sha=abc" || exit 1
    [[ "$(wc -l < "$L")" == "2" ]] || exit 1
    jq -e . "$L" >/dev/null || exit 1
    [[ "$(sed -n 1p "$L" | jq -r '.by + " " + .kind + " " + .name + " " + (.priorInstalled|tostring) + " " + (.t|type)')" == "test pkg ufw false number" ]] || exit 1
    [[ "$(sed -n 2p "$L" | jq -r '.path')" == "/etc/x y" ]] || exit 1
    ! ledger_record pkg "bad key=1" 2>/dev/null || exit 1
    ;;
  record-dry)
    DRY_RUN=1 ledger_record pkg "name=ufw" "priorInstalled:=false" 2>"$OUT/dry" || exit 1
    [[ ! -e "$L" ]] || exit 1
    grep -q "\[dry-run\] ledger pkg name=ufw" "$OUT/dry" || exit 1
    ;;
  file-before)
    printf 'original\n' > "$OUT/conf"
    ledger_file_before "$OUT/conf" || exit 1
    ledger_file_before "$OUT/missing" || exit 1
    sha="$(sha256sum "$OUT/conf" | cut -d' ' -f1)"
    [[ "$(sed -n 1p "$L" | jq -r '.kind + " " + (.existed|tostring) + " " + .sha')" == "file true $sha" ]] || exit 1
    [[ "$(cat "$AW_STATE/ledger.d/$sha")" == "original" ]] || exit 1
    [[ "$(sed -n 2p "$L" | jq -r '(.existed|tostring)')" == "false" ]] || exit 1
    # idempotent: the same path is never recorded twice (the first entry wins)
    printf 'changed\n' > "$OUT/conf"
    ledger_file_before "$OUT/conf" || exit 1
    [[ "$(wc -l < "$L")" == "2" ]] || exit 1
    ;;
  pkg-before)
    pkg_is_installed() { [[ "$1" == "git" ]]; }
    ledger_pkg_before git ufw || exit 1
    ledger_pkg_before ufw || exit 1
    [[ "$(jq -r 'select(.name=="git") | .priorInstalled' "$L")" == "true" ]] || exit 1
    [[ "$(jq -r 'select(.name=="ufw") | .priorInstalled' "$L")" == "false" ]] || exit 1
    [[ "$(wc -l < "$L")" == "2" ]] || exit 1
    ;;
  unit-before)
    ledger_unit alwayswork-x.service || exit 1
    ledger_unit alwayswork-x.service || exit 1
    [[ "$(jq -r '.kind + " " + .name + " " + (.existed|tostring)' "$L")" == "unit alwayswork-x.service false" ]] || exit 1
    ;;
  restore-dry)
    synthetic
    DRY_RUN=1 ledger_restore 2>"$OUT/plan" || exit 1
    [[ "$(wc -l < "$L")" == "10" ]] || exit 1           # unchanged
    [[ ! -e "$AW_STATE/decommission.json" ]] || exit 1   # nothing marked
    ;;
  restore-keep)
    synthetic
    DRY_RUN=1 ledger_restore --keep-foundation 2>"$OUT/plan" || exit 1
    ;;
  restore-real)
    # Only kinds that never touch systemd/hostname: file and dir, for real.
    mkdir -p "$OUT/root/created" "$OUT/root/kept"
    printf 'ours\n' > "$OUT/root/new.conf"
    printf 'ours\n' > "$OUT/root/replaced.conf"
    printf 'theirs\n' > "$OUT/prior"
    sha="$(sha256sum "$OUT/prior" | cut -d' ' -f1)"
    mkdir -p "$AW_STATE/ledger.d"; cp "$OUT/prior" "$AW_STATE/ledger.d/$sha"
    jq -cn --arg p "$OUT/root/kept" '{t:1,by:"install",kind:"dir",path:$p,existed:true}' > "$L"
    jq -cn --arg p "$OUT/root/created" '{t:1,by:"install",kind:"dir",path:$p,existed:false}' >> "$L"
    jq -cn --arg p "$OUT/root/replaced.conf" --arg s "$sha" '{t:2,by:"core",kind:"file",path:$p,existed:true,sha:$s}' >> "$L"
    jq -cn --arg p "$OUT/root/lost.conf" '{t:2,by:"core",kind:"file",path:$p,existed:true,sha:"0000"}' >> "$L"
    jq -cn --arg p "$OUT/root/new.conf" '{t:3,by:"core",kind:"file",path:$p,existed:false}' >> "$L"
    printf 'ours\n' > "$OUT/root/lost.conf"
    ledger_restore 2>"$OUT/real"; rc=$?
    [[ "$rc" != "0" ]] || exit 1                                   # one entry (no copy) failed
    [[ ! -e "$OUT/root/new.conf" ]] || exit 1                      # deleted
    [[ "$(cat "$OUT/root/replaced.conf")" == "theirs" ]] || exit 1 # prior content back
    [[ -f "$OUT/root/lost.conf" ]] || exit 1                       # never deleted
    [[ ! -d "$OUT/root/created" ]] || exit 1                       # our empty dir removed
    [[ -d "$OUT/root/kept" ]] || exit 1                            # pre-existing dir kept
    [[ "$(jq -c '.restored' "$AW_STATE/decommission.json")" == "[1,2,3,5]" ]] || exit 1
    # re-run: only the failed entry is attempted again
    ledger_restore 2>"$OUT/again"; [[ "$?" != "0" ]] || exit 1
    grep -q "1 failed" "$OUT/again" || exit 1
    grep -q "4 already done" "$OUT/again" || exit 1
    ;;
  self-remove)
    marker="$OUT/marker"; touch "$marker"
    ! ledger_self_remove 2>"$OUT/self" || exit 1
    [[ -e "$marker" && -d "$ROOT/lib" ]] || exit 1
    grep -q "refusing" "$OUT/self" || exit 1
    AW_TEST=0
    ! ledger_self_remove 2>"$OUT/self2" || exit 1                  # not under /opt: still refused
    grep -q "not under /opt" "$OUT/self2" || exit 1
    ;;
  self-remove-dry)
    DRY_RUN=1 ledger_self_remove 2>"$OUT/self" || exit 1
    grep -q "rm -rf $ROOT $AW_ETC $AW_LOG_DIR $AW_STATE" "$OUT/self" || exit 1
    [[ -d "$ROOT/lib" ]] || exit 1
    ;;
  *) printf 'unknown scenario: %s\n' "$SCENARIO" >&2; exit 2 ;;
esac
EOS
run_ledger() { rm -rf "$TMP/lout"; mkdir -p "$TMP/lout"; bash "$TMP/ledger-probe.sh" "$ROOT" "$TMP/lout" "$1" "$TMP/os/arch" > "$TMP/ledger.out" 2>&1; }
plan() { grep -n "$1" "$TMP/lout/plan" | head -1 | cut -d: -f1; }
check "ledger_record writes valid JSON lines"     'run_ledger record'
check "ledger_record honours dry-run"             'run_ledger record-dry'
check "ledger_file_before keeps a copy, once"     'run_ledger file-before'
check "ledger_pkg_before marks priorInstalled"    'run_ledger pkg-before'
check "ledger_unit records once"                  'run_ledger unit-before'
check "dry-run restore changes nothing"           'run_ledger restore-dry'
check "dry-run restore plans in reverse order"    '[[ "$(plan "restore #10 hostname")" -lt "$(plan "restore #8 unit")" && "$(plan "restore #8 unit")" -lt "$(plan "restore #7 file")" && "$(plan "restore #7 file")" -lt "$(plan "restore #5 firewall")" && "$(plan "restore #5 firewall")" -lt "$(plan "restore #2 pkg")" ]]'
check "dry-run restore undoes each kind"          'grep -q "hostnamectl set-hostname ubuntu" "$TMP/lout/plan" && grep -q "systemctl disable --now alwayswork-webui.service" "$TMP/lout/plan" && grep -q "rm -f /etc/systemd/system/alwayswork-webui.service" "$TMP/lout/plan" && grep -q "ufw --force disable" "$TMP/lout/plan" && grep -q "pacman -Rns --noconfirm ufw" "$TMP/lout/plan" && grep -q "systemctl restart sshd" "$TMP/lout/plan"'
check "restore keeps a package that was there"    'grep -q "git was already installed; kept" "$TMP/lout/plan" && ! grep -q "pacman -Rns --noconfirm git" "$TMP/lout/plan"'
check "restore removes jq last"                   '[[ "$(plan "restore #1 pkg: remove jq")" -gt "$(plan "restore #2 pkg")" ]]'
check "--keep-foundation skips firewall and ssh"  'run_ledger restore-keep && grep -q "restore #5 firewall: kept" "$TMP/lout/plan" && grep -q "restore #6 ssh: kept" "$TMP/lout/plan" && ! grep -q "ufw --force" "$TMP/lout/plan" && ! grep -q "systemctl.*sshd" "$TMP/lout/plan"'
check "--keep-foundation keeps the installer's footprint" 'grep -q "restore #2 pkg: kept (foundation, by install)" "$TMP/lout/plan" && ! grep -q "pacman -Rns" "$TMP/lout/plan" && grep -q "hostnamectl set-hostname ubuntu" "$TMP/lout/plan"'
check "real restore: files back, failures loud, resumable" 'run_ledger restore-real'
check "self-remove refuses under AW_TEST / outside /opt" 'run_ledger self-remove'
check "self-remove dry-run only prints the plan" 'run_ledger self-remove-dry'
check "decommission --help documents restore flags" 'run_aw decommission --help && has "keep-foundation" && has "keep-agent" && has "restore"'
check "help documents the restore flags"          'run_aw help && has "keep-foundation"'
check "drain order restore:false keeps the agent" 'grep -q "\.restore == false" "$ROOT/lib/control.sh" && grep -q "decommission_run 0 \"\$mode\"" "$ROOT/lib/control.sh"'
check "restore runs between wipe and report"      'grep -A4 "decommission_phase_wipe || return 1" "$ROOT/lib/control.sh" | grep -q "decommission_phase_restore"'
check "ledger lib is sourced by the cli"          'grep -q "lib/ledger.sh" "$ROOT/bin/alwayswork"'
check "aw_write records the prior file"           'grep -q "ledger_file_before" "$ROOT/lib/core.sh" && grep -q "ledger_unit" "$ROOT/lib/core.sh"'
check "pkg_install records prior packages"        'grep -q "ledger_pkg_before" "$ROOT/lib/distro.sh"'
check "cap_install attributes entries to the cap" 'grep -q "AW_LEDGER_BY=\"\$id\"" "$ROOT/lib/capability.sh"'
check "bootstrap records firewall and ssh first"  'grep -q "ledger_firewall_before" "$ROOT/commands/bootstrap.sh" && grep -q "ledger_ssh_before" "$ROOT/commands/bootstrap.sh"'
check "usb provisioning records the hostname"     'grep -B1 "run hostnamectl set-hostname" "$ROOT/lib/control.sh" | grep -q "ledger_hostname_before"'
if have yq; then
  # End to end, dry-run, against a seeded ledger: the CLI plans the reverse
  # replay, removes itself last, and writes nothing.
  mkdir -p "$AW_STATE"
  printf '%s\n' '{"t":1,"by":"install","kind":"pkg","name":"ufw","priorInstalled":false}' \
    '{"t":2,"by":"bootstrap","kind":"hostname","prior":"pristine"}' > "$AW_STATE/ledger.jsonl"
  check "decommission dry-run replays the ledger"   'run_aw --dry-run --yes decommission && has "restore #2 hostname: pristine" && has "restore #1 pkg: remove ufw" && has "removing alwayswork itself" && [[ ! -e "$AW_STATE/decommission.json" && -f "$AW_STATE/ledger.jsonl" ]]'
  check "decommission --keep-foundation keeps install entries" 'run_aw --dry-run --yes decommission --keep-foundation && has "restore #1 pkg: kept" && ! has "removing alwayswork itself" && has "kept the hardened base"'
  check "decommission --keep-agent skips restore" 'run_aw --dry-run --yes decommission --keep-agent && ! has "restore #" && has "keep-agent"'
  rm -f "$AW_STATE/ledger.jsonl"
fi

echo "== distro =="

# Mock os-release files for the family matrix ($TMP/os/arch is the suite-wide
# Arch pin created at the top of this file).
printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n'                             > "$TMP/os/fam-arch"
printf 'ID=endeavouros\nID_LIKE=arch\nPRETTY_NAME="EndeavourOS"\n'        > "$TMP/os/fam-endeavouros"
printf 'ID=garuda-linux\nID_LIKE=arch\nPRETTY_NAME="Garuda Linux"\n'     > "$TMP/os/fam-garuda"
printf 'ID=debian\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'       > "$TMP/os/fam-debian"
printf 'ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 24.04 LTS"\n'     > "$TMP/os/fam-ubuntu"
printf 'ID=kali\nID_LIKE=debian\nPRETTY_NAME="Kali GNU/Linux"\n'         > "$TMP/os/fam-kali"
printf 'ID=pop\nID_LIKE="ubuntu debian"\nPRETTY_NAME="Pop!_OS 22.04"\n'  > "$TMP/os/fam-pop"
printf 'ID=fedora\nPRETTY_NAME="Fedora Linux 42"\n'                     > "$TMP/os/fam-fedora"
printf 'PRETTY_NAME="Mystery OS"\n'                                     > "$TMP/os/fam-noid"

# Probe: source core+distro with a mocked os-release, then run one function.
cat > "$TMP/distro-probe.sh" <<'EOS'
set -u
ROOT="$1"; shift
export AW_OS_RELEASE="$1"; shift
export AW_ROOT="$ROOT"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/distro.sh"
"$@"
EOS
probe() { bash "$TMP/distro-probe.sh" "$ROOT" "$TMP/os/$1" "${@:2}"; }

check "cli sources distro lib" 'grep -q "lib/distro.sh" "$ROOT/bin/alwayswork"'
check "detect arch"            '[ "$(probe fam-arch distro_family)" == "arch" ]'
check "detect cachyos"         '[ "$(probe arch distro_family)" == "arch" ]'
check "detect endeavouros"     '[ "$(probe fam-endeavouros distro_family)" == "arch" ]'
check "detect garuda via ID_LIKE" '[ "$(probe fam-garuda distro_family)" == "arch" ]'
check "detect debian"          '[ "$(probe fam-debian distro_family)" == "debian" ]'
check "detect ubuntu"          '[ "$(probe fam-ubuntu distro_family)" == "debian" ]'
check "detect kali"            '[ "$(probe fam-kali distro_family)" == "debian" ]'
check "detect pop"             '[ "$(probe fam-pop distro_family)" == "debian" ]'
check "detect fedora unknown"  '[ "$(probe fam-fedora distro_family)" == "unknown" ]'
check "detect missing ID unknown" '[ "$(probe fam-noid distro_family)" == "unknown" ]'
check "detect missing file unknown" '[ "$(bash "$TMP/distro-probe.sh" "$ROOT" "$TMP/os/nope" distro_family)" == "unknown" ]'
check "unknown distro refuses" '! probe fam-fedora distro_require >/dev/null 2>&1'
check "unknown refusal names the ID" 'out="$(probe fam-fedora distro_require 2>&1 || true)"; grep -q "ID=.fedora." <<<"$out"'

# Stub package managers that log their argv instead of touching the host.
mkdir -p "$TMP/stubbin"
export PKGLOG="$TMP/pkglog" INSTALLED_PKGS=""
: > "$PKGLOG"
cat > "$TMP/stubbin/pacman" <<'EOS'
#!/bin/bash
echo "pacman $*" >> "$PKGLOG"
if [[ "${1:-}" == "-Q" && -n "${2:-}" ]]; then
  case " $INSTALLED_PKGS " in *" $2 "*) exit 0;; *) exit 1;; esac
fi
exit 0
EOS
cat > "$TMP/stubbin/apt-get" <<'EOS'
#!/bin/bash
echo "apt-get $*" >> "$PKGLOG"
exit 0
EOS
cat > "$TMP/stubbin/dpkg-query" <<'EOS'
#!/bin/bash
echo "dpkg-query $*" >> "$PKGLOG"
pkg="${@: -1}"
case " $INSTALLED_PKGS " in
  *" $pkg "*) echo "install ok installed"; exit 0;;
  *) exit 1;;
esac
EOS
cat > "$TMP/stubbin/paccache" <<'EOS'
#!/bin/bash
echo "paccache $*" >> "$PKGLOG"
exit 0
EOS
chmod +x "$TMP/stubbin/"*
stub_probe() { PATH="$TMP/stubbin:$PATH" probe "$@"; }

check "debian maps python-pipx to pipx"      '[ "$(probe fam-debian distro_pkg python-pipx)" == "pipx" ]'
check "debian maps python to python3"        '[ "$(probe fam-debian distro_pkg python)" == "python3" ]'
check "debian maps docker to docker.io"      '[ "$(probe fam-debian distro_pkg docker)" == "docker.io" ]'
check "debian maps docker-compose to plugin" '[ "$(probe fam-debian distro_pkg docker-compose)" == "docker-compose-plugin" ]'
check "debian passes through unmapped"       '[ "$(probe fam-debian distro_pkg restic)" == "restic" ]'
check "arch keeps names as-is"               '[ "$(probe fam-arch distro_pkg python-pipx)" == "python-pipx" ]'

check "arch install uses pacman"   ': > "$PKGLOG"; stub_probe fam-arch pkg_install ripgrep >/dev/null 2>&1 && grep -qx "pacman -S --needed --noconfirm ripgrep" "$PKGLOG"'
check "debian install uses apt"    ': > "$PKGLOG"; stub_probe fam-debian pkg_install ripgrep >/dev/null 2>&1 && grep -qx "apt-get install -y ripgrep" "$PKGLOG"'
check "debian install updates apt first" ': > "$PKGLOG"; stub_probe fam-debian pkg_install ripgrep >/dev/null 2>&1 && head -1 "$PKGLOG" | grep -qx "apt-get update"'
check "debian install translates names" ': > "$PKGLOG"; stub_probe fam-debian pkg_install python-pipx docker >/dev/null 2>&1 && grep -qx "apt-get install -y pipx docker.io" "$PKGLOG"'
check "arch remove uses pacman"    ': > "$PKGLOG"; stub_probe fam-arch pkg_remove ripgrep >/dev/null 2>&1 && grep -qx "pacman -Rns --noconfirm ripgrep" "$PKGLOG"'
check "debian remove uses apt purge" ': > "$PKGLOG"; stub_probe fam-debian pkg_remove ripgrep >/dev/null 2>&1 && grep -qx "apt-get purge -y ripgrep" "$PKGLOG"'
check "arch upgrade uses pacman -Syu" ': > "$PKGLOG"; stub_probe fam-arch pkg_upgrade >/dev/null 2>&1 && grep -qx "pacman -Syu --noconfirm" "$PKGLOG"'
check "debian upgrade uses apt"    ': > "$PKGLOG"; stub_probe fam-debian pkg_upgrade >/dev/null 2>&1 && grep -qx "apt-get upgrade -y" "$PKGLOG"'
check "arch orphans query pacman"  ': > "$PKGLOG"; stub_probe fam-arch pkg_orphans_remove >/dev/null 2>&1 && grep -qx "pacman -Qtdq" "$PKGLOG"'
check "debian orphans use autoremove" ': > "$PKGLOG"; stub_probe fam-debian pkg_orphans_remove >/dev/null 2>&1 && grep -qx "apt-get autoremove -y" "$PKGLOG"'
check "arch cache prefers paccache" ': > "$PKGLOG"; stub_probe fam-arch pkg_cache_clean >/dev/null 2>&1 && grep -qx "paccache -rk2" "$PKGLOG"'
check "debian cache uses apt clean" ': > "$PKGLOG"; stub_probe fam-debian pkg_cache_clean >/dev/null 2>&1 && grep -qx "apt-get clean" "$PKGLOG"'

check "arch installed check true"   'INSTALLED_PKGS="ripgrep" stub_probe fam-arch pkg_is_installed ripgrep'
check "arch installed check false"  '! INSTALLED_PKGS="" stub_probe fam-arch pkg_is_installed ripgrep'
check "debian installed check true" 'INSTALLED_PKGS="ripgrep" stub_probe fam-debian pkg_is_installed ripgrep'
check "debian installed check false" '! INSTALLED_PKGS="" stub_probe fam-debian pkg_is_installed ripgrep'

check "run_paru refuses off arch"  '! stub_probe fam-debian run_paru -S foo >/dev/null 2>&1'
check "run_paru refusal names AUR" 'out="$(stub_probe fam-debian run_paru -S foo 2>&1 || true)"; grep -qi "only available on Arch" <<<"$out"'

if have yq; then
  check "app install picks apt on debian" 'AW_OS_RELEASE="$TMP/os/fam-debian" run_aw --dry-run app install ripgrep && has "apt-get install"'
fi

echo "== pinned hashes =="
# Regression: a corrupted pinned hash (not exactly 64 hex chars) can never
# match a real sha256, so the verified download always fails. The Contabo
# zero-touch acceptance caught SOPS_SHA256_AMD64 with a duplicated tail
# segment: the installer aborted before enrollment and no pending claim ever
# appeared. Every pinned hash must be exactly 64 lowercase hex chars.
hash_bad=0
while IFS= read -r hv; do
  if [[ ! "$hv" =~ ^[0-9a-f]{64}$ ]]; then
    hash_bad=1; printf '  bad pinned hash: %s\n' "$hv"
  fi
done < <(grep -oE '_SHA256_[A-Z0-9_]+="[0-9a-fA-F]*"' "$ROOT/install.sh" | grep -oE '"[^"]*"' | tr -d '"')
check "pinned sha256 values are 64 hex chars" '[[ "$hash_bad" == "0" ]]'
check "pinned hashes exist" '[[ "$(grep -oE "_SHA256_[A-Z0-9_]+=" "$ROOT/install.sh" | wc -l)" -ge 1 ]]'

echo "== install.sh sops =="

# Exercise install.sh's dependency logic without touching the host: source the
# installer with `main` stripped and stub the tools it shells out to.
mkdir -p "$TMP/sopsbin"
cat > "$TMP/sopsbin/curl" <<'EOS'
#!/bin/bash
# Fake curl: writes canned content to the -o target, or fails on demand.
out=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
[[ "${CURL_FAIL:-0}" == "1" ]] && exit 1
[[ -n "${CURL_MARKER:-}" ]] && touch "$CURL_MARKER"
printf 'fake-deb-content' > "$out"
exit 0
EOS
cat > "$TMP/sopsbin/sha256sum" <<'EOS'
#!/bin/bash
printf '%s  %s\n' "${SHA256_STUB:-unset}" "${@: -1}"
EOS
cat > "$TMP/sopsbin/dpkg" <<'EOS'
#!/bin/bash
echo "dpkg $*" >> "$PKGLOG"
if [[ "${DPKG_FAIL_ONCE:-0}" == "1" && ! -f "$TMP/dpkg-failed" ]]; then
  touch "$TMP/dpkg-failed"
  exit 1
fi
# pretend the install drops a sops binary on PATH
printf '#!/bin/sh\necho stub-sops\n' > "$TMP/sopsbin/sops"
chmod +x "$TMP/sopsbin/sops"
exit 0
EOS
cat > "$TMP/sopsbin/apt-get" <<'EOS'
#!/bin/bash
echo "apt-get $*" >> "$PKGLOG"
exit 0
EOS
cat > "$TMP/sopsbin/dpkg-query" <<'EOS'
#!/bin/bash
# Fake dpkg-query -s: "installed" only for names listed in DPKG_INSTALLED.
[[ " ${DPKG_INSTALLED:-} " == *" ${2:-} "* ]]
EOS
cat > "$TMP/sopsbin/pacman" <<'EOS'
#!/bin/bash
echo "pacman $*" >> "$PKGLOG"
exit 0
EOS
cat > "$TMP/sopsbin/uname" <<'EOS'
#!/bin/bash
printf '%s\n' "${UNAME_M:-x86_64}"
EOS
chmod +x "$TMP/sopsbin/"*

cat > "$TMP/sops-probe.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; MODE="$2"; shift 2
sed '/^main "$@"/d' "$ROOT/install.sh" > "$TMP/sops-install.sh"
# shellcheck disable=SC1090
source "$TMP/sops-install.sh"
INSTALL_FAMILY="debian"
case "$MODE" in
  present)  install_sops_debian ;;
  install)  install_sops_debian ;;
  deps)     install_deps ;;
  archdeps) INSTALL_FAMILY="arch"; install_deps ;;
esac
EOS
sops_probe() { # <install.sh path> <mode>
  rm -f "$TMP/dpkg-failed" "$TMP/curl-marker"
  # The installer's footprint ledger goes to a scratch state dir, never the host.
  export PKGLOG="$TMP/sopspkglog" CURL_MARKER="$TMP/curl-marker" TMP STATE_DIR="$TMP/sopsstate"
  : > "$PKGLOG"
  PATH="$TMP/sopsbin:/usr/bin:/bin" bash "$TMP/sops-probe.sh" "$1" "$2" > "$TMP/sops.out" 2>&1
}
shas() { grep -q "$1" "$TMP/sops.out"; }
check "sops present skips download" \
  'printf "#!/bin/sh\n" > "$TMP/sopsbin/sops"; chmod +x "$TMP/sopsbin/sops"; sops_probe "$ROOT" present && shas "sops present" && [[ ! -e "$TMP/curl-marker" ]]'
check "debian installs verified sops deb" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f3b" sops_probe "$ROOT" install && shas "sha256 verified" && grep -q "dpkg -i .*/sops_3.13.3_amd64.deb" "$PKGLOG" && shas "sops installed"'
check "debian skips sops on checksum mismatch (non-fatal)" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="deadbeef" sops_probe "$ROOT" install && shas "checksum mismatch" && shas "refusing to install"'
check "debian continues without sops when download fails" \
  'rm -f "$TMP/sopsbin/sops"; CURL_FAIL=1 sops_probe "$ROOT" install && shas "could not download sops"'
check "debian continues without sops on unknown arch" \
  'rm -f "$TMP/sopsbin/sops"; UNAME_M="riscv64" sops_probe "$ROOT" install && shas "no sops .deb for riscv64"'
check "debian retries sops install after fixing deps" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f3b" DPKG_FAIL_ONCE=1 sops_probe "$ROOT" install && grep -qx "apt-get install -f -y" "$PKGLOG" && [[ "$(grep -c "^dpkg -i" "$PKGLOG")" == "2" ]] && shas "sops installed"'
check "debian apt list excludes sops" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f3b" sops_probe "$ROOT" deps && grep -qx "apt-get install -y git curl jq openssl age restic ufw" "$PKGLOG" && ! grep -q "^apt-get.*sops" "$PKGLOG"'
check "arch pacman still installs sops from repos" \
  'sops_probe "$ROOT" archdeps && grep -qx "pacman -Syu --needed --noconfirm git curl jq openssl age restic ufw sops" "$PKGLOG"'

# footprint ledger: the installer's own entries, same format, checked before the package manager runs
check "installer records packages before installing" \
  'rm -rf "$TMP/sopsstate"; DPKG_INSTALLED="jq" sops_probe "$ROOT" deps && jq -e . "$TMP/sopsstate/ledger.jsonl" >/dev/null && [[ "$(jq -r "select(.name==\"jq\") | .by + \" \" + .kind + \" \" + (.priorInstalled|tostring)" "$TMP/sopsstate/ledger.jsonl")" == "install pkg true" ]] && [[ "$(jq -r "select(.name==\"ufw\") | .priorInstalled" "$TMP/sopsstate/ledger.jsonl")" == "false" ]]'
check "installer never records a package twice" \
  'DPKG_INSTALLED="jq" sops_probe "$ROOT" deps && DPKG_INSTALLED="ufw" sops_probe "$ROOT" deps && [[ "$(grep -c "\"name\":\"ufw\"" "$TMP/sopsstate/ledger.jsonl")" == "1" ]] && [[ "$(jq -r "select(.name==\"ufw\") | .priorInstalled" "$TMP/sopsstate/ledger.jsonl")" == "false" ]]'
check "installer dry-run plans its ledger entries" \
  'bash "$ROOT/install.sh" --dry-run --skip-deps --no-alias > "$TMP/ildr" 2>&1 && grep -q "ledger dir path=/opt/alwayswork" "$TMP/ildr" && grep -q "ledger file path=/usr/local/bin/alwayswork" "$TMP/ildr" && grep -q "ledger file path=/opt/alwayswork/bin/yq" "$TMP/ildr"'

echo "== agents.dsh zero-touch =="
# Exercise capabilities/agents.dsh/ensure.sh without touching the host:
# source it with stubbed config/distro/package helpers and stub binaries.
mkdir -p "$TMP/dshbin"
cat > "$TMP/dshbin/curl" <<'EOS'
#!/bin/bash
# Fake curl: packument JSON to stdout when no -o given, canned bytes to the
# -o target otherwise. Touches CURL_MARKER on every download call.
out=""; url=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  [[ "$a" == https://* ]] && url="$a"
  prev="$a"
done
[[ "${CURL_FAIL:-0}" == "1" ]] && exit 1
if [[ -z "$out" ]]; then
  printf '%s' "${PACKUMENT_JSON:-{}}"
else
  printf 'fake-download-content' > "$out"
  [[ -n "${CURL_MARKER:-}" ]] && touch "$CURL_MARKER"
fi
exit 0
EOS
cat > "$TMP/dshbin/sha256sum" <<'EOS'
#!/bin/bash
printf '%s  %s\n' "${SHA256_STUB:-unset}" "${@: -1}"
EOS
cat > "$TMP/dshbin/openssl" <<'EOS'
#!/bin/bash
# dgst emits canned bytes; base64 -A emits the canned digest of them.
if [[ "${1:-}" == "dgst" ]]; then printf 'fake-digest-bytes'; else printf '%s' "${SHA512_STUB_B64:-}"; fi
EOS
cat > "$TMP/dshbin/jq" <<'EOS'
#!/bin/bash
printf '%s' "${JQ_RESULT:-}"
EOS
cat > "$TMP/dshbin/npm" <<'EOS'
#!/bin/bash
echo "npm $*" >> "$PKGLOG"
# pretend the global install drops dsh on PATH
printf '#!/bin/sh\nexit 0\n' > "$TMP/dshbin/dsh"
chmod +x "$TMP/dshbin/dsh"
exit 0
EOS
cat > "$TMP/dshbin/tar" <<'EOS'
#!/bin/bash
echo "tar $*" >> "$PKGLOG"
# pretend extracting the node tarball drops node 22 on PATH (npm stub is
# already there)
printf '#!/bin/sh\n[ "$1" = "-v" ] && echo "v22.23.2"\n' > "$TMP/dshbin/node"
chmod +x "$TMP/dshbin/node"
exit 0
EOS
cat > "$TMP/dshbin/uname" <<'EOS'
#!/bin/bash
printf '%s\n' "${UNAME_M:-x86_64}"
EOS
chmod +x "$TMP/dshbin/"*
# Passthroughs for the coreutils the probe needs: the probe PATH is
# $TMP/dshbin ONLY, so the host's node/npm stay invisible to the stubs.
for _t in mktemp rm cut chmod touch; do ln -sf "/usr/bin/$_t" "$TMP/dshbin/$_t"; done
unset _t

cat > "$TMP/dsh-probe.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; MODE="$2"; shift 2
export AW_ROOT="$ROOT"
source "$ROOT/lib/core.sh"
CAP_ID="agents.dsh"
CAP_DIR="$ROOT/capabilities/agents.dsh"
cap_config() {
  case "$1" in
    dsh)         printf '%s' "${DSH_TEST_DSH:-}" ;;
    dsh_version) printf '%s' "${DSH_TEST_DSH_VERSION:-}" ;;
    *)           printf '' ;;
  esac
}
distro_family() { printf '%s' "${DSH_TEST_FAMILY:-debian}"; }
distro_pretty() { printf '%s-test\n' "${DSH_TEST_FAMILY:-debian}"; }
pkg_install() {
  printf 'pkg_install %s\n' "$*" >> "$PKGLOG"
  # pretend pacman drops a current node + npm on PATH
  printf '#!/bin/sh\n[ "$1" = "-v" ] && echo "v24.1.0"\n' > "$TMP/dshbin/node"
  chmod +x "$TMP/dshbin/node"
}
# shellcheck disable=SC1090
source "$ROOT/capabilities/agents.dsh/ensure.sh"
case "$MODE" in
  ensure) ds_ensure_harness ;;
esac
EOS
dsh_probe() { # <mode>
  # Fixtures (dsh/node stubs) are managed by each test, sops-style; the
  # probe only resets the logs. PATH is $TMP/dshbin alone so the host's
  # node/npm can never leak into the stubbed environment (bash itself is
  # resolved before the PATH override).
  rm -f "$TMP/curl-marker"
  export PKGLOG="$TMP/dshpkglog" CURL_MARKER="$TMP/curl-marker" TMP
  : > "$PKGLOG"
  local bash_bin
  bash_bin="$(command -v bash)"
  PATH="$TMP/dshbin" DRY_RUN=0 "$bash_bin" "$TMP/dsh-probe.sh" "$ROOT" "$1" > "$TMP/dsh.out" 2>&1
}
dshshas() { grep -q "$1" "$TMP/dsh.out"; }
dsh_reset() { rm -f "$TMP/dshbin/dsh" "$TMP/dshbin/node"; }
dsh_with_node22() { printf '#!/bin/sh\n[ "$1" = "-v" ] && echo "v22.23.2"\n' > "$TMP/dshbin/node"; chmod +x "$TMP/dshbin/node"; }
# Real pins, so the happy-path tests prove the script's constants verify.
NODE_PIN_X64="d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307"
DSH_PIN_B64="8Xc8hCQHcIWRmTCVU/xZdp6/qMsWMeAd2ObChKDEsfhUPJFXx6H0lgeb1DxUMD86HZrrVN+1bCvn1ppjZ/fOxw=="
check "existing dsh is used untouched (no download)" \
  'dsh_reset; printf "#!/bin/sh\nexit 0\n" > "$TMP/dshbin/dsh"; chmod +x "$TMP/dshbin/dsh"; dsh_probe ensure && dshshas "dshbin/dsh" && [[ ! -e "$TMP/curl-marker" ]]'
check "explicit --dsh override wins, no install" \
  'dsh_reset; mkdir -p "$TMP/custom"; printf "#!/bin/sh\nexit 0\n" > "$TMP/custom/dsh"; chmod +x "$TMP/custom/dsh"; DSH_TEST_DSH="$TMP/custom/dsh" dsh_probe ensure && dshshas "$TMP/custom/dsh" && [[ ! -e "$TMP/curl-marker" ]]'
check "debian zero-touch: node tarball then pinned dsh" \
  'dsh_reset; DSH_TEST_FAMILY=debian SHA256_STUB="$NODE_PIN_X64" SHA512_STUB_B64="$DSH_PIN_B64" dsh_probe ensure && dshshas "sha256 verified" && dshshas "sha512 verified" && dshshas "dshbin/dsh" && grep -q "^tar -xf" "$PKGLOG" && grep -q "npm install -g" "$PKGLOG"'
check "debian node checksum mismatch refuses the binary" \
  'dsh_reset; ! DSH_TEST_FAMILY=debian SHA256_STUB="deadbeef" dsh_probe ensure && dshshas "checksum mismatch" && dshshas "refusing to install"'
check "node download failure dies loudly" \
  'dsh_reset; ! DSH_TEST_FAMILY=debian CURL_FAIL=1 dsh_probe ensure && dshshas "could not download node"'
check "arch zero-touch: node via pacman, dsh via npm" \
  'dsh_reset; DSH_TEST_FAMILY=arch SHA512_STUB_B64="$DSH_PIN_B64" dsh_probe ensure && grep -qx "pkg_install nodejs" "$PKGLOG" && ! grep -q "^tar -xf" "$PKGLOG" && dshshas "node v24" && dshshas "dshbin/dsh"'
check "usable node present: skips node install" \
  'dsh_reset; dsh_with_node22; DSH_TEST_FAMILY=debian SHA512_STUB_B64="$DSH_PIN_B64" dsh_probe ensure && ! grep -q "^tar -xf" "$PKGLOG" && ! grep -q "^pkg_install" "$PKGLOG" && dshshas "dshbin/dsh"'
check "node too old is replaced" \
  'dsh_reset; printf "#!/bin/sh\n[ \"\$1\" = \"-v\" ] && echo \"v20.19.0\"\n" > "$TMP/dshbin/node"; chmod +x "$TMP/dshbin/node"; DSH_TEST_FAMILY=arch SHA512_STUB_B64="$DSH_PIN_B64" dsh_probe ensure && grep -qx "pkg_install nodejs" "$PKGLOG" && dshshas "node v24"'
check "dsh_version override verified against registry integrity" \
  'dsh_reset; dsh_with_node22; DSH_TEST_DSH_VERSION="0.1.6-alpha.2" JQ_RESULT="sha512-PHR/3ZHpJNWXlDQ3U9weFb7calWbSMJd2GD3z2iPJ8zAKL7ipuzyPy5xGbaXf2OA8hc0SAGJeoUW7nfatCNOYw==" SHA512_STUB_B64="PHR/3ZHpJNWXlDQ3U9weFb7calWbSMJd2GD3z2iPJ8zAKL7ipuzyPy5xGbaXf2OA8hc0SAGJeoUW7nfatCNOYw==" dsh_probe ensure && dshshas "@deepseek-ai/dsh@0.1.6-alpha.2" && dshshas "sha512 verified"'
check "unknown dsh_version dies" \
  'dsh_reset; dsh_with_node22; ! DSH_TEST_DSH_VERSION="9.9.9" JQ_RESULT="" dsh_probe ensure && dshshas "not found in the npm registry"'
check "suspicious dsh_version refused" \
  'dsh_reset; dsh_with_node22; ! DSH_TEST_DSH_VERSION="1.0;touch /tmp/pwned" dsh_probe ensure && dshshas "refusing suspicious"'
check "dsh tarball integrity mismatch refuses install" \
  'dsh_reset; dsh_with_node22; ! SHA512_STUB_B64="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" dsh_probe ensure && dshshas "integrity mismatch" && dshshas "refusing to install"'
check "pinned dsh sha512 decodes to 64 bytes" \
  'v="$(sed -n "s/^DSH_NPM_SHA512_DEFAULT=\"\([^\"]*\)\"/\1/p" "$ROOT/capabilities/agents.dsh/ensure.sh")"; [[ "$(python3 -c "import base64,sys; sys.stdout.write(str(len(base64.b64decode(sys.argv[1]))))" "$v")" == "64" ]]'
check "pinned node sha256 are 64 hex chars" \
  'bad=0; while IFS= read -r hv; do [[ "$hv" =~ ^[0-9a-f]{64}$ ]] || bad=1; done < <(grep -oE "^NODE_SHA256_[A-Z0-9_]+=\"[0-9a-f]*\"" "$ROOT/capabilities/agents.dsh/ensure.sh" | grep -oE "\"[^\"]*\"" | tr -d "\""); [[ "$bad" == "0" ]]'
# No dsh on the box: dry-run must print the plan, not die or download.
# Needs yq like the other enable/dry-run tests above (config rendering).
if have yq; then
# Container mode (the default) never installs node on the host: the dry run
# plans an image pull/build and a unit, and writes nothing.
check "dry-run enable without dsh prints plan, changes nothing" \
  'rm -f "$TMP/dsh"; PATH="$(printf "%s" "$PATH" | tr ":" "\n" | grep -v "^$TMP$" | paste -sd: -)" run_aw --dry-run enable agents.dsh && has "would pull ghcr.io/softstone1/alwayswork-dsh" && ! has "would install node" && [[ ! -e "$AW_STATE/webui.json" ]]'
fi

echo "== agents.dsh container (SYSTEM_SPEC §12) =="
# Render the workload unit into a scratch dir with the real lib helpers and a
# scratch config; no podman, no systemd, nothing on the host is touched.
cat > "$TMP/dsc-probe.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"; shift 2
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml"
export AW_SYSTEMD_DIR="$D/systemd" AW_OS_RELEASE="$D/../os/arch"
export CAP_ID=agents.dsh CAP_DIR="$ROOT/capabilities/agents.dsh"
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_SYSTEMD_DIR"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/hardware.sh"
source "$ROOT/lib/distro.sh"; source "$ROOT/lib/engine.sh"; source "$ROOT/lib/secrets.sh"
source "$ROOT/lib/capability.sh"; source "$ROOT/lib/workload.sh"
source "$CAP_DIR/ensure.sh"; source "$CAP_DIR/container.sh"
DRY_RUN=0
[[ -f "$AW_CONFIG" ]] || cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
"$@"
EOS
dsc_probe() { bash "$TMP/dsc-probe.sh" "$ROOT" "$TMP/dsc" "$@"; }
rm -rf "$TMP/dsc"
if have yq; then
  check "dsc: default image is the pinned GHCR tag" \
    '[[ "$(dsc_probe dsc_image)" == "ghcr.io/softstone1/alwayswork-dsh:$(sed -n "s/^DSH_NPM_VERSION_DEFAULT=\"\([^\"]*\)\".*/\1/p" "$ROOT/capabilities/agents.dsh/ensure.sh" | head -1)" ]]'
  check "dsc: image override wins, suspicious image refused" \
    'yq -i ".capabilities.config.agents.dsh.image = \"ghcr.io/x/y@sha256:abc\"" "$TMP/dsc/etc/worker.yaml" && [[ "$(dsc_probe dsc_image)" == "ghcr.io/x/y@sha256:abc" ]] && yq -i ".capabilities.config.agents.dsh.image = \"evil;rm -rf /\"" "$TMP/dsc/etc/worker.yaml" && ! dsc_probe dsc_image >/dev/null 2>&1; yq -i "del(.capabilities.config.agents.dsh.image)" "$TMP/dsc/etc/worker.yaml"'
  check "dsc: default mode is container, host is the escape hatch" \
    '[[ "$(dsc_probe dsc_mode)" == "container" ]] && yq -i ".capabilities.config.agents.dsh.mode = \"host\"" "$TMP/dsc/etc/worker.yaml" && [[ "$(dsc_probe dsc_mode)" == "host" ]] && yq -i "del(.capabilities.config.agents.dsh.mode)" "$TMP/dsc/etc/worker.yaml"'
  check "dsc: unit renders the isolation contract" \
    'dsc_probe dsc_write_unit >/dev/null 2>&1 && u="$TMP/dsc/systemd/alwayswork-dsh.service" && grep -q -- "--userns=auto" "$u" && grep -q -- "--read-only" "$u" && grep -q -- "--cap-drop ALL" "$u" && grep -q -- "no-new-privileges" "$u" && grep -q -- "--pids-limit" "$u" && grep -q -- "--memory" "$u"'
  check "dsc: unit publishes to loopback only and mounts the two volumes" \
    'u="$TMP/dsc/systemd/alwayswork-dsh.service"; grep -q -- "--publish 127.0.0.1:3080:3080" "$u" && ! grep -q -- "--publish 0.0.0.0" "$u" && grep -q -- "--volume $TMP/dsc/state/workspaces/dsh:/workspace:U" "$u" && grep -q -- "--volume $TMP/dsc/state/dsh/home:/home/dsh:U" "$u" && grep -q -- "--env-file $TMP/dsc/etc/dsh.env" "$u"'
  check "dsc: unit is a notify service that systemd restarts" \
    'u="$TMP/dsc/systemd/alwayswork-dsh.service"; grep -q "^Type=notify" "$u" && grep -q -- "--sdnotify=conmon" "$u" && grep -q "^Restart=always" "$u" && grep -q "^ExecStop=.*podman stop" "$u"'
  check "dsc: env file carries the trusted host and port, 0600" \
    'dsc_probe dsc_render_env >/dev/null 2>&1 && f="$TMP/dsc/etc/dsh.env" && grep -q "^DSH_TRUSTED_HOST=$(hostname).alwayswork.space$" "$f" && grep -q "^DSH_PORT=3080$" "$f" && [[ "$(stat -c %a "$f")" == "600" ]]'
  check "dsc: workspace falls back to a directory off btrfs" \
    'dsc_probe dsc_ensure_workspace >/dev/null 2>&1 && [[ -d "$TMP/dsc/state/workspaces/dsh" && -d "$TMP/dsc/state/dsh/home" ]]'
  check "dsc: env carries the UI gate facts from desired state; pinned key mounted read-only" \
    'yq -i ".access.teamDomain = \"team.cloudflareaccess.com\" | .access.uiAud = \"aud-node-ui\"" "$TMP/dsc/etc/worker.yaml" && printf "{\"kid\":\"ck-x\",\"alg\":\"Ed25519\",\"publicKey\":\"AA==\"}" > "$TMP/dsc/state/control-pubkey.json" && dsc_probe dsc_render_env >/dev/null 2>&1 && grep -q "^AW_ACCESS_TEAM_DOMAIN=team.cloudflareaccess.com$" "$TMP/dsc/etc/dsh.env" && grep -q "^AW_ACCESS_AUD=aud-node-ui$" "$TMP/dsc/etc/dsh.env" && grep -q "^AW_CONTROL_PUBKEY_FILE=/run/alwayswork/control-pubkey.json$" "$TMP/dsc/etc/dsh.env" && dsc_probe dsc_write_unit >/dev/null 2>&1 && grep -q -- "--volume $TMP/dsc/state/control-pubkey.json:/run/alwayswork/control-pubkey.json:ro" "$TMP/dsc/systemd/alwayswork-dsh.service"'
  check "dsc: --network none is honoured" \
    'yq -i ".capabilities.config.agents.dsh.network = \"none\"" "$TMP/dsc/etc/worker.yaml" && dsc_probe dsc_write_unit >/dev/null 2>&1 && grep -q -- "--network none" "$TMP/dsc/systemd/alwayswork-dsh.service" && yq -i "del(.capabilities.config.agents.dsh.network)" "$TMP/dsc/etc/worker.yaml"'
  check "dsc: dry-run enable agents.dsh pulls runtime.podman first" \
    'run_aw --dry-run enable agents.dsh && has "runtime.podman" && has "agents.dsh" && [[ "$(grep -n "runtime.podman" "$TMP/out" | head -1 | cut -d: -f1)" -lt "$(grep -n "Installing capability: agents.dsh" "$TMP/out" | head -1 | cut -d: -f1)" ]]'
fi
check "dsc: manifest requires runtime.podman"     'grep -q "requires: \[core, runtime.podman\]" "$ROOT/capabilities/agents.dsh/manifest.yaml"'
check "dsc: Containerfile verifies the tarball before npm" 'grep -q "openssl dgst -sha512" "$ROOT/capabilities/agents.dsh/Containerfile" && grep -q "USER dsh" "$ROOT/capabilities/agents.dsh/Containerfile"'
check "dsc: entrypoint binds loopback, gate in front"  'grep -q -- "--host 127.0.0.1" "$ROOT/capabilities/agents.dsh/entrypoint.sh" && grep -q "alwayswork-gate" "$ROOT/capabilities/agents.dsh/entrypoint.sh" && grep -q -- "--expose-internals" "$ROOT/capabilities/agents.dsh/entrypoint.sh"'
check "dsc: image workflow publishes the pinned tag"  'grep -q "alwayswork-dsh" "$ROOT/.github/workflows/image.yml" && grep -q "DSH_NPM_VERSION_DEFAULT" "$ROOT/.github/workflows/image.yml"'
check "dsc: runtime.podman provides userns ranges"    'grep -q "containers:2147483647:2147483648" "$ROOT/capabilities/runtime.podman/install.sh"'
check "apply persists resolved dependencies"          'grep -q "cfg_list_add .\.capabilities\.enabled. \"\$c\"" "$ROOT/commands/apply.sh"'

echo "== services.postgres on the workload contract (SYSTEM_SPEC §12.7) =="
cat > "$TMP/pg-probe.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"; shift 2
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml"
export AW_SYSTEMD_DIR="$D/systemd" AW_OS_RELEASE="$D/../os/arch" AW_TEST=1
export CAP_ID=services.postgres CAP_DIR="$ROOT/capabilities/services.postgres"
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_SYSTEMD_DIR"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/hardware.sh"
source "$ROOT/lib/distro.sh"; source "$ROOT/lib/engine.sh"; source "$ROOT/lib/secrets.sh"
source "$ROOT/lib/capability.sh"; source "$ROOT/lib/workload.sh"
source "$CAP_DIR/postgres.sh"
DRY_RUN=0
[[ -f "$AW_CONFIG" ]] || cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
"$@"
EOS
pg_probe() { bash "$TMP/pg-probe.sh" "$ROOT" "$TMP/pg" "$@"; }
rm -rf "$TMP/pg"
if have yq; then
  check "pg: defaults are a pinned major, loopback 5432, app db/role" \
    '[[ "$(pg_probe pg_image)" == "docker.io/library/postgres:16" && "$(pg_probe pg_port)" == "5432" && "$(pg_probe pg_db)" == "app" && "$(pg_probe pg_user)" == "app" ]]'
  check "pg: suspicious names are refused" \
    'yq -i ".capabilities.config.services.postgres.db = \"app; drop\"" "$TMP/pg/etc/worker.yaml" && ! pg_probe pg_db >/dev/null 2>&1; yq -i "del(.capabilities.config.services.postgres.db)" "$TMP/pg/etc/worker.yaml"'
  check "pg: unit is a writable-data workload with a healthcheck, loopback publish, data volume" \
    'pg_probe pg_write_unit >/dev/null 2>&1 && u="$TMP/pg/systemd/alwayswork-postgres.service" && grep -q -- "--userns=auto" "$u" && ! grep -q -- "--read-only" "$u" && grep -q -- "--health-cmd \"pg_isready -U postgres -h 127.0.0.1\"" "$u" && grep -q -- "--health-on-failure=stop" "$u" && grep -q -- "--publish 127.0.0.1:5432:5432" "$u" && grep -q -- "--volume $TMP/pg/state/services/postgres/data:/var/lib/postgresql/data:U" "$u" && grep -q -- "--user 999:999" "$u" && grep -q -- "--shm-size 256m" "$u" && grep -q "docker.io/library/postgres:16" "$u"'
  check "pg: memory_mb override lands as a container budget" \
    'yq -i ".capabilities.config.services.postgres.memory_mb = 3072" "$TMP/pg/etc/worker.yaml" && pg_probe pg_write_unit >/dev/null 2>&1 && grep -q -- "--memory 3072m" "$TMP/pg/systemd/alwayswork-postgres.service" && yq -i "del(.capabilities.config.services.postgres.memory_mb)" "$TMP/pg/etc/worker.yaml"'
  check "pg: init script creates the app role as owner, never hardcodes a password" \
    'pg_probe pg_render_init >/dev/null 2>&1 && f="$TMP/pg/state/services/postgres/init/10-app-role.sh" && grep -q "CREATE ROLE" "$f" && grep -q "AW_APP_PASSWORD" "$f" && ! grep -qi "password .[a-z0-9]\{8,\}" "$f"'
  check "pg: service is reported for the heartbeat as tcp 5432" \
    'pg_probe wl_report_service postgres PostgreSQL tcp 5432 >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json | jq -r ".[0] | .id + \" \" + .protocol + \" \" + (.port|tostring) + \" \" + .health")" == "postgres tcp 5432 unknown" ]]'
  check "pg: unreport removes it"     'pg_probe wl_unreport_service postgres >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json)" == "[]" ]]'
  check "workload: subvolume falls back to a directory off btrfs; snapshot warns" \
    'pg_probe wl_subvolume "$TMP/pg/state/x/data" >/dev/null 2>&1 && [[ -d "$TMP/pg/state/x/data" ]] && ! pg_probe wl_snapshot "$TMP/pg/state/x/data" >/dev/null 2>&1'
  check "workload: systemd quoting of arguments with spaces and quotes" \
    '[[ "$(pg_probe wl_qs --a "b c" "d\"e")" == "--a \"b c\" \"d\\\"e\" " ]]'
  check "pg: dry-run enable pulls runtime.podman and renders the unit" \
    'run_aw --dry-run enable services.postgres && has "runtime.podman" && has "alwayswork-postgres.service" && has "postgres ready on 127.0.0.1:5432"'
  check "aw service list shows nothing enabled"   'run_aw service list && has "none"'
  check "aw service refuses unknown ids"           '! run_aw service status nope 2>/dev/null'
fi
check "heartbeat carries expose.services when present" 'grep -q "expose:{services:" "$ROOT/lib/control.sh" && grep -q "wl_services_json" "$ROOT/lib/control.sh"'
check "service command is dispatched and documented" 'grep -q "service|help" "$ROOT/bin/alwayswork" && run_aw help && has "service <action> <id>"'

echo "== safe unattended updates (SYSTEM_SPEC §13.1) =="
cat > "$TMP/upd-probe.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"; shift 2
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml" AW_RUN_DIR="$D/run"
export AW_SYSTEMD_DIR="$D/systemd" AW_OS_RELEASE="$D/../os/arch" AW_TEST=1
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_RUN_DIR"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/hardware.sh"; source "$ROOT/lib/distro.sh"
source "$ROOT/lib/secrets.sh"; source "$ROOT/lib/snapshot.sh"; source "$ROOT/lib/health.sh"; source "$ROOT/lib/control.sh"; source "$ROOT/lib/updates.sh"
DRY_RUN="${PROBE_DRY:-0}"
[[ -f "$AW_CONFIG" ]] || cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
"$@"
EOS
upd_probe() { bash "$TMP/upd-probe.sh" "$ROOT" "$TMP/upd" "$@"; }
rm -rf "$TMP/upd"
if have yq; then
  check "update guard: refuses without the lock, allows the agent's own installs" \
    '! upd_probe upd_guard >/dev/null 2>&1 && AW_PKG_GUARD_OK=1 upd_probe upd_guard >/dev/null 2>&1'
  check "update guard: can be switched off in config" \
    'yq -i ".updates.guard = false" "$TMP/upd/etc/worker.yaml" && upd_probe upd_guard >/dev/null 2>&1; yq -i "del(.updates.guard)" "$TMP/upd/etc/worker.yaml"'
  check "boot check: nothing on probation is a no-op" 'upd_probe upd_boot_check >/dev/null 2>&1'
  check "boot check: healthy clears probation and records ok" \
    'upd_probe upd_probation_start 41 r_1 && AW_TEST_HEALTH=ok upd_probe upd_boot_check >/dev/null 2>&1 && [[ ! -e "$TMP/upd/state/update-probation.json" ]] && [[ "$(jq -r .state "$TMP/upd/state/update-result.json")" == "ok" && "$(jq -r .rolloutId "$TMP/upd/state/update-result.json")" == "r_1" ]]'
  check "boot check: unhealthy once waits, twice records rolled_back (no snapper here)" \
    'upd_probe upd_probation_start 42 r_2 && ! AW_TEST_HEALTH=bad upd_probe upd_boot_check >/dev/null 2>&1 && [[ "$(jq -r .boots "$TMP/upd/state/update-probation.json")" == "1" ]] && ! AW_TEST_HEALTH=bad upd_probe upd_boot_check >/dev/null 2>&1 && [[ "$(jq -r .state "$TMP/upd/state/update-result.json")" == "failed" ]]'
  check "rollout from desired state: runs once per id, reports running" \
    'rm -f "$TMP/upd/state/update-result.json"; upd_probe upd_apply_from_delivery "{\"update\":{\"rolloutId\":\"ro_abc\"}}" >/dev/null 2>&1 && [[ "$(jq -r .rolloutId "$TMP/upd/state/update-result.json")" == "ro_abc" && "$(jq -r .state "$TMP/upd/state/update-result.json")" == "running" ]] && ! upd_probe upd_apply_from_delivery "{\"update\":{\"rolloutId\":\"ro_abc\"}}" 2>&1 | grep -q "asks this node"'
  check "rollout: suspicious id ignored"  '! upd_probe upd_apply_from_delivery "{\"update\":{\"rolloutId\":\"../x\"}}" 2>&1 | grep -q "asks this node"'
  check "health carries the update result"  '[[ "$(upd_probe control_health_json | jq -r ".update.rolloutId")" == "ro_abc" ]]'
  check "aw update --dry-run: snapshot, upgrade, gate, probation" \
    'run_aw --dry-run update && has "pre-update" && has "update gate: dry-run" && has "on probation"'
  check "core installs the guard hook and the boot check" \
    'run_aw --dry-run enable core && has "00-alwayswork-guard.hook" && has "alwayswork-boot-check.service"'
fi

echo "== node UI gate (SYSTEM_SPEC §10 B) =="
check "gate ships in the image"       'grep -q "COPY gate.mjs /usr/local/bin/alwayswork-gate" "$ROOT/capabilities/agents.dsh/Containerfile" && grep -q "alwayswork-gate" "$ROOT/capabilities/agents.dsh/entrypoint.sh"'
if have node && node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 20 ? 0 : 1)" 2>/dev/null; then
  check "gate: JWT verification, cookie mint, proxy, tenant sessions, fail closed" 'node "$ROOT/tests/gate.test.mjs" > "$TMP/gate.out" 2>&1 && grep -q "failed 0" "$TMP/gate.out"'
else
  echo "  skip  node >= 20 not installed (gate tests)"
fi

# The delivery's access.teamDomain / access.uiAud land in config; null clears; junk is refused.
cat > "$TMP/uiaccess.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml"
mkdir -p "$AW_ETC" "$AW_STATE"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/hardware.sh"; source "$ROOT/lib/secrets.sh"; source "$ROOT/lib/control.sh"
DRY_RUN=0
cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
control_apply_ui_access '{"access":{"sshCa":null,"teamDomain":"team.cloudflareaccess.com","uiAud":"aud-1"}}'
[[ "$(cfg_get .access.teamDomain '')" == "team.cloudflareaccess.com" && "$(cfg_get .access.uiAud '')" == "aud-1" ]] || exit 1
control_apply_ui_access '{"access":{"sshCa":null,"uiAud":"bad aud;rm"}}'
[[ "$(cfg_get .access.uiAud '')" == "aud-1" ]] || exit 2
control_apply_ui_access '{"access":{"sshCa":null}}'
[[ "$(cfg_get .access.uiAud '')" == "aud-1" ]] || exit 3
control_apply_ui_access '{"access":{"sshCa":null,"uiAud":null}}'
[[ -z "$(cfg_get .access.uiAud '')" ]] || exit 4
exit 0
EOS
if have yq; then
  check "delivered access.teamDomain/uiAud are recorded, junk refused, null clears" 'bash "$TMP/uiaccess.sh" "$ROOT" "$TMP/uiaccess"'
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
  # sec_set_stdin must store a value that never appeared on a command line.
  cat > "$TMP/store-stdin.sh" <<'EOS'
set -euo pipefail
ROOT="$1"
export AW_ROOT="$ROOT"
export AW_ETC="$2/etc" AW_STATE="$2/state" AW_LOG_DIR="$2/log" AW_CONFIG="$2/etc/worker.yaml"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/secrets.sh"
sec_init >/dev/null
printf '%s' 'fake-tunnel-token-123' | sec_set_stdin TUNNEL_TEST_KEY >/dev/null
[[ "$(sec_get TUNNEL_TEST_KEY)" == 'fake-tunnel-token-123' ]] || exit 1
EOS
  check "sec_set_stdin stores from stdin" 'bash "$TMP/store-stdin.sh" "$ROOT" "$TMP/stdin"'
else
  echo "  skip  secret store (sops/age/mikefarah yq missing)"
fi

echo "== tunnel from desired-state =="
# The agent consumes the tunnel token ONLY from the signed desired-state
# channel. The helper below stubs the secret store (0600 files), the service
# manager and the config layer, then runs one scenario per invocation,
# exiting 0 when the agent behaves as expected. Fake tokens only.
cat > "$TMP/tunnel-apply.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; OUT="$2"
export AW_ETC="$3" AW_STATE="$4" AW_TEST=1
SCENARIO="$5"
AW_ROOT="$ROOT"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/secrets.sh"
source "$ROOT/lib/capability.sh"
source "$ROOT/lib/hardening.sh"
source "$ROOT/lib/tunnel.sh"
source "$ROOT/lib/control.sh"

mkdir -p "$OUT" "$OUT/store" "$AW_ETC" "$AW_STATE"
: > "$OUT/calls"

# --- stubs ---------------------------------------------------------------
sec_backend() { printf '%s\n' "${SEC_BACKEND:-sops}"; }
sec_get()     { local f="$OUT/store/$1"; [[ -f "$f" ]] && cat "$f"; return 0; }
sec_set_stdin() {
  local k="$1" v; v="$(cat)" || return 1
  [[ -n "$v" ]] || return 1
  ( umask 077; printf '%s' "$v" > "$OUT/store/$k" )
  chmod 600 "$OUT/store/$k"
}
cap_install()      { printf 'cap_install %s\n' "$1" >> "$OUT/calls"; return "${CAP_INSTALL_RC:-0}"; }
cfg_set_str()      { printf 'cfg_set_str %s\n' "$1" >> "$OUT/calls"; }
cfg_set_expr()     { printf 'cfg_set_expr %s\n' "$1" >> "$OUT/calls"; }
cfg_get()          { printf '%s\n' "${CFG_GET:-disabled}"; }
cfg_bool()         { [[ "${CFG_BOOL:-true}" == "true" ]]; }
fw_ensure()        { printf 'fw_ensure\n' >> "$OUT/calls"; return "${FW_RC:-0}"; }
apply_ssh_policy() { printf 'apply_ssh_policy %s\n' "${1:-<cfg>}" >> "$OUT/calls"; return "${SSH_RC:-0}"; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$OUT/calls"
  case "$1 $2" in
    "is-active --quiet")                 return "${SYS_ACTIVE_RC:-0}" ;;
    "list-unit-files cloudflared.service") return "${UNIT_RC:-1}" ;;
  esac
  return 0
}

D="$OUT/delivery.json"
mk_tunnel_delivery() { # <token> <hostname> — "none" for no tunnel section, "null" for an explicit null
  if [[ "$1" == "none" ]]; then
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9}}' > "$D"
  elif [[ "$1" == "null" ]]; then
    # The control plane sends an explicit null when no tunnel is provisioned
    # or the node opted out.
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9},"tunnel":null}' > "$D"
  else
    jq -n --arg t "$1" --arg h "$2" \
      '{state:"approved",sequence:9,config:{configVersion:9},tunnel:{token:$t,hostname:$h}}' > "$D"
  fi
}

case "$SCENARIO" in
  tunnel-first)
    mk_tunnel_delivery "FAKE_TOKEN_AAA" "n1.alwayswork.space"
    tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1 || exit 1
    [[ "$(cat "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN")" == "FAKE_TOKEN_AAA" ]] || exit 1
    [[ "$(stat -c %a "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN")" == "600" ]] || exit 1
    grep -qx "cap_install access.tunnel" "$OUT/calls" || exit 1
    grep -qx "cfg_set_str .capabilities.config.access.tunnel.domain" "$OUT/calls" || exit 1
    [[ "$(jq -r .hostname "$AW_STATE/tunnel.json")" == "n1.alwayswork.space" ]] || exit 1
    [[ "$(jq -r .source "$AW_STATE/tunnel.json")" == "control-plane" ]] || exit 1
    # The token must never travel as an argument to an external call.
    ! grep -q "FAKE_TOKEN_AAA" "$OUT/calls" || exit 1
    ;;
  tunnel-rotation)
    printf 'FAKE_TOKEN_AAA' > "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN"
    chmod 600 "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN"
    mk_tunnel_delivery "FAKE_TOKEN_BBB" "n1.alwayswork.space"
    tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1 || exit 1
    [[ "$(cat "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN")" == "FAKE_TOKEN_BBB" ]] || exit 1
    grep -qx "cap_install access.tunnel" "$OUT/calls" || exit 1
    ;;
  tunnel-same)
    printf 'FAKE_TOKEN_AAA' > "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN"
    chmod 600 "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN"
    mk_tunnel_delivery "FAKE_TOKEN_AAA" "n1.alwayswork.space"
    tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1 || exit 1
    grep -qx "cap_install access.tunnel" "$OUT/calls" || exit 1
    ;;
  tunnel-absent)
    mk_tunnel_delivery none ""
    tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1
    [[ "$?" == "3" ]] || exit 1
    [[ ! -e "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN" ]] || exit 1
    [[ ! -e "$AW_STATE/tunnel.json" ]] || exit 1
    ! grep -q "cap_install" "$OUT/calls" || exit 1
    ;;
  tunnel-null)
    # Explicit null (no tunnel provisioned, or the node opted out) is the
    # same as absent: no-op, and never a teardown of cloudflared.
    mk_tunnel_delivery null ""
    tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1
    [[ "$?" == "3" ]] || exit 1
    [[ ! -e "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN" ]] || exit 1
    [[ ! -e "$AW_STATE/tunnel.json" ]] || exit 1
    ! grep -q "cap_install" "$OUT/calls" || exit 1
    ;;
  tunnel-empty)
    mk_tunnel_delivery "" "n1.alwayswork.space"
    ! tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1 || exit 1
    [[ ! -e "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN" ]] || exit 1
    ;;
  tunnel-manual-then-delivered)
    # The manual `aw secrets set` value is a fallback: a verified delivered
    # token always replaces it.
    printf 'MANUAL_TOKEN' > "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN"
    chmod 600 "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN"
    mk_tunnel_delivery "DELIVERED_TOKEN" "n1.alwayswork.space"
    tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1 || exit 1
    [[ "$(cat "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN")" == "DELIVERED_TOKEN" ]] || exit 1
    ;;
  tunnel-no-backend)
    mk_tunnel_delivery "FAKE_TOKEN_AAA" "n1.alwayswork.space"
    ! tunnel_apply_from_delivery "$(cat "$D")" >/dev/null 2>&1 || exit 1
    [[ ! -e "$OUT/store/CLOUDFLARE_TUNNEL_TOKEN" ]] || exit 1
    ;;
  lockdown-tunnel-up)
    printf '{"hostname":"n1.alwayswork.space","source":"control-plane","updated_at":1}' > "$AW_STATE/tunnel.json"
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9}}' > "$D"
    control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    grep -qx "fw_ensure" "$OUT/calls" || exit 1
    grep -qx "apply_ssh_policy disabled" "$OUT/calls" || exit 1
    ;;
  lockdown-tunnel-down)
    printf '{"hostname":"n1.alwayswork.space","source":"control-plane","updated_at":1}' > "$AW_STATE/tunnel.json"
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9}}' > "$D"
    ! control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    ! grep -q "apply_ssh_policy" "$OUT/calls" || exit 1
    ;;
  lockdown-no-tunnel)
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9}}' > "$D"
    control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    ! grep -q "apply_ssh_policy" "$OUT/calls" || exit 1
    ! grep -q "fw_ensure" "$OUT/calls" || exit 1
    ;;
  lockdown-delivered-policy)
    printf '{"hostname":"n1.alwayswork.space","source":"control-plane","updated_at":1}' > "$AW_STATE/tunnel.json"
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9,"hardening":{"ssh":"tailscale"}}}' > "$D"
    control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    grep -qx "cfg_set_str .hardening.ssh" "$OUT/calls" || exit 1
    grep -qx "apply_ssh_policy tailscale" "$OUT/calls" || exit 1
    ;;
  lockdown-unknown-policy)
    printf '{"hostname":"n1.alwayswork.space","source":"control-plane","updated_at":1}' > "$AW_STATE/tunnel.json"
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9,"hardening":{"ssh":"bogus"}}}' > "$D"
    control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    ! grep -q "apply_ssh_policy" "$OUT/calls" || exit 1
    ;;
  lockdown-ssh-fails)
    printf '{"hostname":"n1.alwayswork.space","source":"control-plane","updated_at":1}' > "$AW_STATE/tunnel.json"
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9}}' > "$D"
    ! control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    ;;
  lockdown-tunnel-policy)
    printf '{"hostname":"n1.alwayswork.space","source":"control-plane","updated_at":1}' > "$AW_STATE/tunnel.json"
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9,"hardening":{"ssh":"tunnel"}}}' > "$D"
    control_apply_lockdown "$(cat "$D")" >/dev/null 2>&1 || exit 1
    grep -qx "apply_ssh_policy tunnel" "$OUT/calls" || exit 1
    ;;
  access-ca|access-ca-bad|access-ca-multiline|access-null|access-absent)
    # The SSH access CA arrives as a top-level "access" object. Dry-run: the
    # whole delivery runs, and the CA write must show up as a dry-run write
    # (or not at all) without touching the host.
    DRY_RUN=1; sec_backend() { printf 'none\n'; }
    case "$SCENARIO" in
      access-ca)           A='"access":{"sshCa":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeAccessCaKeyForTests test-ca\n"}' ;;
      access-ca-bad)       A='"access":{"sshCa":"not a key at all"}' ;;
      access-ca-multiline) A='"access":{"sshCa":"ssh-ed25519 AAAA one\nssh-ed25519 AAAA two"}' ;;
      access-null)         A='"access":null' ;;
      access-absent)       A='"ignored":true' ;;
    esac
    printf '{"state":"approved","sequence":9,"config":{"configVersion":9},%s}' "$A" > "$D"
    control_apply_delivery "$(cat "$D")" > "$OUT/apply.log" 2>&1 || exit 1
    case "$SCENARIO" in
      access-ca)
        grep -q "write /etc/ssh/alwayswork_access_ca.pub" "$OUT/apply.log" || exit 1
        grep -q "chmod 0644 /etc/ssh/alwayswork_access_ca.pub" "$OUT/apply.log" || exit 1 ;;
      access-ca-bad)
        grep -q "not an OpenSSH public key" "$OUT/apply.log" || exit 1
        ! grep -q "write /etc/ssh/alwayswork_access_ca.pub" "$OUT/apply.log" || exit 1 ;;
      access-ca-multiline)
        grep -q "single key line" "$OUT/apply.log" || exit 1
        ! grep -q "write /etc/ssh/alwayswork_access_ca.pub" "$OUT/apply.log" || exit 1 ;;
      access-null|access-absent)
        ! grep -q "alwayswork_access_ca.pub" "$OUT/apply.log" || exit 1 ;;
    esac
    # The rest of the delivery still applied and was recorded.
    grep -qx "cfg_set_expr .control.appliedVersion" "$OUT/calls" || exit 1
    [[ ! -e /etc/ssh/alwayswork_access_ca.pub || "$(stat -c %Y /etc/ssh/alwayswork_access_ca.pub)" -lt "$START" ]] || exit 1
    ;;
  *) printf 'unknown scenario: %s\n' "$SCENARIO" >&2; exit 2 ;;
esac
EOS
run_tunnel() { rm -rf "$TMP/tout" "$TMP/tetc" "$TMP/tstate"; START="$(date +%s)" bash "$TMP/tunnel-apply.sh" "$ROOT" "$TMP/tout" "$TMP/tetc" "$TMP/tstate" "$1" > "$TMP/tunnel.out" 2>&1; }
check "tunnel token stored 0600 on first delivery" 'run_tunnel tunnel-first'
check "tunnel token rotates on a new delivery"    'run_tunnel tunnel-rotation'
check "same token still reconciles the service"   'run_tunnel tunnel-same'
check "no tunnel section leaves state alone"     'run_tunnel tunnel-absent'
check "explicit null tunnel leaves state alone"  'run_tunnel tunnel-null'
check "empty tunnel token is refused"             'run_tunnel tunnel-empty'
check "delivered token wins over manual override" 'run_tunnel tunnel-manual-then-delivered'
check "no secret store fails the tunnel closed"   'SEC_BACKEND=none run_tunnel tunnel-no-backend'
check "lockdown runs once the tunnel is up"       'SYS_ACTIVE_RC=0 run_tunnel lockdown-tunnel-up'
check "lockdown defers while cloudflared is down" 'SYS_ACTIVE_RC=1 run_tunnel lockdown-tunnel-down'
check "lockdown skips non-tunnel nodes"           'UNIT_RC=1 run_tunnel lockdown-no-tunnel'
check "lockdown honors the delivered ssh policy"  'SYS_ACTIVE_RC=0 run_tunnel lockdown-delivered-policy'
check "lockdown ignores an unknown ssh policy"    'SYS_ACTIVE_RC=0 run_tunnel lockdown-unknown-policy'
check "lockdown failure stays unacked (retry)"    'SYS_ACTIVE_RC=0 SSH_RC=1 run_tunnel lockdown-ssh-fails'
check "lockdown accepts the tunnel ssh policy"    'SYS_ACTIVE_RC=0 run_tunnel lockdown-tunnel-policy'

echo "== ssh access ca from desired-state =="
check "delivery writes access.sshCa (dry-run)"     'run_tunnel access-ca'
check "delivery refuses a malformed ssh ca"        'run_tunnel access-ca-bad'
check "delivery refuses a multi-line ssh ca"       'run_tunnel access-ca-multiline'
check "explicit null access leaves the ca alone"   'run_tunnel access-null'
check "absent access leaves the ca alone"          'run_tunnel access-absent'

echo "== ssh policy tunnel =="
# Dry-run the policy with the service manager and firewall openers stubbed:
# the loopback drop-in must be written and port 22 must never be opened.
cat > "$TMP/ssh-tunnel.sh" <<'EOS'
set -uo pipefail
ROOT="$1"
export AW_ROOT="$ROOT" AW_ETC="$2/etc" AW_STATE="$2/state" AW_CONFIG="$2/etc/worker.yaml" AW_TEST=1 DRY_RUN=1
source "$ROOT/lib/core.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/firewall.sh"
source "$ROOT/lib/hardening.sh"
source "$ROOT/lib/capability.sh"
source "$ROOT/lib/control.sh"
systemctl()           { printf 'systemctl %s\n' "$*" >&2; }
fw_allow_port()       { printf 'FIREWALL-OPEN %s\n' "$*" >&2; }
fw_allow_subnet_port(){ printf 'FIREWALL-OPEN %s\n' "$*" >&2; }
fw_allow_iface()      { printf 'FIREWALL-OPEN %s\n' "$*" >&2; }
cfg_get()             { printf 'tunnel\n'; }
cfg_bool()            { return 0; }
apply_ssh_policy tunnel
EOS
run_ssh_tunnel() { bash "$TMP/ssh-tunnel.sh" "$ROOT" "$TMP/sshtun" > "$TMP/sshtun.out" 2>&1; }
check "tunnel policy exits 0"                    'run_ssh_tunnel'
check "tunnel policy writes the loopback drop-in" 'grep -q "write /etc/ssh/sshd_config.d/10-alwayswork-tunnel.conf" "$TMP/sshtun.out"'
check "tunnel policy never opens the firewall"   '! grep -q "FIREWALL-OPEN" "$TMP/sshtun.out" && ! grep -q "ufw allow" "$TMP/sshtun.out"'
check "tunnel policy enables sshd"               'grep -q "systemctl enable --now sshd" "$TMP/sshtun.out"'
check "tunnel policy reloads sshd"               'grep -q "systemctl reload-or-restart sshd" "$TMP/sshtun.out"'
check "tunnel policy drops the lan drop-in"      'grep -q "rm -f /etc/ssh/sshd_config.d/10-alwayswork-lan.conf" "$TMP/sshtun.out"'
check "tunnel policy documented"                 'grep -q "| \`tunnel\` |" "$ROOT/docs/SECURITY.md" && grep -q "lan | tunnel" "$ROOT/config/defaults.yaml"'
check "doctor grades tunnel via loopback check"  'grep -q "ssh_loopback_only" "$ROOT/commands/doctor.sh"'

echo "== health =="
# control_health_json must be valid JSON with the SYSTEM_SPEC §6 names even
# with no config, no state and whatever tools this host happens to lack.
cat > "$TMP/health.sh" <<'EOS'
set -uo pipefail
ROOT="$1"
export AW_ROOT="$ROOT" AW_ETC="$2/etc" AW_STATE="$2/state" AW_CONFIG="$2/etc/worker.yaml" AW_TEST=1
for l in core distro config hardware engine firewall hardening secrets capability tunnel control health; do
  source "$ROOT/lib/$l.sh"
done
mkdir -p "$AW_STATE"
printf '{"score":88,"at":1789776000000}' > "$AW_STATE/doctor.json"
control_health_json
EOS
run_health() { bash "$TMP/health.sh" "$ROOT" "$TMP/health" > "$TMP/health.out" 2>"$TMP/health.err"; }
check "health json is valid"            'run_health && jq -e . "$TMP/health.out" >/dev/null'
check "health json is a single line"    '[[ "$(wc -l < "$TMP/health.out")" == "1" ]]'
check "health has agentVersion"         'jq -e ".agentVersion | type == \"string\"" "$TMP/health.out" >/dev/null'
check "health has uptimeSec"            'jq -e ".uptimeSec | type == \"number\"" "$TMP/health.out" >/dev/null'
check "health has clockSynced"          'jq -e ".clockSynced | type == \"boolean\"" "$TMP/health.out" >/dev/null'
check "health engine is typed"          'jq -e ".engine.kind == \"none\" and .engine.state == \"inactive\"" "$TMP/health.out" >/dev/null'
check "health agent is typed"           'jq -e ".agent.kind == \"none\" and (.agent.up | type == \"boolean\")" "$TMP/health.out" >/dev/null'
check "health reads the doctor cache"   'jq -e ".doctorScore == 88 and .doctorAt == 1789776000000" "$TMP/health.out" >/dev/null'
check "health disk pct is 0-100"        'jq -e "(.diskRootUsedPct // 0) >= 0 and (.diskRootUsedPct // 0) <= 100" "$TMP/health.out" >/dev/null'
check "health uses only spec field names" \
  '[[ -z "$(jq -r "keys[]" "$TMP/health.out" | grep -vxE "agentVersion|os|kernel|arch|uptimeSec|load1|cpuCount|memTotalMb|memUsedMb|diskRootTotalGb|diskRootUsedPct|tempC|engine|agent|tunnelUp|webUiUp|sshPolicy|doctorScore|doctorAt|capabilities|lanIp|clockSynced")" ]]'
check "health probes stay quiet"        '[[ ! -s "$TMP/health.err" ]]'
check "tick sends typed health"         'grep -q "health:\$h" "$ROOT/lib/control.sh" && ! grep -q "health:{}" "$ROOT/lib/control.sh"'
check "doctor caches its score"         'grep -q "health_doctor_record" "$ROOT/commands/doctor.sh"'
if have yq; then
  check "status --json carries health"  'run_aw --json status && jq -e ".health.agentVersion" "$TMP/out" >/dev/null'
  check "status --json lists capabilities in health" 'jq -e ".health.capabilities | index(\"core\") != null" "$TMP/out" >/dev/null'
fi

echo "== clock guard =="
# timedatectl is stubbed so the host's own NTP state cannot leak into the
# assertions; AW_CLOCK_FLOOR moves the plausibility floor around "now".
cat > "$TMP/clock.sh" <<'EOS'
set -uo pipefail
ROOT="$1"; SCENARIO="$2"
export AW_ROOT="$ROOT" AW_ETC="$3/etc" AW_STATE="$3/state" AW_CONFIG="$3/etc/worker.yaml" AW_TEST=1
source "$ROOT/lib/core.sh"
source "$ROOT/lib/control.sh"
timedatectl() { printf '%s\n' "${NTP:-no}"; }
mkdir -p "$3"
FUTURE=$(( $(date +%s) + 86400 * 365 ))
PAST=$(( $(date +%s) - 86400 ))
case "$SCENARIO" in
  floor-past)     NTP=no  AW_CLOCK_FLOOR="$PAST"   control_clock_trusted ;;
  floor-future)   ! NTP=no AW_CLOCK_FLOOR="$FUTURE" control_clock_trusted ;;
  ntp-wins)       NTP=yes AW_CLOCK_FLOOR="$FUTURE" control_clock_trusted ;;
  default-floor)  NTP=no  control_clock_trusted ;;
  tick-refuses)
    # An untrusted clock must stop the tick before anything is signed.
    control_sign() { printf 'SIGNED\n' >&2; printf 'sig'; }
    curl()         { printf 'CURL\n' >&2; }
    control_ensure_pubkey() { printf 'PUBKEY\n' >&2; return 0; }
    export NTP=no AW_CLOCK_FLOOR="$FUTURE"
    control_agent_tick > "$3/tick.out" 2>&1
    rc=$?
    [[ "$rc" == "1" ]] || exit 1
    grep -q "clock not trusted" "$3/tick.out" || exit 1
    ! grep -q "SIGNED\|CURL\|PUBKEY" "$3/tick.out" || exit 1 ;;
  *) exit 2 ;;
esac
EOS
run_clock() { bash "$TMP/clock.sh" "$ROOT" "$1" "$TMP/clock" > "$TMP/clock.out" 2>&1; }
check "clock trusted past the floor"          'run_clock floor-past'
check "clock untrusted before the floor"      'run_clock floor-future'
check "ntp sync trusts the clock regardless"  'run_clock ntp-wins'
check "default floor trusts a current clock"  'run_clock default-floor'
check "tick refuses to sign on a bad clock"   'run_clock tick-refuses'
check "enroll refuses on a bad clock"         'grep -q "control_clock_trusted" "$ROOT/lib/control.sh" && grep -q "before enrolling" "$ROOT/lib/control.sh"'
check "agent unit waits for time-sync"        'grep -q "After=network-online.target time-sync.target" "$ROOT/capabilities/control.join/install.sh" && grep -q "Wants=network-online.target time-sync.target" "$ROOT/capabilities/control.join/install.sh"'

echo "== zero-touch install =="
check "auto-enroll env is documented"  'grep -q "ALWAYSWORK_AUTO_ENROLL" "$ROOT/install.sh"'
check "auto-enroll enrolls, never bootstraps" \
  'ALWAYSWORK_AUTO_ENROLL=1 bash "$ROOT/install.sh" --dry-run --yes > "$TMP/izt" 2>&1 && grep -q "init --profile" "$TMP/izt" && ! grep -q "bootstrap" "$TMP/izt"'
check "auto-enroll registers a pending claim" 'grep -q "provision" "$TMP/izt"'
check "auto-enroll pins the agent until approval" 'grep -q "alwayswork-agent.service" "$TMP/izt"'
check "auto-enroll --token enrols directly (no claim)" \
  'ALWAYSWORK_AUTO_ENROLL=1 bash "$ROOT/install.sh" --dry-run --yes --control https://c.example --token aj_t1 --hostname kitchen --profile agent > "$TMP/izt2" 2>&1 && grep -q "enroll --control https://c.example --token aj_t1" "$TMP/izt2" && ! grep -q "alwayswork provision" "$TMP/izt2"'
check "auto-enroll --hostname is set before enrolling" \
  'grep -q "hostnamectl set-hostname kitchen" "$TMP/izt2" && [[ "$(grep -n "set-hostname" "$TMP/izt2" | head -1 | cut -d: -f1)" -lt "$(grep -n "enroll --control" "$TMP/izt2" | head -1 | cut -d: -f1)" ]]'
check "auto-enroll --profile reaches init"          'grep -q "init --profile agent" "$TMP/izt2"'
check "--token alone implies the zero-touch path"   'bash "$ROOT/install.sh" --dry-run --yes --token aj_t2 > "$TMP/izt3" 2>&1 && grep -q "enroll --control" "$TMP/izt3" && ! grep -q "bootstrap --yes" "$TMP/izt3"'
check "env equivalents still work"                  'ALWAYSWORK_AUTO_ENROLL=1 ALWAYSWORK_JOIN_TOKEN=aj_env ALWAYSWORK_HOSTNAME=envhost bash "$ROOT/install.sh" --dry-run --yes > "$TMP/izt4" 2>&1 && grep -q -- "--token aj_env" "$TMP/izt4" && grep -q "set-hostname envhost" "$TMP/izt4"'
check "bad --hostname is refused"                   '! ALWAYSWORK_AUTO_ENROLL=1 bash "$ROOT/install.sh" --dry-run --yes --hostname "bad host" >/dev/null 2>&1'
check "classic --yes still bootstraps" \
  'bash "$ROOT/install.sh" --dry-run --yes > "$TMP/icl" 2>&1 && grep -q "bootstrap --yes" "$TMP/icl"'
check "installer pulls openssl for device identity" 'grep -q "openssl" "$ROOT/install.sh"'
check "secrets set documents --stdin" 'grep -q -- "--stdin" "$ROOT/commands/secrets.sh"'
check "tunnel lib is sourced by the cli" 'grep -q "lib/tunnel.sh" "$ROOT/bin/alwayswork"'
check "hardening lib is sourced by the cli" 'grep -q "lib/hardening.sh" "$ROOT/bin/alwayswork"'
check "bootstrap uses the shared ssh policy" 'grep -q "apply_ssh_policy" "$ROOT/commands/bootstrap.sh" && ! grep -q "apply_ssh_policy()" "$ROOT/commands/bootstrap.sh"'

echo
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
