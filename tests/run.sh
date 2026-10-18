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
check "install.sh: an enrolled node is upgraded in place, never re-enrolled" \
  'grep -q "already_enrolled()" "$ROOT/install.sh" && grep -q "upgrade_in_place" "$ROOT/install.sh" && grep -q "systemctl restart alwayswork-agent.service" "$ROOT/install.sh" && grep -q "join token is ignored" "$ROOT/install.sh"'
check "install.sh: records the agent commit"  'grep -q "AW_AGENT_COMMIT" "$ROOT/install.sh" && grep -q "INSTALL_DIR/COMMIT" "$ROOT/install.sh"'
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

# The suite must never reach the real system: a probe that calls
# systemctl/ufw/podman/useradd as the developer's user would prompt for a
# password through polkit (it did once). Every such binary is shadowed by
# a no-op stub for the whole run; probes that need behaviour add their own.
mkdir -p "$TMP/nobin"
for b in systemctl systemd-run ufw useradd pacman apt-get snapper hostnamectl sysctl podman docker; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/nobin/$b"; chmod +x "$TMP/nobin/$b"
done
export PATH="$TMP/nobin:$PATH"

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
check "unattended image: installer and build script are sound" 'bash -n "$ROOT/image/arch/installer.sh" && bash -n "$ROOT/image/arch/build.sh" && grep -q "pacstrap -K /mnt base linux-lts" "$ROOT/image/arch/installer.sh" && grep -q "alwayswork-firstboot.service" "$ROOT/image/arch/installer.sh" && grep -q "die \"provision.toml must name the disk" "$ROOT/image/arch/installer.sh"'
check "unattended image: planted provision file is found by aw provision" 'grep -q "AW_STATE/provision.toml" "$ROOT/lib/control.sh"'
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
check "a first delivery that is not fully applied never abandons the enrolment" 'blk="$(sed -n "/^      approved)\$/,/return 0 ;;/{p;/return 0 ;;/q;}" "$ROOT/lib/control.sh")"; [[ -n "$blk" ]] && grep -q control_finish_enrolled <<<"$blk" && ! grep -q "die " <<<"$blk" && ! grep -q "initial apply failed" "$ROOT/lib/control.sh"'
check "cloudflared unit passes --token-file to run, not to tunnel" 'grep -q "ExecStart=\$bin tunnel --no-autoupdate run --token-file \$token_file" "$ROOT/capabilities/access.tunnel/install.sh" && ! grep -q -- "--token-file \$token_file run" "$ROOT/capabilities/access.tunnel/install.sh"'
check "an outdated cloudflared unit is rewritten, not just reported" 'grep -q "cloudflared unit is outdated; rewriting it" "$ROOT/capabilities/access.tunnel/install.sh"'
ssh_purge_probe() {
  local d="$TMP/sshp"; rm -rf "$d"; mkdir -p "$d/bin" "$d/systemd"
  printf '#!/bin/sh\necho "install ok installed"\n' > "$d/bin/dpkg-query"
  printf '#!/bin/sh\necho "$*" >> "%s/apt.log"\n' "$d" > "$d/bin/apt-get"; chmod +x "$d/bin/"*
  [[ "${1:-}" == breakglass ]] && : > "$d/systemd/alwayswork-sshd.service"
  PATH="$d/bin:$PATH" AW_SYSTEMD_DIR="$d/systemd" bash -c 'source "$1/lib/core.sh"; source "$1/lib/hardening.sh"; DRY_RUN=0; ssh_server_purge' _ "$ROOT" >/dev/null 2>&1
  cat "$d/apt.log" 2>/dev/null
}
check "lockdown removes openssh-server, but not while break-glass SSH is configured" \
  '[[ "$(ssh_purge_probe)" == *"purge -y -q openssh-server"* && -z "$(ssh_purge_probe breakglass)" ]]'
check "lockdown disables ssh.socket too (socket-activated Ubuntu)" 'grep -q "for u in ssh.socket ssh.service sshd.service" "$ROOT/lib/hardening.sh"'
check "cloudflared QUIC client sockets are not listeners; systemd on :22 is" '
  d="$(mktemp -d)"; printf "%s\n" "#!/bin/sh" "cat <<OUT" "udp UNCONN 0 0 *:33774 *:* users:((\"cloudflared\",pid=9,fd=7))" "tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:((\"systemd\",pid=1,fd=185))" "OUT" > "$d/ss"; chmod +x "$d/ss"
  out="$(PATH="$d:$PATH" bash -c "source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/health.sh\"; health_listeners_json" 2>/dev/null)"; rm -rf "$d"
  grep -q "\"port\":22" <<<"$out" && ! grep -q cloudflared <<<"$out"'
check "failing units carry a redacted log tail" '
  d="$(mktemp -d)"
  printf "%s\n" "#!/bin/sh" "case \"\$1\" in" "  list-units) echo \"alwayswork-postgres.service loaded activating auto-restart x\"; echo \"alwayswork-agent.service loaded active running y\" ;;" "  show) u=\"\$5\"; case \"\$3\" in ActiveState) [ \"\$u\" = alwayswork-agent.service ] && echo active || echo activating ;; SubState) [ \"\$u\" = alwayswork-agent.service ] && echo running || echo auto-restart ;; NRestarts) [ \"\$u\" = alwayswork-agent.service ] && echo 0 || echo 7 ;; esac ;;" "esac" > "$d/systemctl"
  printf "%s\n" "#!/bin/sh" "echo \"FATAL: could not load private key file\"" "echo \"connecting with password=hunter2\"" > "$d/journalctl"
  chmod +x "$d/systemctl" "$d/journalctl"
  out="$(PATH="$d:$PATH" AW_TEST=1 AW_TEST_UNITS=1 bash -c "source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/health.sh\"; health_failing_units_json")"; rm -rf "$d"
  jq -e "length == 1 and .[0].unit == \"alwayswork-postgres.service\" and .[0].sub == \"auto-restart\" and .[0].restarts == 7 and (.[0].logTail | test(\"private key\"))" <<<"$out" >/dev/null && ! grep -q hunter2 <<<"$out"'
check "postgres init/ and conf/ are world-readable (userns=auto containers read them)" 'grep -q "chmod 0755 \"\$dir\"" "$ROOT/capabilities/services.postgres/postgres.sh" && grep -q "chmod 0755 \"\$(pg_conf_dir)\"" "$ROOT/capabilities/services.postgres/postgres.sh"'
check "postgres data mounts one level up (postgres:18 layout), PGDATA below it" 'grep -q "PG_PGDATA=\"/var/lib/postgresql/pgdata\"" "$ROOT/capabilities/services.postgres/postgres.sh" && ! grep -q ":/var/lib/postgresql/data:U" "$ROOT/capabilities/services.postgres/postgres.sh"'
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
check "arch upgrade unattended (no SUDO_USER) never hands off to paru" \
  ': > "$PKGLOG"; printf "#!/bin/sh\necho paru-called >> \"$PKGLOG\"\n" > "$TMP/stubbin/paru"; chmod +x "$TMP/stubbin/paru"; SUDO_USER= stub_probe fam-arch pkg_upgrade >/dev/null 2>&1; rm -f "$TMP/stubbin/paru"; grep -qx "pacman -Syu --noconfirm" "$PKGLOG" && ! grep -q paru-called "$PKGLOG"'
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
# The host may already have sops. Only the test's installed stub counts.
have() { if [[ "$1" == sops ]]; then [[ -x "$TMP/sopsbin/sops" ]]; else command -v "$1" >/dev/null 2>&1; fi; }
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
  'INSTALL_DIR="$TMP/ledger-install" BIN_LINK="$TMP/ledger-bin" bash "$ROOT/install.sh" --dry-run --skip-deps --no-alias > "$TMP/ildr" 2>&1 && grep -q "ledger dir path=$TMP/ledger-install" "$TMP/ildr" && grep -q "ledger file path=$TMP/ledger-bin" "$TMP/ildr" && grep -q "ledger file path=$TMP/ledger-install/bin/yq" "$TMP/ildr"'

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
# Keep zero-touch probes independent of harnesses installed elsewhere on the host.
ds_dsh_bin() {
  local candidate
  for candidate in "$(cap_config dsh)" "$(command -v dsh 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}
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
    'dsc_probe dsc_render_env >/dev/null 2>&1 && f="$TMP/dsc/etc/dsh.env" && grep -q "^DSH_TRUSTED_HOST=dsh-pending.alwayswork.space$" "$f" && grep -q "^DSH_PORT=3080$" "$f" && [[ "$(stat -c %a "$f")" == "600" ]]'
  check "dsc: the trusted host is the surface name the control plane delivered, never the node hostname (§12.8)" \
    'yq -i ".surfaces.dsh = \"dsh-k3v9q.alwayswork.space\"" "$TMP/dsc/etc/worker.yaml" && dsc_probe dsc_render_env >/dev/null 2>&1 && grep -q "^DSH_TRUSTED_HOST=dsh-k3v9q.alwayswork.space$" "$TMP/dsc/etc/dsh.env" && ! grep -q "$(hostname)" "$TMP/dsc/etc/dsh.env"; yq -i "del(.surfaces)" "$TMP/dsc/etc/worker.yaml"'
  check "dsc: credential names given to the harness are recorded for the heartbeat (never values)" \
    '[[ "$(jq -c . "$TMP/dsc/state/dsh/credentials.json")" == "[]" ]]'
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
check "runtime.docker: disabling never stops a docker the operator already ran (ledger says it was active)" \
  'grep -q "ledger_service_before docker.service" "$ROOT/capabilities/runtime.docker/install.sh" && d="$TMP/dockled" && rm -rf "$d" && mkdir -p "$d" && printf "{\"kind\":\"service\",\"name\":\"docker.service\",\"priorEnabled\":true,\"priorActive\":true}\n" > "$d/ledger.jsonl" && out="$(AW_STATE="$d" bash -c "source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/ledger.sh\"; ledger_file() { echo \"$d/ledger.jsonl\"; }; run() { echo \"RUN: \$*\"; }; DRY_RUN=0; source \"$ROOT/capabilities/runtime.docker/uninstall.sh\"" 2>&1)" && grep -q "leaving the daemon" <<<"$out" && ! grep -q "RUN: systemctl disable" <<<"$out" && printf "{\"kind\":\"service\",\"name\":\"docker.service\",\"priorEnabled\":false,\"priorActive\":false}\n" > "$d/ledger.jsonl" && out="$(AW_STATE="$d" bash -c "source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/ledger.sh\"; ledger_file() { echo \"$d/ledger.jsonl\"; }; run() { echo \"RUN: \$*\"; }; DRY_RUN=0; source \"$ROOT/capabilities/runtime.docker/uninstall.sh\"" 2>&1)" && grep -q "RUN: systemctl disable --now docker" <<<"$out"'
check "dsc: runtime.podman opens DNS (53) from the workload subnet only, through the tracked firewall helpers" \
  'grep -q "fw_allow_subnet_port runtime.podman \"\$subnet\" 53 udp" "$ROOT/capabilities/runtime.podman/install.sh" && grep -q "fw_close_subnet_port runtime.podman" "$ROOT/capabilities/runtime.podman/uninstall.sh" && ! grep -q "ufw allow in on podman" "$ROOT/capabilities/runtime.podman/install.sh"'
check "dsc: runtime.podman lets the workload subnet out (ufw route allow), and closes it on remove" \
  'grep -q "fw_allow_forward_from runtime.podman \"\$subnet\"" "$ROOT/capabilities/runtime.podman/install.sh" && grep -q "fw_close_forward_from runtime.podman" "$ROOT/capabilities/runtime.podman/uninstall.sh" && grep -q "ufw route allow from" "$ROOT/lib/firewall.sh"'
check "dsc: runtime.podman creates the containers account the ranges belong to (shadow >= 4.14 ignores unknown owners)" \
  'grep -q "useradd --system --no-create-home" "$ROOT/capabilities/runtime.podman/install.sh" && mkdir -p "$TMP/nouser" && printf "#!/bin/sh\nexit 2\n" > "$TMP/nouser/getent" && chmod +x "$TMP/nouser/getent" && PATH="$TMP/nouser:$PATH" run_aw --dry-run enable runtime.podman && has "create system user containers"'
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
# A file-backed stand-in for the sealed store (sops/age are not on CI).
if [[ -n "${PG_FAKE_SEC:-}" ]]; then
  sec_backend() { echo sops; }; sec_exists() { :; }; sec_init() { :; }
  sec_get() { grep "^$1=" "$PG_FAKE_SEC" 2>/dev/null | head -1 | cut -d= -f2-; }
  sec_has() { [[ -n "$(sec_get "$1")" ]]; }
  sec_set() { { grep -v "^$1=" "$PG_FAKE_SEC" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$PG_FAKE_SEC.n"; mv "$PG_FAKE_SEC.n" "$PG_FAKE_SEC"; }
fi
DRY_RUN=0
[[ -f "$AW_CONFIG" ]] || cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
"$@"
EOS
pg_probe() { bash "$TMP/pg-probe.sh" "$ROOT" "$TMP/pg" "$@"; }
# podman for the reconcile: `exec` logs its argv and stdin and succeeds,
# except a session naming $PG_FAIL_ROLE, which fails like a refused ALTER.
mkdir -p "$TMP/pgbin"
cat > "$TMP/pgbin/podman" <<'EOS'
#!/usr/bin/env bash
[[ "$1" == exec ]] || exit 0
printf '%s\n' "$*" >> "$PG_LOG.argv"
in="$(cat)"; printf '%s\n' "$in" >> "$PG_LOG.stdin"
[[ -n "${PG_FAIL_ROLE:-}" && "$in" == *"rolname = '$PG_FAIL_ROLE'"* ]] && exit 1
exit 0
EOS
chmod +x "$TMP/pgbin/podman"
pg_rprobe() { PATH="$TMP/pgbin:$PATH" PG_LOG="$TMP/pglog" PG_FAKE_SEC="$TMP/pg/sec" PG_READY_TRIES=1 pg_probe "$@"; }
pg_cfg()  { yq -i "$1" "$TMP/pg/etc/worker.yaml"; }
pg_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
pg_t_roles() {
  local bad r=0
  pg_cfg '.capabilities.config.services.postgres.roles = " shop:owner, shop_ro ,_svc1"'
  [[ "$(pg_probe pg_roles 2>/dev/null)" == "$(printf 'shop\t1\nshop_ro\t0\n_svc1\t0')" ]] || r=1
  for bad in Shop 9x a-b postgres pg_monitor a,a a:owner,b:owner a:admin a,b,c,d,e,f,g,h,i "x$(printf 'y%.0s' {1..47})"; do
    BAD="$bad" yq -i '.capabilities.config.services.postgres.roles = strenv(BAD)' "$TMP/pg/etc/worker.yaml"
    if pg_probe pg_roles >/dev/null 2>&1; then echo "accepted: $bad"; r=1; fi
  done
  # 47 characters at most: PG_ROLE_<NAME>_PASSWORD stays a 64-character env name.
  L="x$(printf 'y%.0s' {1..46})" yq -i '.capabilities.config.services.postgres.roles = strenv(L)' "$TMP/pg/etc/worker.yaml"
  [[ "$(pg_probe pg_roles | cut -f1 | wc -c | tr -d ' ')" == 48 ]] || r=1
  pg_cfg '.capabilities.config.services.postgres.roles = "a,b,c,d,e,f,g,h"'
  [[ "$(pg_probe pg_roles | wc -l | tr -d ' ')" == 8 ]] || r=1
  pg_cfg 'del(.capabilities.config.services.postgres.roles)'
  [[ -z "$(pg_probe pg_roles)" ]] || r=1
  return "$r"
}
pg_t_secrets() {
  local a
  rm -f "$TMP/pg/state/secrets-node-owned.list"; : > "$TMP/pg/sec"
  pg_cfg '.capabilities.config.services.postgres.roles = "shop:owner"'
  pg_rprobe pg_ensure_secrets >/dev/null 2>&1 || return 1
  grep -Eq '^POSTGRES_PASSWORD=[A-Za-z0-9]{40}$' "$TMP/pg/sec" || return 1
  grep -Eq '^POSTGRES_APP_PASSWORD=[A-Za-z0-9]{40}$' "$TMP/pg/sec" || return 1
  grep -Eq '^PG_ROLE_SHOP_PASSWORD=[A-Za-z0-9]{40}$' "$TMP/pg/sec" || return 1
  [[ "$(cat "$TMP/pg/state/secrets-node-owned.list")" == "$(printf 'POSTGRES_PASSWORD\nPOSTGRES_APP_PASSWORD')" ]] || return 1
  a="$(cat "$TMP/pg/sec")"
  pg_rprobe pg_ensure_secrets >/dev/null 2>&1 || return 1
  [[ "$(cat "$TMP/pg/sec")" == "$a" ]] && [[ "$(wc -l < "$TMP/pg/state/secrets-node-owned.list" | tr -d ' ')" == 2 ]]
}
pg_t_reconcile() {
  local shop_pw="it's \"Q-Secret-9\" \\ pw" r="$TMP/pg/state/services/postgres/roles.json" in="$TMP/pglog.stdin"
  rm -f "$TMP/pglog".*; mkdir -p "$TMP/pg/state/services/postgres/data"
  printf 'POSTGRES_APP_PASSWORD=app-Secret-1\nPG_ROLE_SHOP_PASSWORD=%s\nPG_ROLE_READER_PASSWORD=reader-Secret-2\n' "$shop_pw" > "$TMP/pg/sec"
  pg_cfg '.capabilities.config.services.postgres.roles = "shop:owner,reader"'
  PG_FAIL_ROLE=reader pg_rprobe pg_reconcile >/dev/null 2>&1
  [[ "$(jq -r '[.[].name] | join(",")' "$r")" == "shop" ]] || { echo "roles: $(cat "$r")"; return 1; }
  [[ "$(jq -r '.[0].secretSha256' "$r")" == "$(printf '%s' "$shop_pw" | sha256sum | cut -c1-16)" ]] || return 1
  # Neither argv nor the SQL stream carries a password in the clear.
  ! grep -qF "Secret-" "$TMP/pglog.argv" "$in" || return 1
  grep -qF "\\set pwhex '$(printf '%s' reader-Secret-2 | od -An -tx1 | tr -d ' \n')'" "$in" || return 1
  grep -qF "SET log_min_error_statement = 'panic';" "$in" || return 1
  grep -qF "ALTER ROLE %I NOLOGIN" "$in" && grep -qF "string_to_array(:'keep', ',')" "$in" && grep -qF "\\set keep 'shop,reader'" "$in" || return 1
  grep -qF "COMMENT ON ROLE \"shop\" IS 'managed by alwayswork" "$in" || return 1
  grep -qF "ALTER DATABASE %I OWNER TO %I', 'app', 'shop'" "$in" || return 1
  grep -qF "CREATE OR REPLACE VIEW aw.status" "$in" && grep -qF 'GRANT USAGE ON SCHEMA aw TO "shop";' "$in" && grep -qF 'GRANT SELECT ON aw.status TO "shop";' "$in" || return 1
  grep -qF "INSERT INTO aw.facts" "$in" && grep -Eq "^  \('disk_free_bytes', '[0-9]+', now\(\)\), \('disk_total_bytes', '[0-9]+', now\(\)\)$" "$in" || return 1
  grep -qE "exec -i alwayswork-postgres (timeout [0-9]+ )?psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres" "$TMP/pglog.argv"
}
pg_t_legacy() {
  local in="$TMP/pglog.stdin"
  rm -f "$TMP/pglog".*
  pg_cfg 'del(.capabilities.config.services.postgres.roles)'
  pg_rprobe pg_reconcile >/dev/null 2>&1 || return 1
  grep -qF "ALTER ROLE %I WITH LOGIN PASSWORD %L', 'app'" "$in" && grep -qF "ALTER DATABASE %I OWNER TO %I', 'app', 'app'" "$in" \
    && ! grep -qF 'COMMENT ON ROLE "app"' "$in" && [[ "$(jq length "$TMP/pg/state/services/postgres/roles.json")" == 0 ]]
}
pg_t_heartbeat() {
  local f="$TMP/pg/state/services/postgres.json" ca="$TMP/pg/state/services/postgres/tls/ca.crt" j
  printf 'POSTGRES_APP_PASSWORD=app-Secret-1\nPG_ROLE_SHOP_PASSWORD=shop-Secret-3\n' > "$TMP/pg/sec"
  pg_cfg '.capabilities.config.services.postgres.roles = "shop:owner"'
  pg_rprobe pg_tls_ensure >/dev/null 2>&1 && pg_rprobe pg_reconcile >/dev/null 2>&1 || return 1
  pg_probe wl_report_manifest_surfaces services.postgres >/dev/null 2>&1 && pg_rprobe pg_report >/dev/null 2>&1 || return 1
  j="$(pg_probe wl_services_json)"
  jq -e --rawfile ca "$ca" --arg sha "$(openssl x509 -in "$ca" -outform DER | sha256sum | cut -d' ' -f1)" '
    .[0] | .id == "postgres" and .postgres.database == "app"
    and .postgres.tls.caPem == $ca and (.postgres.tls.caPem | startswith("-----BEGIN CERTIFICATE-----"))
    and .postgres.tls.caSha256 == $sha and (.postgres.tls.caSha256 | test("^[0-9a-f]{64}$"))
    and (.postgres.roles | length) == 1 and .postgres.roles[0].name == "shop"
    and .postgres.roles[0].secretSha256 == "'"$(printf shop-Secret-3 | sha256sum | cut -c1-16)"'"
    and (.postgres.roles[0] | keys) == ["name", "secretSha256"]' <<<"$j" >/dev/null || { echo "$j"; return 1; }
  [[ "$(pg_mode "$f")" == 644 ]] || return 1
  ! grep -rqF -e "Secret-" -e "PRIVATE KEY" "$TMP/pg/state/services" --include='*.json' || return 1
  # The keys and passwords are not in anything the heartbeat reads.
  ! grep -rlqF "Secret-" "$TMP/pg/state/services"
}
pg_t_heartbeat_off() {
  local j r=0
  pg_cfg '.capabilities.config.services.postgres.tls = "off" | del(.capabilities.config.services.postgres.roles)'
  pg_probe wl_report_manifest_surfaces services.postgres >/dev/null 2>&1 && pg_rprobe pg_report >/dev/null 2>&1 || r=1
  j="$(pg_probe wl_services_json)"
  pg_cfg 'del(.capabilities.config.services.postgres.tls)'
  jq -e '.[0].postgres | (has("tls") | not) and .roles == [] and .database == "app"' <<<"$j" >/dev/null || r=1
  pg_probe wl_unreport_manifest_surfaces services.postgres >/dev/null 2>&1
  return "$r"
}
# podman for the metrics sample: `exec` counts itself, logs argv and stdin,
# and answers one canned json_build_object row (plus a key the sample must
# drop) — or fails like a server that is down.
cat > "$TMP/pgbin/podman-metrics" <<'EOS'
#!/usr/bin/env bash
[[ "$1" == exec ]] || exit 0
printf '%s\n' "$*" >> "$PG_LOG.argv"
cat >> "$PG_LOG.stdin"
printf 'x\n' >> "$PG_LOG.count"
[[ -n "${PG_DOWN:-}" ]] && { echo 'psql: error: connection to server on socket failed' >&2; exit 2; }
printf '%s\n' '{"serverVersion" : "17.6", "inRecovery" : false, "uptimeSec" : 86400, "connections" : 7, "maxConnections" : 100, "activeQueries" : 2, "dbSizeBytes" : 123456789, "cacheHitRatio" : 0.9934, "xactCommit" : 5000, "xactRollback" : 12, "deadlocks" : 0, "longestQuerySec" : 3.2, "longestTxSec" : 41.0, "walArchivedCount" : null, "walFailedCount" : null, "lastFailedWal" : null, "lastArchivedAt" : null, "archiveLagSec" : null, "replicationSlots" : 1, "backrestSessions" : [], "checkpointer" : {"wait" : null}, "query" : "SELECT q-Secret-7"}'
EOS
mkdir -p "$TMP/pgmbin"; cp "$TMP/pgbin/podman-metrics" "$TMP/pgmbin/podman"; chmod +x "$TMP/pgmbin/podman"
pg_mprobe() { PATH="$TMP/pgmbin:$PATH" PG_LOG="$TMP/pgmlog" PG_FAKE_SEC="$TMP/pg/sec" pg_probe "$@"; }
pg_mcount() { wc -l < "$TMP/pgmlog.count" 2>/dev/null | tr -d ' ' || echo 0; }
pg_t_metrics() {
  local c="$TMP/pg/state/postgres-metrics.json" j
  rm -f "$TMP/pgmlog".* "$c"; mkdir -p "$TMP/pg/state/services/postgres/data"
  j="$(pg_mprobe pg_metrics_json)" || return 1
  jq -e '(keys_unsorted) == ["at","up","serverVersion","inRecovery","uptimeSec","connections","maxConnections","activeQueries",
          "dbSizeBytes","diskFreeBytes","diskTotalBytes","cacheHitRatio","xactCommit","xactRollback","deadlocks",
          "longestQuerySec","longestTxSec","walArchivedCount","walFailedCount","lastFailedWal","lastArchivedAt","archiveLagSec","replicationSlots","backrestSessions","checkpointer","hostTcp"]
     and .up == true and .serverVersion == "17.6" and .connections == 7 and .cacheHitRatio == 0.9934
     and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
     and (.diskFreeBytes | type) == "number" and .diskTotalBytes >= .diskFreeBytes and .walArchivedCount == null' <<<"$j" >/dev/null || { echo "$j"; return 1; }
  # One psql, over the socket as postgres, in the configured db, logging off.
  grep -qE "exec -i alwayswork-postgres (timeout 5 )?psql -X -q -A -t -v ON_ERROR_STOP=1 -U postgres -d app" "$TMP/pgmlog.argv" || return 1
  # With timeout(1) on the host it also bounds psql inside the container.
  ! command -v timeout >/dev/null || grep -qF "exec -i alwayswork-postgres timeout 5 psql" "$TMP/pgmlog.argv" || return 1
  grep -qF "SET log_statement = 'none';" "$TMP/pgmlog.stdin" && grep -qF "SELECT json_build_object(" "$TMP/pgmlog.stdin" || return 1
  [[ "$(pg_mcount)" == 1 ]] || return 1
  # Cached for 60 s: a second sample within the window does not touch the db.
  [[ "$(pg_mprobe pg_metrics_json)" == "$j" && "$(pg_mcount)" == 1 ]] || return 1
  touch -t 200001010000 "$c"
  pg_mprobe pg_metrics_json >/dev/null && [[ "$(pg_mcount)" == 2 ]] || return 1
  [[ "$(pg_mode "$c")" == 644 ]] || return 1
  return 0
}
pg_t_metrics_down() {
  local c="$TMP/pg/state/postgres-metrics.json" j
  rm -f "$TMP/pgmlog".* "$c"
  j="$(PG_DOWN=1 pg_mprobe pg_metrics_json)" || return 1
  jq -e '(keys_unsorted) == ["at","up"] and .up == false' <<<"$j" >/dev/null || { echo "$j"; return 1; }
  # Down is cached too: a fast heartbeat never retries within the window.
  PG_DOWN=1 pg_mprobe pg_metrics_json >/dev/null && [[ "$(pg_mcount)" == 1 ]] || return 1
  # No podman at all is down, not an error.
  rm -f "$c"
  j="$(PATH="/usr/bin:/bin" pg_probe pg_metrics_json)" && jq -e '.up == false' <<<"$j" >/dev/null
}
pg_t_metrics_heartbeat() {
  local c="$TMP/pg/state/postgres-metrics.json" j
  rm -f "$TMP/pgmlog".* "$c"
  printf 'POSTGRES_APP_PASSWORD=app-Secret-1\n' > "$TMP/pg/sec"
  pg_cfg 'del(.capabilities.config.services.postgres.roles)'
  pg_probe wl_report_manifest_surfaces services.postgres >/dev/null 2>&1 && pg_mprobe pg_report >/dev/null 2>&1 || return 1
  jq -e '.postgres.metrics.up == true' "$TMP/pg/state/services/postgres.json" >/dev/null || return 1
  # Each heartbeat refreshes it (through the 60 s cache); the existing fields stay.
  touch -t 200001010000 "$c"
  j="$(AW_TEST_PODMAN=1 pg_mprobe wl_services_json)" || return 1
  jq -e '.[0].postgres | .database == "app" and has("roles") and has("backup") and .metrics.up == true and .metrics.replicationSlots == 1' <<<"$j" >/dev/null || { echo "$j"; return 1; }
  [[ "$(pg_mcount)" == 2 ]] || return 1
  # No secret, no password, no query text anywhere the heartbeat reads.
  ! grep -qF -e "Secret-" -e "query" <<<"$j" || return 1
  ! grep -qF -e "Secret-" -e '"query"' "$c" || return 1
  ! grep -qF "Secret-" "$TMP/pgmlog.argv" "$TMP/pgmlog.stdin" || return 1
  j="$(AW_TEST_PODMAN=1 PG_DOWN=1 pg_mprobe eval 'rm -f "$AW_STATE/postgres-metrics.json"; wl_services_json')" || return 1
  jq -e '.[0].postgres.metrics | keys == ["at","up"] and .up == false' <<<"$j" >/dev/null || { echo "$j"; return 1; }
  pg_probe wl_unreport_manifest_surfaces services.postgres >/dev/null 2>&1
  rm -f "$c"
}
pg_t_admin() {
  local e="$TMP/pg/etc/postgres-admin.env" r=0
  [[ "$(pg_probe pg_admin)" == "off" ]] || r=1
  pg_cfg '.capabilities.config.services.postgres.admin = "on"'
  [[ "$(pg_probe pg_admin)" == "pgweb" ]] || r=1
  pg_rprobe pg_admin_render_env >/dev/null 2>&1 && grep -q 'sslmode=require$' "$e" || r=1
  pg_cfg '.capabilities.config.services.postgres.tls = "off"'
  pg_rprobe pg_admin_render_env >/dev/null 2>&1 && grep -q 'sslmode=disable$' "$e" || r=1
  pg_cfg 'del(.capabilities.config.services.postgres.admin) | del(.capabilities.config.services.postgres.tls)'
  [[ "$(pg_probe pg_admin)" == "off" ]] || r=1
  return "$r"
}
pg_t_delivery() {
  local d="$TMP/pg" out
  printf 'POSTGRES_PASSWORD\n' > "$d/state/secrets-node-owned.list"
  printf 'POSTGRES_PASSWORD="delivered-Super"\nPG_ROLE_SHOP_PASSWORD="delivered-Role"\n' > "$d/dec"
  # shellcheck disable=SC2016
  out="$(pg_probe eval 'source "$AW_ROOT/lib/control.sh"; sec_set() { printf "SET %s=%s\n" "$1" "$2"; }; control_import_secrets "$AW_STATE/../dec"' 2>&1)"
  rm -f "$d/dec"
  grep -qx "SET PG_ROLE_SHOP_PASSWORD=delivered-Role" <<<"$out" && ! grep -q "^SET POSTGRES_PASSWORD" <<<"$out" \
    && grep -q "POSTGRES_PASSWORD is node-owned" <<<"$out" && ! grep -q "delivered-Super" <<<"$out"
}
rm -rf "$TMP/pg"
if have yq; then
  check "pg: defaults are a pinned major, loopback 5432, app db/role" \
    '[[ "$(pg_probe pg_image)" == "docker.io/library/postgres:16" && "$(pg_probe pg_port)" == "5432" && "$(pg_probe pg_db)" == "app" && "$(pg_probe pg_user)" == "app" ]]'
  check "pg: suspicious names are refused" \
    'yq -i ".capabilities.config.services.postgres.db = \"app; drop\"" "$TMP/pg/etc/worker.yaml" && ! pg_probe pg_db >/dev/null 2>&1; yq -i "del(.capabilities.config.services.postgres.db)" "$TMP/pg/etc/worker.yaml"'
  check "pg: unit is a writable-data workload with a healthcheck, loopback publish, data volume" \
    'pg_probe pg_write_unit >/dev/null 2>&1 && u="$TMP/pg/systemd/alwayswork-postgres.service" && grep -q -- "--userns=auto" "$u" && ! grep -q -- "--read-only" "$u" && grep -q -- "--health-cmd \"pg_isready -U postgres -h 127.0.0.1\"" "$u" && grep -q -- "--health-on-failure=none" "$u" && grep -q -- "--health-start-period 10m" "$u" && grep -q -- "--publish 127.0.0.1:5432:5432" "$u" && grep -q -- "--volume $TMP/pg/state/services/postgres/data:/var/lib/postgresql:U" "$u" && grep -q -- "--user 999:999" "$u" && grep -q -- "--shm-size 256m" "$u" && grep -q "docker.io/library/postgres:16" "$u"'
  check "pg: memory_mb override lands as a container budget" \
    'yq -i ".capabilities.config.services.postgres.memory_mb = 3072" "$TMP/pg/etc/worker.yaml" && pg_probe pg_write_unit >/dev/null 2>&1 && grep -q -- "--memory 3072m" "$TMP/pg/systemd/alwayswork-postgres.service" && yq -i "del(.capabilities.config.services.postgres.memory_mb)" "$TMP/pg/etc/worker.yaml"'
  check "pg: init script creates the app role as owner, never hardcodes a password" \
    'pg_probe pg_render_init >/dev/null 2>&1 && f="$TMP/pg/state/services/postgres/init/10-app-role.sh" && grep -q "CREATE ROLE" "$f" && grep -q "AW_APP_PASSWORD" "$f" && ! grep -qi "password .[a-z0-9]\{8,\}" "$f"'
  check "pg: service is reported for the heartbeat as tcp 5432" \
    'pg_probe wl_report_service postgres PostgreSQL tcp 5432 >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json | jq -r ".[0] | .id + \" \" + .protocol + \" \" + (.port|tostring) + \" \" + .health")" == "postgres tcp 5432 unknown" ]]'
  check "workload: a changed env file (a new secret) changes the unit, so the container restarts with it" \
    'pg_probe pg_write_unit >/dev/null 2>&1; u="$TMP/pg/systemd/alwayswork-postgres.service"; a="$(sha256sum "$u")"; printf "X=1\n" >> "$TMP/pg/etc/postgres.env"; pg_probe pg_write_unit >/dev/null 2>&1; b="$(sha256sum "$u")"; [[ "$a" != "$b" ]] && grep -q "env: [0-9a-f]\{16\}" "$u" && ! grep -q "X=1" "$u"'
  check "pg: unreport removes it"     'pg_probe wl_unreport_service postgres >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json)" == "[]" ]]'
  check "pg: the web admin side-car is an http surface of the postgres workload (pgweb, read-only, loopback)" \
    'pg_probe pg_admin_write_unit >/dev/null 2>&1 && u="$TMP/pg/systemd/alwayswork-postgres-admin.service" && grep -q "sosedoff/pgweb" "$u" && grep -q -- "--read-only" "$u" && grep -q -- "--publish 127.0.0.1:8081:8081" "$u" && grep -q -- "--user 65534:65534" "$u" && grep -q -- "--env-file $TMP/pg/etc/postgres-admin.env" "$u" && pg_probe wl_report_surface postgres postgres-admin http 8081 / "PostgreSQL admin" >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json | jq -r ".[0] | .id + \" \" + .workload + \" \" + .kind + \" \" + .protocol")" == "postgres-admin postgres http http" ]]'
  check "pg: admin=off removes the side-car and its surface" \
    'yq -i ".capabilities.config.services.postgres.admin = \"off\"" "$TMP/pg/etc/worker.yaml" && pg_probe pg_admin_apply >/dev/null 2>&1; yq -i "del(.capabilities.config.services.postgres.admin)" "$TMP/pg/etc/worker.yaml"; [[ ! -e "$TMP/pg/systemd/alwayswork-postgres-admin.service" ]] && [[ "$(pg_probe wl_services_json)" == "[]" ]]'
  check "manifest: surfaces come from manifest.yaml, ports moved by the named config key" \
    'pg_probe wl_report_manifest_surfaces services.postgres >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json | jq -r ".[0] | .id + \" \" + .kind + \" \" + (.port|tostring) + \" \" + .name")" == "postgres tcp 5432 PostgreSQL" ]] && yq -i ".capabilities.config.services.postgres.port = 5444" "$TMP/pg/etc/worker.yaml" && pg_probe wl_report_manifest_surfaces services.postgres >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json | jq -r ".[0].port")" == "5444" ]]; yq -i "del(.capabilities.config.services.postgres.port)" "$TMP/pg/etc/worker.yaml"; pg_probe wl_unreport_manifest_surfaces services.postgres >/dev/null 2>&1; [[ "$(pg_probe wl_services_json)" == "[]" ]]'
  check "manifest: image version = explicit config > channel resolved by the control plane > pin" \
    '[[ "$(pg_probe wl_want_image tools.browser)" == "ghcr.io/softstone1/alwayswork-browser:20260919" ]] && printf "{\"ghcr.io/softstone1/alwayswork-browser\":{\"latest\":\"20261001\"},\"ghcr.io/softstone1/alwayswork-dsh\":{\"latest\":\"0.1.7\",\"next\":\"0.1.8-rc.1\"}}" > "$TMP/pg/state/image-targets.json" && [[ "$(pg_probe wl_want_image tools.browser)" == "ghcr.io/softstone1/alwayswork-browser:20261001" ]] && [[ "$(pg_probe wl_want_version agents.dsh)" == "0.1.7" ]] && yq -i ".capabilities.config.agents.dsh.channel = \"next\"" "$TMP/pg/etc/worker.yaml" && [[ "$(pg_probe wl_want_version agents.dsh)" == "0.1.8-rc.1" ]] && yq -i ".capabilities.config.agents.dsh.dsh_version = \"0.1.5-rc.2\"" "$TMP/pg/etc/worker.yaml" && [[ "$(pg_probe wl_want_version agents.dsh)" == "0.1.5-rc.2" ]] && yq -i ".capabilities.config.agents.dsh.channel = \"pinned\" | del(.capabilities.config.agents.dsh.dsh_version)" "$TMP/pg/etc/worker.yaml" && [[ "$(pg_probe wl_want_version agents.dsh)" == "0.1.5-rc.2" ]]; yq -i "del(.capabilities.config.agents.dsh)" "$TMP/pg/etc/worker.yaml"; rm -f "$TMP/pg/state/image-targets.json"'
  check "manifest: a changed image target keeps the previous set for rollback" \
    'pg_probe wl_note_image_targets "{\"r\":{\"latest\":\"1\"}}" >/dev/null 2>&1 && pg_probe wl_note_image_targets "{\"r\":{\"latest\":\"2\"}}" >/dev/null 2>&1 && [[ "$(jq -r .r.latest "$TMP/pg/state/image-targets.json")" == "2" ]] && pg_probe wl_targets_rollback && [[ "$(jq -r .r.latest "$TMP/pg/state/image-targets.json")" == "1" ]]; rm -f "$TMP/pg/state/image-targets.json"'
  check "surfaces: the primary http surface is flagged, workloads list carries its surfaces" \
    'pg_probe wl_report_surface dsh dsh http 3080 / "DSH" 1 >/dev/null 2>&1 && [[ "$(pg_probe wl_services_json | jq -r ".[0] | (.primary|tostring) + \" \" + .kind")" == "true http" ]] && [[ "$(pg_probe wl_surfaces_json | jq -r ".[0].workload")" == "dsh" ]] && pg_probe wl_unreport_service dsh >/dev/null 2>&1'
  check "workload: subvolume falls back to a directory off btrfs; snapshot warns" \
    'pg_probe wl_subvolume "$TMP/pg/state/x/data" >/dev/null 2>&1 && [[ -d "$TMP/pg/state/x/data" ]] && ! pg_probe wl_snapshot "$TMP/pg/state/x/data" >/dev/null 2>&1'
  check "workload: systemd quoting of arguments with spaces and quotes" \
    '[[ "$(pg_probe wl_qs --a "b c" "d\"e")" == "--a \"b c\" \"d\\\"e\" " ]]'
  check "pg: tls defaults on; the unit mounts the managed hba and the server cert (read-only, :U) and starts postgres with TLS and scram" \
    'pg_probe pg_write_unit >/dev/null 2>&1 && u="$TMP/pg/systemd/alwayswork-postgres.service" && [[ "$(pg_probe pg_tls)" == "on" ]] && grep -q -- "--volume $TMP/pg/state/services/postgres/conf:/etc/alwayswork/pg:ro" "$u" && grep -q -- "--volume $TMP/pg/state/services/postgres/tls/server:/etc/alwayswork/tls:ro,U" "$u" && grep -q "postgres:16 postgres -c hba_file=/etc/alwayswork/pg/pg_hba.conf -c password_encryption=scram-sha-256 -c ssl=on -c ssl_cert_file=/etc/alwayswork/tls/server.crt -c ssl_key_file=/etc/alwayswork/tls/server.key -c ssl_min_protocol_version=TLSv1.2" "$u" && grep -q -- "--label dev.alwayswork.pg_conf=[0-9a-f]\{16\}" "$u"'
  check "pg: the postgres unit runs without no-new-privileges (bisected cause of the PG18 hang); cap-drop and userns stay" \
    'pg_probe pg_write_unit >/dev/null 2>&1; u="$TMP/pg/systemd/alwayswork-postgres.service"; ! grep -q "no-new-privileges" "$u" && grep -q -- "--cap-drop ALL" "$u" && grep -q -- "--userns=auto" "$u"'
  check "pg: debug_drop leaves out exactly the named isolation flags, and a bad value is refused" \
    'pg_cfg ".capabilities.config.services.postgres.debug_drop = \"userns,cpus\"" && pg_probe pg_write_unit >/dev/null 2>&1; u="$TMP/pg/systemd/alwayswork-postgres.service"; ! grep -q -- "--userns=auto" "$u" && ! grep -q -- "--cpus " "$u" && grep -q -- "--cap-drop ALL" "$u" && pg_cfg ".capabilities.config.services.postgres.debug_drop = \"everything\"" && ! pg_probe pg_write_unit >/dev/null 2>&1; r=$?; pg_cfg "del(.capabilities.config.services.postgres.debug_drop)"; pg_probe pg_write_unit >/dev/null 2>&1; grep -q -- "--userns=auto" "$u" && (( r == 0 ))'
  check "pg: io_method passes through, defaults to the server's own, and a bad value is refused" \
    'pg_cfg ".capabilities.config.services.postgres.io_method = \"sync\"" && pg_probe pg_write_unit >/dev/null 2>&1; u="$TMP/pg/systemd/alwayswork-postgres.service"; grep -q -- "-c io_method=sync" "$u" && pg_cfg ".capabilities.config.services.postgres.io_method = \"fast\"" && ! pg_probe pg_io_method >/dev/null 2>&1; r=$?; pg_cfg "del(.capabilities.config.services.postgres.io_method)"; pg_probe pg_write_unit >/dev/null 2>&1; ! grep -q io_method "$u" && pg_cfg ".capabilities.config.services.postgres.version = \"18\"" && [[ -z "$(pg_probe pg_io_method)" ]] && pg_cfg ".capabilities.config.services.postgres.io_method = \"worker\"" && [[ "$(pg_probe pg_io_method)" == worker ]]; r2=$?; pg_cfg "del(.capabilities.config.services.postgres.io_method) | del(.capabilities.config.services.postgres.version)"; (( r == 0 && r2 == 0 ))'
  check "pg: tls=off drops the TLS flags and mount, keeps the hba and scram; a bad tls value is refused" \
    'pg_cfg ".capabilities.config.services.postgres.tls = \"off\"" && pg_probe pg_write_unit >/dev/null 2>&1; u="$TMP/pg/systemd/alwayswork-postgres.service"; ! grep -q -- "ssl=on" "$u" && ! grep -q "/etc/alwayswork/tls" "$u" && grep -q "hba_file=/etc/alwayswork/pg/pg_hba.conf -c password_encryption=scram-sha-256" "$u" && pg_cfg ".capabilities.config.services.postgres.tls = \"maybe\"" && ! pg_probe pg_tls >/dev/null 2>&1; r=$?; pg_cfg "del(.capabilities.config.services.postgres.tls)"; (( r == 0 ))'
  check "pg: managed hba — socket peer for postgres only, TCP hostssl scram (v4 and v6), never trust" \
    'pg_probe pg_render_hba >/dev/null 2>&1 && f="$TMP/pg/state/services/postgres/conf/pg_hba.conf" && grep -Eq "^local +all +postgres +peer$" "$f" && grep -Eq "^hostssl +all +all +0\.0\.0\.0/0 +scram-sha-256$" "$f" && grep -Eq "^hostssl +all +all +::/0 +scram-sha-256$" "$f" && ! grep -Eq "^host " "$f" && ! grep -v "^#" "$f" | grep -q trust && [[ "$(grep -vc "^#" "$f")" == 3 ]]'
  check "pg: tls=off hba is host scram with a warning, still no trust" \
    'pg_cfg ".capabilities.config.services.postgres.tls = \"off\"" && out="$(pg_probe pg_render_hba 2>&1)"; pg_cfg "del(.capabilities.config.services.postgres.tls)"; f="$TMP/pg/state/services/postgres/conf/pg_hba.conf"; grep -q "unencrypted" <<<"$out" && grep -Eq "^host +all +all +0\.0\.0\.0/0 +scram-sha-256$" "$f" && ! grep -q "^hostssl" "$f" && ! grep -v "^#" "$f" | grep -q trust; r=$?; pg_probe pg_render_hba >/dev/null 2>&1; (( r == 0 ))'
  if have openssl; then
    check "pg: TLS — a root-only CA outside the mounted dir signs a server cert for localhost, 127.0.0.1 and the hostnames" \
      'pg_cfg ".capabilities.config.services.postgres.hostnames = \"Kitchen-postgres.example.com, db.example.com\"" && pg_probe pg_tls_ensure >/dev/null 2>&1 && t="$TMP/pg/state/services/postgres/tls" && [[ -s "$t/ca.key" && -s "$t/ca.crt" && -s "$t/server/server.key" && -s "$t/server/server.crt" ]] && [[ "$(ls "$t/server")" == "$(printf "server.crt\nserver.key")" ]] && [[ "$(pg_mode "$t/ca.key")" == 600 && "$(pg_mode "$t/server/server.key")" == 600 && "$(pg_mode "$t")" == 700 ]] && openssl verify -CAfile "$t/ca.crt" "$t/server/server.crt" >/dev/null 2>&1 && openssl x509 -in "$t/server/server.crt" -noout -text | grep -q "DNS:localhost, IP Address:127.0.0.1, DNS:kitchen-postgres.example.com, DNS:db.example.com" && openssl x509 -in "$t/ca.crt" -noout -text | grep -q "CA:TRUE" && openssl x509 -checkend $((3000 * 86400)) -noout -in "$t/ca.crt" >/dev/null && ! openssl x509 -checkend $((800 * 86400)) -noout -in "$t/server/server.crt" >/dev/null'
    check "pg: TLS is kept across applies; new names reissue the server cert, never the CA" \
      't="$TMP/pg/state/services/postgres/tls" && ca="$(cat "$t/ca.crt")" && crt="$(cat "$t/server/server.crt")" && pg_probe pg_tls_ensure >/dev/null 2>&1 && [[ "$(cat "$t/server/server.crt")" == "$crt" ]] && pg_cfg ".capabilities.config.services.postgres.hostnames = \"db.example.com\"" && pg_probe pg_tls_ensure >/dev/null 2>&1 && [[ "$(cat "$t/server/server.crt")" != "$crt" && "$(cat "$t/ca.crt")" == "$ca" ]] && openssl verify -CAfile "$t/ca.crt" "$t/server/server.crt" >/dev/null 2>&1; r=$?; pg_cfg "del(.capabilities.config.services.postgres.hostnames)"; pg_probe pg_tls_ensure >/dev/null 2>&1; (( r == 0 ))'
    check "pg: heartbeat — the postgres entry carries database, the CA (public cert + DER sha256) and role fingerprints, no secret, mode 644" 'pg_t_heartbeat'
  fi
  check "pg: a bad hostname is refused" \
    'pg_cfg ".capabilities.config.services.postgres.hostnames = \"ok.example.com,bad_name;rm\"" && ! pg_probe pg_hostnames >/dev/null 2>&1; r=$?; pg_cfg "del(.capabilities.config.services.postgres.hostnames)"; (( r == 0 ))'
  check "pg: roles parse as name/owner; bad names, postgres, pg_*, duplicates, two owners and more than 8 are refused" 'pg_t_roles'
  check "pg: role secrets are PG_ROLE_<NAME>_PASSWORD" '[[ "$(pg_probe pg_role_secret shop_ro)" == "PG_ROLE_SHOP_RO_PASSWORD" ]]'
  check "pg: secrets — superuser/app generated and recorded node-owned, role passwords generated but not node-owned" 'pg_t_secrets'
  check "pg: reconcile — passwords reach psql hex-encoded on stdin, never argv; failed roles stay out of the report" 'pg_t_reconcile'
  check "pg: the legacy app role keeps its password and owns the db without a declared owner" 'pg_t_legacy'
  check "pg: a bad roles declaration never reconciles (a typo disables no role)" \
    'rm -f "$TMP/pglog".*; pg_cfg ".capabilities.config.services.postgres.roles = \"Bad Name\"" && ! pg_rprobe pg_reconcile >/dev/null 2>&1; r=$?; pg_cfg "del(.capabilities.config.services.postgres.roles)"; (( r == 0 )) && [[ ! -e "$TMP/pglog.stdin" ]]'
  check "pg: heartbeat — tls omitted when tls=off; undeclared roles drop out" 'pg_t_heartbeat_off'
  check "pg: metrics — one psql row (socket, logging off) plus host disk, in the contract shape; cached 60 s" 'pg_t_metrics'
  check "pg: a reconcile deferred at install is settled once the server answers, then not again" \
    'rm -f "$TMP/pglog.argv"; mkdir -p "$TMP/pg/state"; : > "$TMP/pg/state/postgres-reconcile-pending"; pg_rprobe pg_reconcile_owed >/dev/null 2>&1; [[ ! -e "$TMP/pg/state/postgres-reconcile-pending" ]] && grep -q "psql" "$TMP/pglog.argv" && rm -f "$TMP/pglog.argv" && pg_rprobe pg_reconcile_owed >/dev/null 2>&1 && [[ ! -s "$TMP/pglog.argv" ]] && grep -q "pg_reconcile_pending_mark" "$ROOT/capabilities/services.postgres/install.sh" && grep -q "pg_reconcile_owed" "$ROOT/lib/workload.sh"'
  check "pg: metrics — down or psql failing is {at, up:false} only, cached too" 'pg_t_metrics_down'
  check "pg: metrics — every heartbeat carries postgres.metrics beside the existing fields; no secret or query text" 'pg_t_metrics_heartbeat'
  check "pg: the web admin is off by default; on/pgweb enable it, over sslmode=require while tls=on" 'pg_t_admin && grep -q "enabled_default: false" "$ROOT/capabilities/services.postgres/manifest.yaml"'
  check "pg: apply reconciles and reports; the healthcheck refreshes disk facts but never fails on them" \
    'grep -q "pg_status_facts >/dev/null 2>&1 || true" "$ROOT/capabilities/services.postgres/healthcheck.sh" && grep -qE "^(if |elif )?pg_reconcile[; ]" "$ROOT/capabilities/services.postgres/install.sh" && grep -q "^pg_report" "$ROOT/capabilities/services.postgres/install.sh"'
  check "control: a delivered secret never replaces a node-owned one (warned by name only); role passwords are delivered" 'pg_t_delivery'
  check "pg: dry-run enable pulls runtime.podman and renders the unit" \
    'run_aw --dry-run enable services.postgres && has "runtime.podman" && has "alwayswork-postgres.service" && has "postgres ready on 127.0.0.1:5432"'
  check "aw service list shows nothing enabled"   'run_aw service list && has "none"'
  check "aw service refuses unknown ids"           '! run_aw service status nope 2>/dev/null'
fi
# --- services.postgres backups (pgBackRest, #14) ---------------------------------
# A podman that records every call (argv, and stdin of `exec`) and answers
# like pgBackRest and psql would; BR_FAIL makes a backup fail with that text
# in its error, BR_RUN_FAIL makes a throwaway container fail.
mkdir -p "$TMP/bkbin"
cat > "$TMP/bkbin/podman" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PG_LOG.argv"
case "$1" in
  exec)
    in="$(cat)"; [[ -n "$in" ]] && printf '%s\n' "$in" >> "$PG_LOG.stdin"
    case "$*" in
      *" pgbackrest "*" stanza-create")
        n="$(cat "$PG_LOG.locks" 2>/dev/null || echo 0)"
        if (( n > 0 )); then echo $((n - 1)) > "$PG_LOG.locks"; echo "P00  ERROR: [050]: unable to acquire lock on file '/tmp/pgbackrest/app-archive-1.lock'" >&2; exit 50; fi ;;
      *" pgbackrest "*" backup")
        if [[ -n "${BR_FAIL:-}" ]]; then echo "P00  ERROR: [039]: access denied: $BR_FAIL" >&2; exit 39; fi
        echo "P00   INFO: backup command end: completed successfully" ;;
      *pg_is_in_recovery*) echo f ;;
      *"WHERE datname"*) echo 1 ;;
      *"count(*) FROM pg_database"*) echo 3 ;;
    esac
    exit 0 ;;
  run)
    if [[ -n "${BR_RUN_FAIL:-}" ]]; then echo "AW_DRILL_FAIL $BR_RUN_FAIL"; exit 1; fi
    [[ "$*" == *alwayswork-drill* ]] && echo "AW_DRILL_OK databases=3"
    exit 0 ;;
esac
exit 0
EOS
chmod +x "$TMP/bkbin/podman"
bk_probe() { PATH="$TMP/bkbin:$PATH" PG_LOG="$TMP/bklog" PG_FAKE_SEC="$TMP/pg/sec" PG_READY_TRIES=1 pg_probe "$@"; }
bk_on()  { pg_cfg '.capabilities.config.services.postgres.backup = "pgbackrest" | .capabilities.config.services.postgres.backup_endpoint = "https://ACCT.r2.cloudflarestorage.com" | .capabilities.config.services.postgres.backup_bucket = "aw-backups"'; }
bk_off() { pg_cfg 'del(.capabilities.config.services.postgres.backup) | del(.capabilities.config.services.postgres.backup_endpoint) | del(.capabilities.config.services.postgres.backup_bucket) | del(.capabilities.config.services.postgres.backup_path) | del(.capabilities.config.services.postgres.backup_monthly_keep) | del(.capabilities.config.services.postgres.backup_retention_full_weeks) | del(.capabilities.config.services.postgres.backup_region)'; }
bk_secrets() { printf 'PGBACKREST_R2_ACCESS_KEY_ID=R2-Secret-Key-1\nPGBACKREST_R2_SECRET_ACCESS_KEY=R2-Secret-Access-2\nPGBACKREST_CIPHER_PASS=R2-Secret-Cipher-3\n' > "$TMP/pg/sec"; }
bk_reset() { rm -f "$TMP/bklog".*; rm -rf "$TMP/pg/state/services/postgres/pgbackrest" "$TMP/pg/state/services/postgres/backup-status.json" "$TMP/pg/systemd"/alwayswork-postgres-*; mkdir -p "$TMP/pg/systemd" "$TMP/pg/state/services/postgres/data"; }
bk_t_config() {
  local v r=0
  bk_off
  [[ "$(pg_probe pg_backup_mode)" == "off" ]] || r=1
  bk_on
  [[ "$(pg_probe pg_backup_endpoint)" == "acct.r2.cloudflarestorage.com" ]] || r=1
  [[ "$(pg_probe pg_backup_path)" == "/$(hostname -s | tr '[:upper:]' '[:lower:]')/app" ]] || r=1
  [[ "$(pg_probe pg_backup_region)" == "auto" && "$(pg_probe pg_backup_retention_days)" == 14 && "$(pg_probe pg_backup_monthly_keep)" == 12 ]] || r=1
  for v in 'backup = "maybe"' 'backup_endpoint = "http://acct.r2.cloudflarestorage.com"' 'backup_endpoint = "https://acct.r2.cloudflarestorage.com/bucket"' \
           'backup_endpoint = "https://x;rm"' 'backup_bucket = "Bad_Bucket"' 'backup_path = "/a/../b"' 'backup_path = "a/b"' 'backup_path = "/a/"' \
           'backup_retention_full_weeks = 0' 'backup_retention_full_weeks = 53' 'backup_retention_full_weeks = "x"' 'backup_monthly_keep = 121' 'backup_region = "Auto Region"'; do
    bk_on; pg_cfg ".capabilities.config.services.postgres.$v"
    if pg_probe eval 'pg_backup_mode >/dev/null && pg_backup_endpoint >/dev/null && pg_backup_bucket >/dev/null && pg_backup_path >/dev/null && pg_backup_full_weeks >/dev/null && pg_backup_monthly_keep >/dev/null && pg_backup_region >/dev/null' >/dev/null 2>&1; then echo "accepted: $v"; r=1; fi
  done
  bk_on; pg_cfg '.capabilities.config.services.postgres.backup_path = "/kitchen/shop" | .capabilities.config.services.postgres.backup_retention_full_weeks = 3 | .capabilities.config.services.postgres.backup_monthly_keep = 0'
  [[ "$(pg_probe pg_backup_path)" == "/kitchen/shop" && "$(pg_probe pg_backup_retention_days)" == 21 && "$(pg_probe pg_backup_monthly_keep)" == 0 ]] || r=1
  bk_off
  return "$r"
}
# Without the three group secrets: preflight and apply refuse by name, and
# nothing — unit, archive_command, config — is written.
bk_t_refuse() {
  local out r=0
  bk_reset; rm -f "$TMP/pg/systemd/alwayswork-postgres.service"; bk_on
  printf 'PGBACKREST_R2_ACCESS_KEY_ID=R2-Secret-Key-1\n' > "$TMP/pg/sec"
  # shellcheck disable=SC2016
  out="$(bk_probe eval 'f() { source "$CAP_DIR/preflight.sh"; }; f' 2>&1)" && r=1
  grep -q "PGBACKREST_R2_SECRET_ACCESS_KEY, PGBACKREST_CIPHER_PASS" <<<"$out" && ! grep -q "PGBACKREST_R2_ACCESS_KEY_ID" <<<"$out" || r=1
  # shellcheck disable=SC2016
  out="$(bk_probe eval 'f() { source "$CAP_DIR/install.sh"; }; f' 2>&1)" && r=1
  grep -q "WAL archiving stays off" <<<"$out" || r=1
  [[ ! -e "$TMP/pg/systemd/alwayswork-postgres.service" && ! -e "$TMP/pg/state/services/postgres/pgbackrest/pgbackrest.conf" ]] || r=1
  ! grep -q "R2-Secret" <<<"$out" || r=1
  bk_off
  return "$r"
}
bk_t_conf() {
  local f="$TMP/pg/state/services/postgres/pgbackrest/pgbackrest.conf" ino r=0 l
  bk_reset; bk_secrets; bk_on
  pg_cfg '.capabilities.config.services.postgres.backup_path = "/kitchen/app"'
  bk_probe pg_br_render >/dev/null 2>&1 || return 1
  [[ "$(pg_mode "$f")" == 600 && "$(pg_mode "$(dirname "$f")")" == 700 ]] || { echo "mode $(pg_mode "$f")"; r=1; }
  for l in '[global]' repo1-type=s3 repo1-s3-endpoint=acct.r2.cloudflarestorage.com repo1-s3-bucket=aw-backups repo1-s3-region=auto repo1-s3-uri-style=path \
           repo1-s3-key=R2-Secret-Key-1 repo1-s3-key-secret=R2-Secret-Access-2 repo1-cipher-type=aes-256-cbc repo1-cipher-pass=R2-Secret-Cipher-3 \
           repo1-path=/kitchen/app repo1-retention-full-type=time repo1-retention-full=14 \
           repo2-type=s3 repo2-path=/kitchen/app-monthly repo2-cipher-type=aes-256-cbc repo2-retention-full-type=count repo2-retention-full=12 \
           repo2-retention-archive-type=full repo2-retention-archive=1 archive-async=n log-level-file=off \
           '[app]' pg1-path=/var/lib/postgresql/pgdata pg1-socket-path=/var/run/postgresql; do
    grep -qxF -- "$l" "$f" || { echo "missing: $l"; r=1; }
  done
  # An unchanged config is not rewritten (the container owns the live file).
  ino="$(ls -i "$f" | awk '{print $1}')"
  bk_probe pg_br_render >/dev/null 2>&1; [[ "$(ls -i "$f" | awk '{print $1}')" == "$ino" ]] || r=1
  pg_cfg '.capabilities.config.services.postgres.backup_monthly_keep = 0'
  bk_probe pg_br_render >/dev/null 2>&1; ! grep -q '^repo2-' "$f" || r=1
  bk_off
  return "$r"
}
bk_t_unit() {
  local u="$TMP/pg/systemd/alwayswork-postgres.service" img r=0
  bk_reset; bk_secrets; bk_on
  bk_probe pg_br_render >/dev/null 2>&1 && bk_probe pg_write_unit >/dev/null 2>&1 || return 1
  img="$(bk_probe pg_image)"
  [[ "$img" =~ ^localhost/alwayswork-postgres:16-pgbackrest2\.59\.3-[0-9a-f]{8}$ ]] || { echo "image $img"; r=1; }
  grep -qF -- "-c wal_level=replica -c archive_mode=on -c \"archive_command=case %%f in *.partial) exit 0 ;; esac; pgbackrest --stanza=app archive-push %%p\" -c archive_timeout=60" "$u" || r=1
  grep -qF -- "--volume $TMP/pg/state/services/postgres/pgbackrest:/etc/pgbackrest:ro,U" "$u" || r=1
  grep -qF -- "--label dev.alwayswork.base_image=docker.io/library/postgres:16" "$u" && grep -qF "$img postgres -c" "$u" || r=1
  ! grep -q "R2-Secret" "$u" || r=1
  # A new base (channel / version) is a new local tag; a digest base works.
  pg_cfg '.capabilities.config.services.postgres.version = "17"'
  [[ "$(bk_probe pg_br_image)" == localhost/alwayswork-postgres:17-pgbackrest2.59.3-* && "$(bk_probe pg_br_image)" != "$img" ]] || r=1
  pg_cfg 'del(.capabilities.config.services.postgres.version) | .capabilities.config.services.postgres.image = "docker.io/library/postgres@sha256:ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d"'
  [[ "$(bk_probe pg_br_image)" =~ ^localhost/alwayswork-postgres:sha256-ca0bd484cb98-pgbackrest2\.59\.3-[0-9a-f]{8}$ ]] || { echo "digest $(bk_probe pg_br_image)"; r=1; }
  pg_cfg 'del(.capabilities.config.services.postgres.image)'
  # The Containerfile's default pin is the one the node builds with.
  grep -qx "ARG PGBACKREST_VERSION=$(bk_probe eval 'printf %s "$PG_BR_VERSION"')" "$ROOT/capabilities/services.postgres/Containerfile" || r=1
  bk_off
  bk_probe pg_write_unit >/dev/null 2>&1
  ! grep -qE "archive_mode|archive_command|pgbackrest|base_image" "$u" && grep -q "docker.io/library/postgres:16 postgres" "$u" || r=1
  return "$r"
}
bk_t_timers() {
  local d="$TMP/pg/systemd" r=0
  bk_reset; bk_secrets; bk_on
  bk_probe pg_br_timers_apply >/dev/null 2>&1 || return 1
  grep -qx "OnCalendar=Sun \*-\*-\* 03:00:00" "$d/alwayswork-postgres-backup-full.timer" || r=1
  grep -qx "OnCalendar=Mon..Sat \*-\*-\* 03:00:00" "$d/alwayswork-postgres-backup-diff.timer" || r=1
  grep -qx "OnCalendar=\*-\*-01 05:00:00" "$d/alwayswork-postgres-backup-monthly.timer" || r=1
  grep -qx "OnCalendar=Wed \*-\*-\* 04:00:00" "$d/alwayswork-postgres-restore-drill.timer" || r=1
  grep -qx "RandomizedDelaySec=10m" "$d/alwayswork-postgres-restore-drill.timer" && grep -qx "Persistent=true" "$d/alwayswork-postgres-backup-full.timer" || r=1
  grep -qx "ExecStart=/usr/local/bin/alwayswork service backup postgres --full" "$d/alwayswork-postgres-backup-full.service" || r=1
  grep -qx "ExecStart=/usr/local/bin/alwayswork service backup postgres --monthly" "$d/alwayswork-postgres-backup-monthly.service" || r=1
  grep -qx "ExecStart=/usr/local/bin/alwayswork service drill postgres" "$d/alwayswork-postgres-restore-drill.service" && grep -qx "Type=oneshot" "$d/alwayswork-postgres-restore-drill.service" || r=1
  pg_cfg '.capabilities.config.services.postgres.backup_monthly_keep = 0'
  bk_probe pg_br_timers_apply >/dev/null 2>&1
  [[ ! -e "$d/alwayswork-postgres-backup-monthly.timer" && ! -e "$d/alwayswork-postgres-backup-monthly.service" && -e "$d/alwayswork-postgres-backup-full.timer" ]] || r=1
  bk_probe pg_br_render >/dev/null 2>&1
  bk_probe pg_br_disable >/dev/null 2>&1
  [[ -z "$(ls "$d" | grep -E 'postgres-(backup|restore)')" && ! -e "$TMP/pg/state/services/postgres/pgbackrest" ]] || r=1
  bk_off
  return "$r"
}
bk_t_backup() {
  local st="$TMP/pg/state/services/postgres/backup-status.json" in="$TMP/bklog.stdin" out r=0
  bk_reset; bk_secrets; bk_on
  bk_probe pg_backup --full >/dev/null 2>&1 || return 1
  grep -qxF "exec -i alwayswork-postgres pgbackrest --stanza=app --repo=1 --type=full backup" "$TMP/bklog.argv" || r=1
  jq -e '.lastBackupOk == true and .lastBackupKind == "full" and .lastBackupError == "" and (.lastBackupAt | test("^[0-9-]{10}T"))' "$st" >/dev/null || r=1
  grep -qF "INSERT INTO aw.facts" "$in" && grep -qF "('last_backup_ok', convert_from(decode('$(printf true | od -An -tx1 | tr -d ' \n')', 'hex'), 'UTF8'), now())" "$in" \
    && grep -qF "('last_backup_kind', convert_from(decode('$(printf full | od -An -tx1 | tr -d ' \n')'" "$in" && grep -qF "'last_backup_at'" "$in" && grep -qF "'last_backup_error'" "$in" || r=1
  bk_probe pg_backup >/dev/null 2>&1 && grep -qxF "exec -i alwayswork-postgres pgbackrest --stanza=app --repo=1 --type=diff backup" "$TMP/bklog.argv" || r=1
  bk_probe pg_backup --monthly >/dev/null 2>&1 && grep -qxF "exec -i alwayswork-postgres pgbackrest --stanza=app --repo=2 --type=full backup" "$TMP/bklog.argv" || r=1
  ! bk_probe pg_backup --weird >/dev/null 2>&1 || r=1
  # A failure is recorded, with the error redacted, and fails the run.
  out="$(BR_FAIL="key R2-Secret-Access-2 rejected" bk_probe pg_backup --diff 2>&1)" && r=1
  jq -e '.lastBackupOk == false and .lastBackupKind == "diff" and (.lastBackupError | test("ERROR: \\[039\\]")) and (.lastBackupError | test("\\*\\*\\*"))' "$st" >/dev/null || { cat "$st"; r=1; }
  ! grep -q "R2-Secret" "$st" <<<"$out" && ! grep -q "R2-Secret" <<<"$out" || r=1
  ! grep -qF "$(printf R2-Secret-Access-2 | od -An -tx1 | tr -d ' \n')" "$in" || r=1
  ! grep -q "R2-Secret" "$TMP/bklog.argv" "$in" || r=1
  bk_off
  # backup=off keeps the logical dump, which takes no options.
  ! bk_probe pg_backup --full >/dev/null 2>&1 || r=1
  return "$r"
}
bk_t_drill() {
  local st="$TMP/pg/state/services/postgres/backup-status.json" data="$TMP/pg/state/services/postgres/data" a r=0
  bk_reset; bk_secrets; bk_on
  printf 'x\n' > "$data/marker"
  bk_probe pg_drill >/dev/null 2>&1 || return 1
  a="$(grep "^run " "$TMP/bklog.argv")"
  grep -qF -- "--name alwayswork-postgres-drill" <<<"$a" && grep -qF -- "--userns=auto" <<<"$a" && grep -qF -- "--user 999:999" <<<"$a" && grep -qF -- "--cap-drop ALL" <<<"$a" || r=1
  grep -qF -- "--volume $TMP/pg/state/services/postgres/drill/data:/var/lib/postgresql:U" <<<"$a" && grep -qF -- "--volume $TMP/pg/state/services/postgres/drill/conf:/etc/pgbackrest:ro,U" <<<"$a" || r=1
  grep -qF -- "--entrypoint /bin/sh localhost/alwayswork-postgres:" <<<"$a" && grep -qF "/usr/local/bin/alwayswork-drill app app" <<<"$a" || r=1
  # Never the live data directory, never a published port, never a secret.
  ! grep -qF "$data" "$TMP/bklog.argv" && ! grep -qF -- "--publish" <<<"$a" && ! grep -q "R2-Secret" "$TMP/bklog.argv" || r=1
  [[ ! -e "$TMP/pg/state/services/postgres/drill" && -f "$data/marker" ]] || r=1
  jq -e '.lastDrillOk == true and .lastDrillError == ""' "$st" >/dev/null || r=1
  grep -qF "'last_restore_drill_at'" "$TMP/bklog.stdin" && grep -qF "'last_restore_drill_ok'" "$TMP/bklog.stdin" || r=1
  # The drilled server never archives into the repository.
  bk_probe pg_drill_script | grep -qF -- "-c archive_mode=off" && bk_probe pg_drill_script | grep -qF 'listen_addresses=' || r=1
  # A failing drill is recorded and the scratch copy still goes.
  BR_RUN_FAIL="database app is not in the restore" bk_probe pg_drill >/dev/null 2>&1 && r=1
  jq -e '.lastDrillOk == false and (.lastDrillError | test("not in the restore"))' "$st" >/dev/null && [[ ! -e "$TMP/pg/state/services/postgres/drill" ]] || r=1
  # Not 1.2x the data size free: refused before any container.
  rm -f "$TMP/bklog".*
  mkdir -p "$TMP/bkdf"; printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 100 100 0 100%% /\\n"\n' > "$TMP/bkdf/df"; chmod +x "$TMP/bkdf/df"
  PATH="$TMP/bkdf:$PATH" bk_probe pg_drill >/dev/null 2>&1 && r=1
  ! grep -q "^run " "$TMP/bklog.argv" 2>/dev/null && jq -e '.lastDrillOk == false and (.lastDrillError | test("not enough disk"))' "$st" >/dev/null || r=1
  bk_off
  return "$r"
}
bk_t_restore() {
  local data="$TMP/pg/state/services/postgres/data" a r=0 aside
  bk_reset; bk_secrets; bk_on
  rm -rf "$TMP/pg/state/services/postgres"/data.*; printf 'live\n' > "$data/marker"
  # Explicit confirmation, a valid target, and backup=pgbackrest.
  bk_probe pg_restore --to '2026-10-17 09:30:00+00' >/dev/null 2>&1 && r=1
  bk_probe pg_restore --to 'yesterday; rm -rf /' --yes >/dev/null 2>&1 && r=1
  [[ ! -e "$TMP/bklog.argv" && -f "$data/marker" ]] || r=1
  bk_probe pg_restore --to '2026-10-17 09:30:00+00' --yes >/dev/null 2>&1 || r=1
  aside="$(ls -d "$data".before-restore-* 2>/dev/null | head -1)"
  [[ -n "$aside" && -f "$aside/marker" && -d "$data" && ! -f "$data/marker" ]] || { echo "aside: $aside"; r=1; }
  a="$(grep "^run " "$TMP/bklog.argv")"
  grep -qF -- "--name alwayswork-postgres-restore" <<<"$a" && grep -qF -- "--volume $data:/var/lib/postgresql:U" <<<"$a" || r=1
  grep -qF -- "--stanza=app --repo=1 --pg1-path=/var/lib/postgresql/pgdata --type=time --target=2026-10-17 09:30:00+00 --target-action=promote" <<<"$a" || r=1
  grep -qF "pg_is_in_recovery" "$TMP/bklog.argv" && grep -qF "WHERE datname = 'app'" "$TMP/bklog.argv" || r=1
  [[ ! -e "$TMP/pg/state/services/postgres/restore.lock" && ! -e "$TMP/pg/state/services/postgres/restore-conf" ]] || r=1
  ! grep -q "R2-Secret" "$TMP/bklog.argv" || r=1
  # --latest restores to the end of the archive (no target).
  rm -f "$TMP/bklog".*; rm -rf "$data".*; printf 'live\n' > "$data/marker"
  bk_probe pg_restore --latest --yes >/dev/null 2>&1 && ! grep -q -- "--type=time" "$TMP/bklog.argv" || r=1
  # A failed restore puts the previous data directory back.
  rm -f "$TMP/bklog".*; rm -rf "$data" "$data".*; mkdir -p "$data"; printf 'live\n' > "$data/marker"
  BR_RUN_FAIL=x bk_probe pg_restore --latest --yes >/dev/null 2>&1 && r=1
  [[ -f "$data/marker" && -n "$(ls -d "$data".failed-restore-* 2>/dev/null)" && -z "$(ls -d "$data".before-restore-* 2>/dev/null)" ]] || r=1
  rm -rf "$data".*
  bk_off
  ! bk_probe pg_restore --latest --yes >/dev/null 2>&1 || r=1
  return "$r"
}
bk_t_stanza_retry() {
  local r=0 st="$TMP/pg/state/services/postgres"
  bk_reset; bk_secrets; bk_on
  bk_probe pg_br_render >/dev/null 2>&1 || return 1
  # One archive-lock refusal, then success: retried, ready, the first full backup started.
  echo 1 > "$TMP/bklog.locks"; rm -f "$st/pgbackrest.stanza" "$st/pgbackrest.stanza.tried"
  PG_BR_STANZA_WAIT=0 bk_probe pg_br_stanza_ensure >/dev/null 2>&1 || r=1
  [[ "$(grep -c "stanza-create" "$TMP/bklog.argv")" == 2 && -s "$st/pgbackrest.stanza" ]] || r=1
  # Owed from the heartbeat: not again within ten minutes of a try, then yes.
  rm -f "$TMP/bklog".argv "$st/pgbackrest.stanza"; date +%s > "$st/pgbackrest.stanza.tried"
  bk_probe pg_br_stanza_owed >/dev/null 2>&1; ! grep -q "stanza-create" "$TMP/bklog.argv" 2>/dev/null || r=1
  echo 0 > "$st/pgbackrest.stanza.tried"
  bk_probe pg_br_stanza_owed >/dev/null 2>&1; grep -q "stanza-create" "$TMP/bklog.argv" && [[ -s "$st/pgbackrest.stanza" ]] || r=1
  rm -f "$TMP/bklog.locks"; bk_off
  return "$r"
}
bk_t_seed() {
  local r=0 st="$TMP/pg/state/services/postgres" a
  bk_reset; bk_secrets; bk_on
  # standby=on needs seed_from; with it, the repository read is the seed's.
  pg_cfg '.capabilities.config.services.postgres.standby = "on"'
  ! bk_probe pg_standby >/dev/null 2>&1 || r=1
  pg_cfg '.capabilities.config.services.postgres.seed_from = "/contabo-use-1/app"'
  [[ "$(bk_probe pg_backup_path)" == "/contabo-use-1/app" && "$(bk_probe pg_standby)" == on ]] || r=1
  pg_cfg '.capabilities.config.services.postgres.seed_from = "/../etc"'
  ! bk_probe pg_seed_from >/dev/null 2>&1 || r=1
  pg_cfg '.capabilities.config.services.postgres.seed_from = "/contabo-use-1/app"'
  # An empty data directory is seeded as a standby, from the seed's repository, in a throwaway container.
  rm -rf "$st/data/pgdata"; rm -f "$TMP/bklog.argv"
  bk_probe pg_seed_needed || r=1
  bk_probe pg_seed_restore >/dev/null 2>&1 || r=1
  a="$(grep "alwayswork-postgres-seed" "$TMP/bklog.argv" || true)"
  [[ "$a" == *"--repo1-path=/contabo-use-1/app"* && "$a" == *"--type=standby"* && "$a" == *"--stanza=app"* ]] || { echo "$a"; r=1; }
  # Data already there: never seeded again. A standby never creates a stanza.
  mkdir -p "$st/data/pgdata"; echo 18 > "$st/data/pgdata/PG_VERSION"
  ! bk_probe pg_seed_needed || r=1
  rm -f "$TMP/bklog.argv" "$st/pgbackrest.stanza" "$st/pgbackrest.stanza.tried"
  bk_probe pg_br_stanza_owed >/dev/null 2>&1; ! grep -q "stanza-create" "$TMP/bklog.argv" 2>/dev/null || r=1
  # seed_generation: a new token re-seeds a node with data (moved aside), once.
  pg_cfg '.capabilities.config.services.postgres.seed_generation = "g2"'
  bk_probe pg_seed_needed || r=1
  rm -f "$TMP/bklog.argv"; bk_probe pg_seed_restore >/dev/null 2>&1 || r=1
  ls -d "$st/data/pgdata.before-reseed-"* >/dev/null 2>&1 || r=1
  [[ "$(cat "$st/seed-generation" 2>/dev/null)" == g2 ]] || r=1
  mkdir -p "$st/data/pgdata"; echo 18 > "$st/data/pgdata/PG_VERSION"
  ! bk_probe pg_seed_needed || r=1
  pg_cfg 'del(.capabilities.config.services.postgres.seed_generation)'
  # standby=off: the node's own path again, and a seeded restore is promoted (no --type).
  pg_cfg '.capabilities.config.services.postgres.standby = "off"'
  [[ "$(bk_probe pg_backup_path)" == "/$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-' | head -c 63)/app" ]] || r=1
  rm -rf "$st/data/pgdata"; rm -f "$TMP/bklog.argv"
  bk_probe pg_seed_restore >/dev/null 2>&1; ! grep "alwayswork-postgres-seed" "$TMP/bklog.argv" | grep -q -- "--type=standby" || r=1
  pg_cfg 'del(.capabilities.config.services.postgres.standby) | del(.capabilities.config.services.postgres.seed_from)'
  bk_off
  return "$r"
}
bk_t_heartbeat() {
  local j r=0
  bk_reset; bk_secrets; bk_on
  bk_probe pg_backup --full >/dev/null 2>&1 && bk_probe pg_drill >/dev/null 2>&1 || return 1
  pg_probe wl_report_manifest_surfaces services.postgres >/dev/null 2>&1 && bk_probe pg_report >/dev/null 2>&1 || return 1
  j="$(pg_probe wl_services_json)"
  jq -e '.[0].postgres.backup | .mode == "pgbackrest" and .lastBackupOk == true and .lastDrillOk == true and (.lastBackupAt | type) == "string" and (.lastDrillAt | type) == "string"
    and (keys == ["lastArchiveError", "lastBackupAt", "lastBackupError", "lastBackupKind", "lastBackupOk", "lastDrillAt", "lastDrillError", "lastDrillOk", "mode", "running", "runningPct"])
    and .running == null and .runningPct == null
    and .lastBackupError == null and .lastDrillError == null and .lastArchiveError == null' <<<"$j" >/dev/null || { echo "$j"; r=1; }
  ! grep -rq "R2-Secret" "$TMP/pg/state/services" --include='*.json' || r=1
  bk_off
  bk_probe pg_report >/dev/null 2>&1
  jq -e '.[0].postgres.backup.mode == "off"' <<<"$(pg_probe wl_services_json)" >/dev/null || r=1
  pg_probe wl_unreport_manifest_surfaces services.postgres >/dev/null 2>&1
  return "$r"
}
bk_t_secrets() {
  local d="$TMP/pg" out
  bk_secrets; bk_on; rm -f "$d/state/secrets-node-owned.list"
  bk_probe pg_ensure_secrets >/dev/null 2>&1
  ! grep -q PGBACKREST "$d/state/secrets-node-owned.list" || return 1
  printf 'PGBACKREST_R2_ACCESS_KEY_ID="k"\nPGBACKREST_R2_SECRET_ACCESS_KEY="s"\nPGBACKREST_CIPHER_PASS="c"\n' > "$d/dec"
  # shellcheck disable=SC2016
  out="$(pg_probe eval 'source "$AW_ROOT/lib/control.sh"; sec_set() { printf "SET %s\n" "$1"; }; control_import_secrets "$AW_STATE/../dec"' 2>&1)"
  rm -f "$d/dec"; bk_off
  [[ "$(grep -c '^SET PGBACKREST_' <<<"$out")" == 3 ]]
}
bk_t_updates() {
  local out
  mkdir -p "$TMP/bkps"
  cat > "$TMP/bkps/podman" <<'EOS'
#!/bin/sh
[ "$1" = ps ] && printf '[{"Names":["alwayswork-postgres"],"Image":"localhost/alwayswork-postgres:16-pgbackrest2.59.3-0123abcd","Labels":{"alwayswork":"true","dev.alwayswork.base_image":"%s"}}]\n' "$BR_BASE"
exit 0
EOS
  chmod +x "$TMP/bkps/podman"
  pg_cfg '.capabilities.enabled = ["core", "runtime.podman", "services.postgres"]'
  out="$(BR_BASE=docker.io/library/postgres:16 PATH="$TMP/bkps:$PATH" AW_TEST_PODMAN=1 pg_probe wl_image_updates_json)"
  [[ "$out" == "[]" ]] || { echo "$out"; return 1; }
  out="$(BR_BASE=docker.io/library/postgres:15 PATH="$TMP/bkps:$PATH" AW_TEST_PODMAN=1 pg_probe wl_image_updates_json)"
  jq -e '.[0] | .workload == "postgres" and .running == "docker.io/library/postgres:15" and .want == "docker.io/library/postgres:16"' <<<"$out" >/dev/null
}
if have yq; then
  check "pg backup: off by default; endpoint/bucket/path/region/retention validated, defaults /<node>/<db>, auto, 14 days, 12 monthly" 'bk_t_config'
  check "pg backup: without the three group secrets preflight and apply refuse by name, and write no unit, config or archive_command" 'bk_t_refuse'
  check "pg backup: pgbackrest.conf is 0600 in a 0700 dir — R2 s3 path-style, aes-256-cbc, repo1 14-day time retention, repo2 monthly count 12; unchanged is not rewritten" 'bk_t_conf'
  check "pg backup: the unit runs the node-built image with archiving on (archive_command, archive_timeout 60, wal_level replica) only while backup=pgbackrest, never a secret" 'bk_t_unit'
  check "pg backup: timers — full Sun 03:00, diff Mon..Sat 03:00, monthly 1st 05:00, drill Wed 04:00; removed with backup=off" 'bk_t_timers'
  check "pg backup: on-demand and scheduled runs exec pgBackRest in the live container and record aw.facts; failures are redacted" 'bk_t_backup'
  check "pg backup: the restore drill uses a scratch container, never the live data dir, checks disk first, records the result" 'bk_t_drill'
  check "pg backup: PITR restore needs --yes, moves the data dir aside (never deletes), restores to the target, verifies; a failure puts it back" 'bk_t_restore'
  check "pg: the stanza is retried past an archive-lock race, and owed from the heartbeat at most every ten minutes" 'bk_t_stanza_retry'
  check "pg: seed_from restores an empty node from another's backup as a standby, never twice; standby=off is its own repository again" 'bk_t_seed'
  check "pg backup: heartbeat postgres.backup = {mode, lastBackupAt/Ok, lastDrillAt/Ok}, no secret" 'bk_t_heartbeat'
  check "pg backup: PGBACKREST_* are group secrets — imported from deliveries, never node-owned" 'bk_t_secrets'
  check "pg backup: image tracking compares the node-built image's base with the wanted one" 'bk_t_updates'
  check "pg backup: aw.status keeps its columns and appends last_backup_kind / errors" \
    'grep -A3 "AS updated_at,$" "$ROOT/capabilities/services.postgres/postgres.sh" | grep -q "AS last_backup_kind,"'
  check "aw service <action> postgres resolves to the postgres operations" \
    'pg_probe eval "declare -F postgres_status postgres_backup postgres_restore postgres_drill postgres_psql" >/dev/null'
fi
check "heartbeat carries expose.services when present" 'grep -q "expose:{services:" "$ROOT/lib/control.sh" && grep -q "wl_services_json" "$ROOT/lib/control.sh"'
check "service command is dispatched and documented" 'grep -q "|service|" "$ROOT/bin/alwayswork" && run_aw help && has "service <action> <id>"'

echo "== packages (SYSTEM_SPEC §9) =="
cat > "$TMP/pkg-probe.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"; shift 2
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml"
export AW_SYSTEMD_DIR="$D/systemd" AW_OS_RELEASE="$D/../os/arch" AW_TEST=1
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_SYSTEMD_DIR" "$D/bin"
# A podman stub: `image exists` says yes, everything else is a no-op.
printf '#!/bin/sh\ncase "$1 $2" in "image exists") exit 0;; esac\nexit 0\n' > "$D/bin/podman"; chmod +x "$D/bin/podman"
printf '#!/bin/sh\nexit 0\n' > "$D/bin/systemctl"; chmod +x "$D/bin/systemctl"
export PATH="$D/bin:$PATH"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/hardware.sh"
source "$ROOT/lib/distro.sh"; source "$ROOT/lib/engine.sh"; source "$ROOT/lib/secrets.sh"
source "$ROOT/lib/capability.sh"; source "$ROOT/lib/apps.sh"; source "$ROOT/lib/workload.sh"; source "$ROOT/lib/packages.sh"
DRY_RUN=0
sec_get() { [[ "$1" == N8N_ENCRYPTION_KEY ]] && printf "test-only-key"; }
[[ -f "$AW_CONFIG" ]] || cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
"$@"
EOS
pkg_probe() { bash "$TMP/pkg-probe.sh" "$ROOT" "$TMP/pkg" "$@"; }
rm -rf "$TMP/pkg"; PKGD="$TMP/pkg/state/packages"
N8N='{"packages":[{"id":"pkg_1","name":"n8n","version":"1.80.0","kind":"oci","digest":"sha256:aaaa","manifest":{"kind":"oci","image":"docker.io/n8nio/n8n:1.80.0","env":{"GENERIC_TIMEZONE":"UTC"},"secrets":["N8N_ENCRYPTION_KEY"],"publish":[{"port":5678,"protocol":"http"},{"port":5679,"containerPort":80,"protocol":"tcp"}],"volumes":[{"name":"data","path":"/home/node/.n8n"}],"resources":{"memoryMb":2048,"cpu":1.5},"network":"full","readOnly":false,"health":["wget","-q","-O-","http://127.0.0.1:5678/healthz"],"user":"1000:1000","args":["start"]}}]}'
if have yq; then
check "packages: an oci package becomes a workload unit on the contract" \
  'pkg_probe pkg_apply_from_delivery "$N8N" >/dev/null 2>&1 && u="$TMP/pkg/systemd/alwayswork-n8n.service" && grep -q -- "--userns=auto" "$u" && grep -q -- "--publish 127.0.0.1:5678:5678" "$u" && grep -q -- "--publish 127.0.0.1:5679:80" "$u" && grep -q -- "--volume $TMP/pkg/state/workloads/n8n/data:/home/node/.n8n:U" "$u" && grep -q -- "--memory 2048m" "$u" && grep -q -- "--cpus 1.5" "$u" && grep -q -- "--user 1000:1000" "$u" && grep -q -- "--health-cmd" "$u" && grep -q "healthz" "$u" && grep -q -- "--env-file $TMP/pkg/etc/pkg-n8n.env" "$u" && grep -q "docker.io/n8nio/n8n:1.80.0 start" "$u"'
check "packages: env file is 0600 with plain env and the required secret" \
  'f="$TMP/pkg/etc/pkg-n8n.env" && [[ "$(stat -c %a "$f")" == "600" ]] && grep -qx "GENERIC_TIMEZONE=UTC" "$f" && grep -qx "N8N_ENCRYPTION_KEY=test-only-key" "$f"'
check "packages: every published port is a surface with kind and name" \
  '[[ "$(pkg_probe wl_services_json | jq -r "sort_by(.port) | map(.id + \" \" + .workload + \" \" + .kind) | join(\",\")")" == "n8n n8n http,n8n-5679 n8n tcp" ]]'
check "packages: every published port is reported as a service" \
  '[[ "$(pkg_probe wl_services_json | jq -r "sort_by(.port) | map(.id + \" \" + .protocol + \" \" + (.port|tostring)) | join(\",\")")" == "n8n http 5678,n8n-5679 tcp 5679" ]]'
check "packages: installed state carries the digest for the heartbeat" \
  '[[ "$(pkg_probe pkg_reports_json | jq -r ".[0] | .name + \" \" + .version + \" \" + .digest + \" \" + .state")" == "n8n 1.80.0 sha256:aaaa installed" ]]'
check "packages: same digest again is a no-op (unit unchanged)" \
  'b="$(sha256sum "$TMP/pkg/systemd/alwayswork-n8n.service")" && pkg_probe pkg_apply_from_delivery "$N8N" >/dev/null 2>&1 && [[ "$(sha256sum "$TMP/pkg/systemd/alwayswork-n8n.service")" == "$b" ]]'
check "packages: a bad image is recorded as failed, never installed, and does not abort the delivery" \
  'pkg_probe pkg_apply_from_delivery "{\"packages\":[{\"name\":\"evil\",\"version\":\"1\",\"kind\":\"oci\",\"digest\":\"sha256:bb\",\"manifest\":{\"kind\":\"oci\",\"image\":\"x; rm -rf /\"}},$(jq -c ".packages[0]" <<<"$N8N")]}" >/dev/null 2>&1 && [[ "$(jq -r .state "$PKGD/installed/evil.json")" == "failed" ]] && [[ ! -e "$TMP/pkg/systemd/alwayswork-evil.service" ]] && [[ -e "$PKGD/installed/n8n.json" ]]'
check "packages: a capability package enables the capability with its config" \
  'pkg_probe pkg_apply_from_delivery "{\"packages\":[{\"name\":\"pg\",\"version\":\"16\",\"kind\":\"capability\",\"digest\":\"sha256:cc\",\"manifest\":{\"kind\":\"capability\",\"capability\":\"services.postgres\",\"config\":{\"version\":\"16\",\"port\":\"5433\"}}}]}" >/dev/null 2>&1 && [[ "$(yq -r ".capabilities.config.services.postgres.port" "$TMP/pkg/etc/worker.yaml")" == "5433" ]] && yq -r ".capabilities.enabled[]" "$TMP/pkg/etc/worker.yaml" | grep -qx services.postgres'
check "packages: dropped from desired state -> unit and service report removed, data kept" \
  '[[ ! -e "$TMP/pkg/systemd/alwayswork-n8n.service" && ! -e "$PKGD/installed/n8n.json" && -d "$TMP/pkg/state/workloads/n8n/data" ]] && [[ "$(pkg_probe wl_services_json)" == "[]" ]]'
check "packages: a bad package name is ignored" \
  'pkg_probe pkg_apply_from_delivery "{\"packages\":[{\"name\":\"../x\",\"version\":\"1\",\"kind\":\"oci\",\"manifest\":{}}]}" >/dev/null 2>&1 && [[ ! -e "$PKGD/installed/../x.json" ]]'
check "packages: a distro package adds catalog apps to the desired list" \
  'pkg_probe pkg_apply_from_delivery "{\"packages\":[{\"name\":\"tools\",\"version\":\"1\",\"kind\":\"distro\",\"digest\":\"sha256:dd\",\"manifest\":{\"kind\":\"distro\",\"apps\":[\"ripgrep\"]}}]}" >/dev/null 2>&1 && yq -r ".capabilities.apps[]" "$TMP/pkg/etc/worker.yaml" | grep -qx ripgrep && [[ "$(jq -r .state "$PKGD/installed/tools.json")" == "installed" ]]'
fi
check "workloads: heartbeat inventory from podman ps + stats (both stats formats)" \
  'mkdir -p "$TMP/wlbin" && cp "$ROOT/tests/fixtures/podman-stub.sh" "$TMP/wlbin/podman" && chmod +x "$TMP/wlbin/podman" && out="$(PATH="$TMP/wlbin:$PATH" AW_TEST_PODMAN=1 bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/workload.sh\"; wl_workloads_json")" && [[ "$(jq -r "map(.id + \":\" + .kind + \":\" + .state + \":\" + (.health // \"-\")) | join(\" \")" <<<"$out")" == "dsh:harness:running:healthy n8n:package:exited:- postgres:service:running:unhealthy" ]] && [[ "$(jq -r ".[0] | (.cpuPct|tostring) + \" \" + (.memMb|tostring) + \" \" + (.memLimitMb|tostring)" <<<"$out")" == "12.35 700 4096" ]] && [[ "$(jq -r ".[2].cpuPct" <<<"$out")" == "0.75" ]]'
check "workloads: no podman -> empty list, never an error" '[[ "$(PATH=/nonexistent:/usr/bin:/bin bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/workload.sh\"; wl_workloads_json")" == "[]" ]]'
check "samples: the watch flag is fresh for 90 s, then nobody is watching" \
  'd="$TMP/smp"; rm -rf "$d"; mkdir -p "$d"; AW_STATE="$d" bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/control.sh\"; control_watch_set true; control_watching || exit 1; echo \$(( \$(date +%s) - 100 )) > \"\$AW_STATE/watching\"; ! control_watching || exit 1; control_watch_set false; [[ ! -e \"\$AW_STATE/watching\" ]]"'
check "samples: a sample carries node load and per-workload usage only" \
  'out="$(PATH="$TMP/wlbin:$PATH" AW_TEST_PODMAN=1 bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/workload.sh\"; source \"$ROOT/lib/control.sh\"; control_sample_json")" && [[ "$(jq -r ".node.load1 | type" <<<"$out")" == "number" ]] && [[ "$(jq -r ".workloads | length" <<<"$out")" == "3" ]] && [[ "$(jq -r ".workloads[0] | keys | join(\",\")" <<<"$out")" == "cpuPct,id,memLimitMb,memMb,pids,state" ]] && [[ "$(jq -r ".workloads[0] | has(\"image\")" <<<"$out")" == "false" ]]'
check "packages: an empty installed dir reports [] exactly once (a doubled value breaks health --argjson)" \
  'mkdir -p "$PKGD/installed" && rm -f "$PKGD"/installed/*.json && [[ "$(pkg_probe pkg_reports_json)" == "[]" ]] && [[ "$(pkg_probe pkg_reports_json | wc -c)" == "2" ]]'
check "packages: bridge allows the packages op" 'grep -q "packages)" "$ROOT/lib/objectives.sh"'
check "aw config get/set exists and round-trips a boolean, a number and a string" \
  'rm -rf "$TMP/cfgt"; mkdir -p "$TMP/cfgt/etc" "$TMP/cfgt/state"; cp "$ROOT/config/defaults.yaml" "$TMP/cfgt/etc/worker.yaml"; c() { AW_ROOT="$ROOT" AW_ETC="$TMP/cfgt/etc" AW_STATE="$TMP/cfgt/state" AW_CONFIG="$TMP/cfgt/etc/worker.yaml" AW_TEST=1 bash "$AW" config "$@"; }; c set .updates.guard false >/dev/null && [[ "$(c get .updates.guard)" == "false" ]] && c set .updates.min_doctor_score 80 >/dev/null && [[ "$(c get .updates.min_doctor_score)" == "80" ]] && c set .updates.guard strict >/dev/null && [[ "$(c get .updates.guard)" == "strict" ]] && c show | grep -q "min_doctor_score: 80"'
check "packages: aw package is a command"        'grep -q "|package|" "$ROOT/bin/alwayswork" && [[ -f "$ROOT/commands/package.sh" ]]'

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
  check "update guard: refuses unattended (no controlling terminal, no SUDO_USER) without the lock; allows the agent's own installs" \
    '! setsid -w env -u SUDO_USER bash "$TMP/upd-probe.sh" "$ROOT" "$TMP/upd" upd_guard >/dev/null 2>&1 </dev/null && AW_PKG_GUARD_OK=1 setsid -w env -u SUDO_USER bash "$TMP/upd-probe.sh" "$ROOT" "$TMP/upd" upd_guard >/dev/null 2>&1 </dev/null'
  check "update guard: an operator (SUDO_USER, fds captured like a pacman hook) is let through; strict refuses even them" \
    'SUDO_USER=op setsid -w bash "$TMP/upd-probe.sh" "$ROOT" "$TMP/upd" upd_guard >/dev/null 2>&1 </dev/null && yq -i ".updates.guard = \"strict\"" "$TMP/upd/etc/worker.yaml" && ! SUDO_USER=op setsid -w bash "$TMP/upd-probe.sh" "$ROOT" "$TMP/upd" upd_guard >/dev/null 2>&1 </dev/null; yq -i "del(.updates.guard)" "$TMP/upd/etc/worker.yaml"'
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
  check "agent self-update: behind when the heartbeat's commit differs from COMMIT" \
    'rm -f "$TMP/upd/state/agent-target"; ! upd_probe upd_agent_behind && upd_probe upd_agent_note_target aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && upd_probe upd_agent_behind && upd_probe upd_agent_note_target "../evil" && [[ "$(cat "$TMP/upd/state/agent-target")" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] && [[ -z "$(upd_probe upd_agent_behind 2>&1)" ]]'
  check "agent self-update: the upgrade path fetches the control plane's own tarball and re-runs its installer in place" \
    'grep -q "x-aw-agent-commit" "$ROOT/lib/updates.sh" && grep -q "agent.tar.gz" "$ROOT/lib/updates.sh" && grep -q -- "--skip-deps --from" "$ROOT/lib/updates.sh"'
  check "heartbeat notes the shipped agent commit"  'grep -q "upd_agent_note_target" "$ROOT/lib/control.sh" && grep -q "agentOutdated" "$ROOT/lib/health.sh"'
  check "aw update: agent step runs before packages and can be skipped" \
    'grep -q "upd_agent_upgrade" "$ROOT/commands/update.sh" && grep -q -- "--no-agent" "$ROOT/commands/update.sh" && grep -q -- "--agent)" "$ROOT/commands/update.sh"'
  check "aw update accepts --yes after the command (what a rollout unit runs)" \
    'grep -q -- "--yes|-y)" "$ROOT/commands/update.sh" && ! run_aw --dry-run update --yes --no-agent 2>&1 | grep -q "unknown option"'
  check "rollout unit settles a process that died without a result" \
    'grep -q "ExecStopPost=/usr/local/bin/alwayswork update --settle" "$ROOT/lib/updates.sh" && printf "{\"rolloutId\":\"ro_dead\",\"state\":\"running\",\"summary\":\"update started\",\"at\":1}" > "$TMP/upd/state/update-result.json" && upd_probe upd_settle ro_dead exit-code 1 >/dev/null 2>&1 && [[ "$(jq -r .state "$TMP/upd/state/update-result.json")" == "failed" ]] && printf "{\"rolloutId\":\"ro_ok\",\"state\":\"ok\",\"summary\":\"x\",\"at\":1}" > "$TMP/upd/state/update-result.json" && upd_probe upd_settle ro_ok >/dev/null 2>&1 && [[ "$(jq -r .state "$TMP/upd/state/update-result.json")" == "ok" ]]'
  check "snapshot ids parse from snapper's CSV, and from 0.10+ tables with box-drawing separators" \
    'mkdir -p "$TMP/snapbin" && cat > "$TMP/snapbin/snapper" <<"EOS"
#!/bin/bash
if [[ "$1" == "--machine-readable" ]]; then printf "number,type\n0,single\n41,pre\n42,post\n43,single\n"; exit 0; fi
if [[ "$*" == *create* ]]; then echo 44; exit 0; fi
printf "  # │ Type   \n────┼────────\n  0 │ single \n 41 │ pre    \n 42 │ post   \n 43 │ single \n"
EOS
chmod +x "$TMP/snapbin/snapper" && [[ "$(PATH="$TMP/snapbin:$PATH" bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/config.sh\"; source \"$ROOT/lib/hardware.sh\"; source \"$ROOT/lib/snapshot.sh\"; hw_is_btrfs() { return 0; }; cfg_get() { echo root; }; snap_latest_id; DRY_RUN=0 snap_create x")" == $'"'"'43\n44'"'"' ]] && printf "#!/bin/bash\nif [[ \"\$1\" == \"--machine-readable\" ]]; then exit 1; fi; printf \"  # │ Type   \\n────┼────────\\n 41 │ pre    \\n 42 │ post   \\n\"\n" > "$TMP/snapbin/snapper" && [[ "$(PATH="$TMP/snapbin:$PATH" bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/config.sh\"; source \"$ROOT/lib/hardware.sh\"; source \"$ROOT/lib/snapshot.sh\"; hw_is_btrfs() { return 0; }; cfg_get() { echo root; }; snap_latest_id")" == "41" ]]'
  check "aw update --dry-run: snapshot, upgrade, gate, probation" \
    'run_aw --dry-run update && has "pre-update" && has "update gate: dry-run" && has "on probation"'
  check "core installs the guard hook and the boot check" \
    'run_aw --dry-run enable core && has "00-alwayswork-guard.hook" && has "alwayswork-boot-check.service"'
fi

echo "== tools.browser on the workload contract (SYSTEM_SPEC §12.5) =="
cat > "$TMP/br-probe.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"; shift 2
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml"
export AW_SYSTEMD_DIR="$D/systemd" AW_OS_RELEASE="$D/../os/arch" AW_TEST=1
export CAP_ID=tools.browser CAP_DIR="$ROOT/capabilities/tools.browser"
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_SYSTEMD_DIR"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/hardware.sh"
source "$ROOT/lib/distro.sh"; source "$ROOT/lib/engine.sh"; source "$ROOT/lib/secrets.sh"
source "$ROOT/lib/capability.sh"; source "$ROOT/lib/workload.sh"
source "$CAP_DIR/browser.sh"
DRY_RUN=0
[[ -f "$AW_CONFIG" ]] || cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
"$@"
EOS
br_probe() { bash "$TMP/br-probe.sh" "$ROOT" "$TMP/br" "$@"; }
rm -rf "$TMP/br"
if have yq; then
  check "browser: unit publishes noVNC to loopback, joins the node network, keeps the profile" \
    'br_probe br_write_unit >/dev/null 2>&1 && u="$TMP/br/systemd/alwayswork-browser.service" && grep -q -- "--publish 127.0.0.1:6080:6080" "$u" && grep -q -- "--network alwayswork" "$u" && grep -q -- "--volume $TMP/br/state/browser/profile:/profile:U" "$u" && grep -q -- "--shm-size 1g" "$u" && grep -q -- "--userns=auto" "$u" && grep -q -- "--health-cmd" "$u"'
  check "browser: reported as an http service with the noVNC path" \
    'br_probe wl_report_service browser "Agent browser" http 6080 "/vnc.html?autoconnect=1&resize=scale" >/dev/null 2>&1 && [[ "$(br_probe wl_services_json | jq -r ".[0].protocol + \" \" + .[0].path")" == "http /vnc.html?autoconnect=1&resize=scale" ]]'
  check "browser: start_url must be a URL"  'yq -i ".capabilities.config.tools.browser.start_url = \"javascript:alert(1)\"" "$TMP/br/etc/worker.yaml" && br_probe br_render_env >/dev/null 2>&1 && ! grep -q BROWSER_START_URL "$TMP/br/etc/browser.env" && yq -i "del(.capabilities.config.tools.browser)" "$TMP/br/etc/worker.yaml"'
  check "browser: dry-run enable renders the unit" 'run_aw --dry-run enable tools.browser && has "alwayswork-browser.service" && has "agent browser ready"'
  check "harness env gets BROWSER_CDP_URL when the browser is enabled" \
    'yq -i ".capabilities.enabled += [\"tools.browser\"]" "$TMP/dsc/etc/worker.yaml" && dsc_probe dsc_render_env >/dev/null 2>&1 && grep -q "^BROWSER_CDP_URL=http://alwayswork-browser:9222$" "$TMP/dsc/etc/dsh.env"'
  check "workloads join the alwayswork network by default; none isolates" \
    'grep -q -- "--network alwayswork" "$TMP/dsc/systemd/alwayswork-dsh.service" || dsc_probe dsc_write_unit >/dev/null 2>&1 && grep -q -- "--network alwayswork" "$TMP/dsc/systemd/alwayswork-dsh.service"'
fi
check "browser image: chromium with CDP, noVNC, unprivileged user" 'grep -q "remote-debugging-port" "$ROOT/capabilities/tools.browser/entrypoint.sh" && grep -q "websockify" "$ROOT/capabilities/tools.browser/entrypoint.sh" && grep -q "^USER browser" "$ROOT/capabilities/tools.browser/Containerfile"'
check "runtime.podman creates the node network" 'grep -q "podman network create alwayswork" "$ROOT/capabilities/runtime.podman/install.sh"'
check "image workflow builds the browser too"   'grep -q "alwayswork-browser" "$ROOT/.github/workflows/image.yml"'

echo "== objectives and the host bridge (SYSTEM_SPEC §5.5) =="
cat > "$TMP/obj-probe.sh" <<'EOS'
set -u
ROOT="$1"; D="$2"; shift 2
export AW_ROOT="$ROOT" AW_ETC="$D/etc" AW_STATE="$D/state" AW_LOG_DIR="$D/log" AW_CONFIG="$D/etc/worker.yaml" AW_TEST=1
mkdir -p "$AW_ETC" "$AW_STATE"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/objectives.sh"
DRY_RUN=0
# The bridge shells out to bin/alwayswork; point it at a stub that echoes its argv.
if [[ -n "${STUB_AW:-}" ]]; then AW_ROOT="$D/stubroot"; mkdir -p "$AW_ROOT/bin"; printf '#!/bin/sh\necho "aw $*"\n' > "$AW_ROOT/bin/alwayswork"; chmod +x "$AW_ROOT/bin/alwayswork"; fi
"$@"
EOS
obj_probe() { bash "$TMP/obj-probe.sh" "$ROOT" "$TMP/obj" "$@"; }
rm -rf "$TMP/obj"; OBJD="$TMP/obj/state/workspaces/dsh/.alwayswork"
check "objectives: a delivered objective lands in the harness workspace" \
  'obj_probe obj_apply_from_delivery "{\"objectives\":[{\"id\":\"obj_abcd1\",\"text\":\"run doctor\",\"timeoutSec\":600,\"createdAt\":1}]}" >/dev/null 2>&1 && [[ "$(jq -r .text "$OBJD/objectives/obj_abcd1.json")" == "run doctor" && "$(jq -r .state "$OBJD/objectives/obj_abcd1.json")" == "pending" ]]'
check "objectives: a bad id is ignored"   'obj_probe obj_apply_from_delivery "{\"objectives\":[{\"id\":\"../evil\",\"text\":\"x\"}]}" >/dev/null 2>&1 && [[ ! -e "$OBJD/objectives/../evil.json" ]] && [[ "$(ls "$OBJD/objectives" | wc -l)" == "0" ]]'
check "objectives: the harness result is reported on heartbeat" \
  'obj_probe obj_apply_from_delivery "{\"objectives\":[{\"id\":\"obj_abcd1\",\"text\":\"run doctor\",\"timeoutSec\":600,\"createdAt\":1}]}" >/dev/null 2>&1 && printf "{\"state\":\"done\",\"summary\":\"doctor 92\"}" > "$OBJD/objectives/obj_abcd1.result.json" && [[ "$(obj_probe obj_reports_json | jq -r ".[0].id + \" \" + .[0].state + \" \" + .[0].summary")" == "obj_abcd1 done doctor 92" ]]'
check "objectives: closed on the control plane -> retired from the workspace" \
  'obj_probe obj_apply_from_delivery "{\"objectives\":[]}" >/dev/null 2>&1 && [[ ! -e "$OBJD/objectives/obj_abcd1.json" && ! -e "$OBJD/objectives/obj_abcd1.result.json" ]]'
check "bridge: serves an allowlisted op, result in results/, request consumed" \
  'mkdir -p "$OBJD/requests" && printf "{\"op\":\"service.status\",\"args\":[\"postgres\"]}" > "$OBJD/requests/req1.json" && STUB_AW=1 obj_probe obj_bridge_serve_once >/dev/null 2>&1 && [[ "$(jq -r .output "$OBJD/results/req1.json")" == "aw service status postgres" && "$(jq -r .ok "$OBJD/results/req1.json")" == "true" ]] && [[ ! -e "$OBJD/requests/req1.json" ]]'
check "bridge: unknown op and bad service id are refused" \
  'printf "{\"op\":\"shell\",\"args\":[\"rm -rf /\"]}" > "$OBJD/requests/req2.json"; printf "{\"op\":\"service.logs\",\"args\":[\"pg; id\"]}" > "$OBJD/requests/req3.json"; STUB_AW=1 obj_probe obj_bridge_serve_once >/dev/null 2>&1 && [[ "$(jq -r .ok "$OBJD/results/req2.json")" == "false" && "$(jq -r .ok "$OBJD/results/req3.json")" == "false" ]] && grep -q "unknown op" "$OBJD/results/req2.json"'
check "bridge: path unit watches the request dir; agents.dsh installs it" 'grep -q "DirectoryNotEmpty=" "$ROOT/lib/objectives.sh" && grep -q "obj_install_units" "$ROOT/capabilities/agents.dsh/install.sh"'
check "heartbeat carries objectives when present" 'grep -q "objectives:\$o" "$ROOT/lib/control.sh" && grep -q "obj_apply_from_delivery" "$ROOT/lib/control.sh"'
check "bridge command dispatched"               'grep -q "|bridge|" "$ROOT/bin/alwayswork"'

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
cfg_list()         { printf 'core\n'; }
pkg_apply_from_delivery() { return 0; }
upd_apply_from_delivery() { return 0; }
obj_apply_from_delivery() { return 0; }
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
check "doctor survives checkupdates exiting 2 (no pending updates) and still writes its score" \
  'mkdir -p "$TMP/dbin" && printf "#!/bin/sh\nexit 2\n" > "$TMP/dbin/checkupdates" && chmod +x "$TMP/dbin/checkupdates" && rm -rf "$TMP/doc" && mkdir -p "$TMP/doc/etc" "$TMP/doc/state" && cp "$ROOT/config/defaults.yaml" "$TMP/doc/etc/worker.yaml" && PATH="$TMP/dbin:$PATH" AW_ROOT="$ROOT" AW_ETC="$TMP/doc/etc" AW_STATE="$TMP/doc/state" AW_CONFIG="$TMP/doc/etc/worker.yaml" AW_TEST=1 NO_COLOR=1 bash "$AW" doctor > "$TMP/doc/out" 2>&1; grep -q "system is up to date" "$TMP/doc/out" && grep -q "score" "$TMP/doc/out" && [[ "$(jq -r .score "$TMP/doc/state/doctor.json")" =~ ^[0-9]+$ ]]'
check "doctor names a pam_faillock lockout (looks like a changed password from outside)" \
  'mkdir -p "$TMP/flbin" && printf "#!/bin/sh\nprintf \"%%s:\\nWhen Type Source Valid\\n2026-09-19 21:36:12 SVC polkit-1 V\\n2026-09-19 21:36:13 SVC polkit-1 V\\n2026-09-19 21:36:22 SVC polkit-1 V\\n\" \"\$2\"\n" > "$TMP/flbin/faillock" && chmod +x "$TMP/flbin/faillock" && PATH="$TMP/flbin:$PATH" AW_ROOT="$ROOT" AW_ETC="$TMP/doc/etc" AW_STATE="$TMP/doc/state" AW_CONFIG="$TMP/doc/etc/worker.yaml" AW_TEST=1 NO_COLOR=1 bash "$AW" doctor > "$TMP/doc/out2" 2>&1; grep -q "locked by pam_faillock (3 recent failures)" "$TMP/doc/out2"'
check "doctor reads ufw's default policy from status verbose (plain status never prints it)" \
  'grep -q "ufw status verbose" "$ROOT/commands/doctor.sh" && grep -q "DEFAULT_INPUT_POLICY" "$ROOT/commands/doctor.sh"'
check "doctor records its FAIL/WARN findings for the heartbeat" \
  '[[ "$(jq -r ".findings | type" "$TMP/doc/state/doctor.json" 2>/dev/null)" == "array" ]] && jq -e ".findings | all(test(\"^(FAIL|WARN) \"))" "$TMP/doc/state/doctor.json" >/dev/null'

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
check "health json is a single line"    '[[ "$(wc -l < "$TMP/health.out")" == "1" ]] || { cat "$TMP/health.err" >&2; false; }'
check "health has agentVersion"         'jq -e ".agentVersion | type == \"string\"" "$TMP/health.out" >/dev/null'
check "health has uptimeSec"            'jq -e ".uptimeSec | type == \"number\"" "$TMP/health.out" >/dev/null'
check "health has clockSynced"          'jq -e ".clockSynced | type == \"boolean\"" "$TMP/health.out" >/dev/null'
check "health engine is typed"          'jq -e ".engine.kind == \"none\" and .engine.state == \"inactive\"" "$TMP/health.out" >/dev/null'
check "health agent is typed"           'jq -e ".agent.kind == \"none\" and (.agent.up | type == \"boolean\")" "$TMP/health.out" >/dev/null'
check "health reads the doctor cache"   'jq -e ".doctorScore == 88 and .doctorAt == 1789776000000" "$TMP/health.out" >/dev/null'
check "health disk pct is 0-100"        'jq -e "(.diskRootUsedPct // 0) >= 0 and (.diskRootUsedPct // 0) <= 100" "$TMP/health.out" >/dev/null'
check "health uses only spec field names" \
  '[[ -z "$(jq -r "keys[]" "$TMP/health.out" | grep -vxE "agentVersion|os|kernel|arch|uptimeSec|load1|cpuCount|memTotalMb|memUsedMb|diskRootTotalGb|diskRootUsedPct|tempC|engine|agent|tunnelUp|webUiUp|sshPolicy|doctorScore|doctorAt|capabilities|lanIp|clockSynced|update|cpuModel|gpus|virt|diskRootFreeGb|doctorFindings|agentCommit|agentOutdated|updateProtocol|apps|workloads|packages|listeners")" ]]'
check "health probes stay quiet"        '[[ ! -s "$TMP/health.err" ]]'
check "gpus json is one value even when lspci finds nothing (pipefail)" \
  '[[ "$(bash -c "set -o pipefail; AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/hardware.sh\"; lspci() { echo \"00:00.0 Host bridge: none\"; }; nvidia-smi() { false; }; export -f lspci; hw_gpus_json")" == "[]" ]]'
check "health carries inventory (cpu model, gpus, virt, free disk)" 'jq -e ".cpuModel | type == \"string\"" "$TMP/health.out" >/dev/null && jq -e ".gpus | type == \"array\"" "$TMP/health.out" >/dev/null && jq -e ".diskRootFreeGb | type == \"number\"" "$TMP/health.out" >/dev/null'
check "tick sends typed health"         'grep -q "health:\$h" "$ROOT/lib/control.sh" && ! grep -q "health:{}" "$ROOT/lib/control.sh"'
check "doctor caches its score"         'grep -q "health_doctor_record" "$ROOT/commands/doctor.sh"'

echo "== listener audit =="
# health.listeners (issue #16): a stubbed ss and podman on PATH; the stubs
# answer only under AW_TEST_PODMAN (podman) — ss is always the stub here.
mkdir -p "$TMP/lsbin"
cp "$ROOT/tests/fixtures/ss-stub.sh" "$TMP/lsbin/ss"; cp "$ROOT/tests/fixtures/ip-stub.sh" "$TMP/lsbin/ip"; cp "$ROOT/tests/fixtures/podman-stub.sh" "$TMP/lsbin/podman"; chmod +x "$TMP/lsbin/"*
ls_probe() { PATH="$TMP/lsbin:$PATH" bash -c "AW_ROOT=\"$ROOT\"; source \"$ROOT/lib/core.sh\"; source \"$ROOT/lib/health.sh\"; $1"; }
LS_ALL="$(AW_TEST_PODMAN=1 ls_probe health_listeners_json)"
check "listeners: v4/v6/wildcard binds reported with process names" \
  '[[ "$(jq -r "map(.proto + \" \" + .addr + \" \" + (.port|tostring) + \" \" + .process) | join(\",\")" <<<"$LS_ALL")" == "tcp 0.0.0.0 22 sshd,tcp 192.168.1.20 8443 my app,tcp :: 22 sshd,udp * 5353 avahi-daemon,udp fe80::1 546 " ]]'
check "listeners: entries are typed {proto, addr, port:int, process}" \
  'jq -e "all(.[]; (keys == [\"addr\",\"port\",\"process\",\"proto\"]) and (.port|type) == \"number\" and (.proto == \"tcp\" or .proto == \"udp\"))" <<<"$LS_ALL" >/dev/null'
check "listeners: brackets and %scope suffixes are stripped" \
  '! grep -qE "[][%]" <<<"$(jq -r ".[].addr" <<<"$LS_ALL")"'
check "listeners: loopback (127/8, ::1, v4-mapped 127) is excluded" \
  '! jq -e "any(.[]; .addr | test(\"^127\\\\.|^::1$|ffff:127\"))" <<<"$LS_ALL" >/dev/null'
check "listeners: the alwayswork podman network (v4 and v6 subnets) is excluded" \
  '! jq -e "any(.[]; .addr == \"10.89.0.1\" or .addr == \"fd00:aa::1\")" <<<"$LS_ALL" >/dev/null'
check "listeners: without the network inspect, container-network binds are reported" \
  '[[ "$(ls_probe health_listeners_json | jq -r "[.[] | select(.addr == \"10.89.0.1\" or .addr == \"fd00:aa::1\")] | length")" == "2" ]]'
check "listeners: binds on awinfra0 and CloudflareWARP (v4 and v6) are excluded" \
  '! jq -e "any(.[]; .addr == \"198.18.130.7\" or .addr == \"100.96.0.12\" or (.addr | startswith(\"2606:4700\")))" <<<"$LS_ALL" >/dev/null'
check "listeners: without awinfra0, its bind is reported (WARP still excluded)" \
  '[[ "$(IP_NO_AWINFRA=1 AW_TEST_PODMAN=1 ls_probe health_listeners_json | jq -r "[.[] | select(.addr == \"198.18.130.7\" or .addr == \"100.96.0.12\" or (.addr | startswith(\"2606:4700\"))) | .addr] | join(\",\")")" == "198.18.130.7" ]]'
check "listeners: without CloudflareWARP, its binds are reported (awinfra0 still excluded)" \
  '[[ "$(IP_NO_WARP=1 AW_TEST_PODMAN=1 ls_probe health_listeners_json | jq -r "[.[] | select(.addr == \"198.18.130.7\" or .addr == \"100.96.0.12\" or (.addr | startswith(\"2606:4700\")))] | length")" == "2" ]]'
check "listeners: wildcard binds stay reported with the private interfaces present" \
  'jq -e "any(.[]; .addr == \"0.0.0.0\") and any(.[]; .addr == \"::\")" <<<"$LS_ALL" >/dev/null'
check "listeners: the DHCP client socket (udp 68) is excluded" \
  '! jq -e "any(.[]; .port == 68)" <<<"$LS_ALL" >/dev/null'
check "listeners: non-LISTEN tcp states are ignored" \
  '[[ "$(jq "[.[] | select(.addr == \"192.168.1.20\" and .port == 22)] | length" <<<"$LS_ALL")" == "0" ]]'
check "listeners: capped at 32"   '[[ "$(SS_MODE=many ls_probe health_listeners_json | jq length)" == "32" ]]'
check "listeners: in the heartbeat, [] when ss ran and found nothing" \
  '[[ "$(SS_MODE=empty ls_probe "for l in distro config hardware engine firewall hardening secrets capability tunnel control; do source \"$ROOT/lib/\$l.sh\"; done; control_health_json" | jq -c .listeners)" == "[]" ]]'
check "listeners: in the heartbeat, carried when ss reports exposure" \
  '[[ "$(ls_probe "for l in distro config hardware engine firewall hardening secrets capability tunnel control; do source \"$ROOT/lib/\$l.sh\"; done; control_health_json" | jq -r ".listeners[0].process")" == "sshd" ]]'
check "listeners: field omitted when ss is unavailable" \
  'out="$(ls_probe "for l in distro config hardware engine firewall hardening secrets capability tunnel control; do source \"$ROOT/lib/\$l.sh\"; done; have() { [[ \$1 != ss ]] && command -v \"\$1\" >/dev/null 2>&1; }; control_health_json")" && jq -e . <<<"$out" >/dev/null && ! jq -e "has(\"listeners\")" <<<"$out" >/dev/null'
check "listeners: IPv4/IPv6 CIDR helpers" \
  'ls_probe "_health_in_cidr 10.89.0.7 10.89.0.0/24 && ! _health_in_cidr 10.89.1.7 10.89.0.0/24 && _health_in_cidr fd00:aa::5 fd00:aa::/64 && ! _health_in_cidr fd00:ab::5 fd00:aa::/64 && _health_in_cidr 10.1.2.3 10.0.0.0/9 && ! _health_in_cidr :: 10.0.0.0/8 && ! _health_in_cidr \"*\" 0.0.0.0/0 && [[ \$(_health_v6_hex ::ffff:1.2.3.4) == 00000000000000000000ffff01020304 ]]"'
# Only where doctor runs to completion (it wrote its score above): on BSD
# userland it stops at the GNU-only df probe before reaching this audit.
if [[ -s "$TMP/doc/state/doctor.json" ]]; then
  check "doctor: all listeners are ONE FAIL finding, recorded whole for the heartbeat" \
    'AW_TEST_PODMAN=1 AW_TEST_PODMAN=1 PATH="$TMP/lsbin:$PATH" AW_ROOT="$ROOT" AW_ETC="$TMP/doc/etc" AW_STATE="$TMP/doc/state" AW_CONFIG="$TMP/doc/etc/worker.yaml" AW_TEST=1 NO_COLOR=1 bash "$AW" doctor > "$TMP/doc/out3" 2>&1; [[ "$(grep -c "FAIL listening on" "$TMP/doc/out3")" == 1 ]] && [[ "$(jq -r "[.findings[] | select(startswith(\"FAIL listening on \"))] | .[]" "$TMP/doc/state/doctor.json")" == "FAIL listening on 0.0.0.0:22/tcp (sshd), 192.168.1.20:8443/tcp (my app), [::]:22/tcp (sshd), *:5353/udp (avahi-daemon), [fe80::1]:546/udp (unknown) — nodes accept no inbound connections" ]]'
  check "doctor: a long listener list is shortened (+N more) and keeps its explanation" \
    'SS_MODE=many AW_TEST_PODMAN=1 AW_TEST_PODMAN=1 PATH="$TMP/lsbin:$PATH" AW_ROOT="$ROOT" AW_ETC="$TMP/doc/etc" AW_STATE="$TMP/doc/state" AW_CONFIG="$TMP/doc/etc/worker.yaml" AW_TEST=1 NO_COLOR=1 bash "$AW" doctor > "$TMP/doc/out5" 2>&1; f="$(jq -r "[.findings[] | select(startswith(\"FAIL listening on \"))] | .[]" "$TMP/doc/state/doctor.json")" && [[ "$(grep -c . <<<"$f")" == 1 && "$f" == "FAIL listening on 0.0.0.0:9001/tcp (unknown), "*", +"*" more — nodes accept no inbound connections" ]]'
  check "doctor: no listeners passes" \
    'SS_MODE=empty AW_TEST_PODMAN=1 AW_TEST_PODMAN=1 PATH="$TMP/lsbin:$PATH" AW_ROOT="$ROOT" AW_ETC="$TMP/doc/etc" AW_STATE="$TMP/doc/state" AW_CONFIG="$TMP/doc/etc/worker.yaml" AW_TEST=1 NO_COLOR=1 bash "$AW" doctor > "$TMP/doc/out4" 2>&1; grep -q "PASS nothing listens outside loopback" "$TMP/doc/out4" && ! jq -e "any(.findings[]; startswith(\"FAIL listening\"))" "$TMP/doc/state/doctor.json" >/dev/null'
fi
if have yq; then
  check "status shows a listeners line" \
    'PATH="$TMP/lsbin:$PATH" run_aw status && has "listeners.*0.0.0.0:22/tcp (sshd), " && SS_MODE=empty PATH="$TMP/lsbin:$PATH" run_aw status && grep -qE "listeners +none" "$TMP/out"'
fi
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
check "workload reconciliation and argument boundary regressions" 'bash "$ROOT/tests/workload-lifecycle.sh"'
check "scoped node update regressions" 'bash "$ROOT/tests/node-updates.sh"'
check "infraAccess: awinfra0 + dedicated sshd via Access for Infrastructure" 'bash "$ROOT/tests/infra-access.sh" > "$TMP/infra.out" 2>&1 || { grep "FAIL" "$TMP/infra.out"; false; }'
printf 'passed: %s   failed: %s\n'  "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
