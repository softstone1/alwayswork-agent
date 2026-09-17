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

if have yq; then
  check "decommission dry-run writes nothing" 'run_aw --dry-run --yes decommission >/dev/null && [[ ! -e "$AW_STATE/decommission.json" ]]'
  check "decommission dry-run summarizes"     'run_aw --dry-run --yes decommission && has "decommissioned"'
  check "provision dry-run is a no-op"        'run_aw --dry-run provision >/dev/null && [[ ! -e "$AW_STATE/decommission.json" ]]'
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
  export PKGLOG="$TMP/sopspkglog" CURL_MARKER="$TMP/curl-marker" TMP
  : > "$PKGLOG"
  PATH="$TMP/sopsbin:/usr/bin:/bin" bash "$TMP/sops-probe.sh" "$1" "$2" > "$TMP/sops.out" 2>&1
}
shas() { grep -q "$1" "$TMP/sops.out"; }
check "sops present skips download" \
  'printf "#!/bin/sh\n" > "$TMP/sopsbin/sops"; chmod +x "$TMP/sopsbin/sops"; sops_probe "$ROOT" present && shas "sops present" && [[ ! -e "$TMP/curl-marker" ]]'
check "debian installs verified sops deb" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f222697a51e0a7081e3f3b" sops_probe "$ROOT" install && shas "sha256 verified" && grep -q "dpkg -i .*/sops_3.13.3_amd64.deb" "$PKGLOG" && shas "sops installed"'
check "debian refuses sops on checksum mismatch" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="deadbeef" sops_probe "$ROOT" install; rc=$?; [[ $rc -ne 0 ]] && shas "checksum mismatch"'
check "debian fails clearly when sops download fails" \
  'rm -f "$TMP/sopsbin/sops"; CURL_FAIL=1 sops_probe "$ROOT" install; rc=$?; [[ $rc -ne 0 ]] && shas "could not download sops"'
check "debian refuses sops on unknown arch" \
  'rm -f "$TMP/sopsbin/sops"; UNAME_M="riscv64" sops_probe "$ROOT" install; rc=$?; [[ $rc -ne 0 ]] && shas "no sops .deb for riscv64"'
check "debian retries sops install after fixing deps" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f222697a51e0a7081e3f3b" DPKG_FAIL_ONCE=1 sops_probe "$ROOT" install && grep -qx "apt-get install -f -y" "$PKGLOG" && [[ "$(grep -c "^dpkg -i" "$PKGLOG")" == "2" ]] && shas "sops installed"'
check "debian apt list excludes sops" \
  'rm -f "$TMP/sopsbin/sops"; SHA256_STUB="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f222697a51e0a7081e3f3b" sops_probe "$ROOT" deps && grep -qx "apt-get install -y git curl jq age restic ufw" "$PKGLOG" && ! grep -q "^apt-get.*sops" "$PKGLOG"'
check "arch pacman still installs sops from repos" \
  'sops_probe "$ROOT" archdeps && grep -qx "pacman -Syu --needed --noconfirm git curl jq age restic ufw sops" "$PKGLOG"'

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
