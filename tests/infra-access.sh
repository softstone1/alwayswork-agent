#!/usr/bin/env bash
# infraAccess (lib/infra.sh, issue #18): operator SSH through Cloudflare
# Access for Infrastructure. No host mutation: ip, systemctl, sshd,
# useradd, passwd, getent, ssh-keygen, networkctl and ss are stubs on a
# temporary PATH that record their argv; every path lives under $TMP.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

CA1='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN3X1Z7VxX/i8hJV0T+vmnB6REgsPvTX8PQVd61DTk9VlUYZL2bctK/r2ccv4+NM37xJCzsYHSRFA7MESDv1ujQ= cf-ca-1'
CA1_FP='SHA256:7RJyUUw9cLosJCbu73CoQkvO/QUizIlOReZnC2IUsCA'
CA2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKWBqy3fvpcbYAyuxCXZqWDpGPau0LhXG9P6N6LPWKUH cf-ca-2'

# --- stubs ------------------------------------------------------------------
S="$TMP/stubs"; mkdir -p "$S"
export CALLS="$TMP/calls" ACTIVE="$TMP/active" USERS="$TMP/users" IFACE_FLAG="$TMP/iface"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$S/$1"; chmod +x "$S/$1"; }
stub systemctl '
quiet=0; args=(); for a in "$@"; do [[ "$a" == --quiet ]] && quiet=1 || args+=("$a"); done
case "${args[0]}" in
  is-active) [[ "${args[1]}" == systemd-networkd.service ]] && { [[ "${NETWORKD:-0}" == 1 ]]; exit; }
             [[ -f "$ACTIVE/${args[1]}" ]] ;;
  restart|start)
    [[ "${args[1]}" == alwayswork-sshd.service && "${SSHD_START_FAIL:-0}" == 1 ]] && exit 1
    mkdir -p "$ACTIVE"; touch "$ACTIVE/${args[1]}" ;;
  disable) [[ "${args[1]}" == --now ]] && rm -f "$ACTIVE/${args[2]}"; exit 0 ;;
  *) exit 0 ;;
esac'
stub sshd '[[ "$1" == -t && "${SSHD_REJECT:-0}" == 1 ]] && exit 1; exit 0'
stub useradd 'echo "${@: -1}" >> "$USERS"'
stub passwd 'exit 0'
stub getent '[[ "$1" == passwd ]] && grep -qx "$2" "$USERS" 2>/dev/null'
stub ssh-keygen 'while [[ $# -gt 0 ]]; do [[ "$1" == -f ]] && { : > "$2"; : > "$2.pub"; }; shift; done'
stub networkctl 'exit 0'
stub ip '[[ "$1 $2 $3" == "link show awinfra0" ]] && { [[ -f "$IFACE_FLAG" ]]; exit; }; exit 0'
stub ss 'printf "%s\n" "${SS_OUT:-}"'
export PATH="$S:$PATH"

export AW_TEST=1 DRY_RUN=0 AW_ROOT="$ROOT"
export AW_ETC="$TMP/etc/alwayswork" AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log"
export AW_SYSTEMD_DIR="$TMP/systemd/system" AW_NETWORKD_DIR="$TMP/systemd/network"
export AW_SSHD_BIN="$S/sshd" AW_IP_BIN=/usr/sbin/ip
mkdir -p "$AW_ETC" "$AW_STATE"

# One scenario per subshell, with the libs freshly sourced.
apply() { # <delivery-json>
  ( source "$ROOT/lib/core.sh"; source "$ROOT/lib/infra.sh"
    infra_apply_from_delivery "$1" ) > "$TMP/out" 2>&1
}
delivery() { # <address> <ca> [users-json]
  jq -nc --arg a "$1" --arg c "$2" --argjson u "${3:-[\"aw\"]}" \
    '{state:"approved", config:{configVersion:1, infraAccess:{address:$a, caPublicKey:$c, users:$u}}}'
}
CFG="$AW_ETC/sshd_config"; UNIT="$AW_SYSTEMD_DIR/alwayswork-sshd.service"; NET="$AW_SYSTEMD_DIR/alwayswork-infra-net.service"
STATE="$AW_STATE/infra-access.json"
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : > "$CALLS"; }

echo "== infraAccess: converge =="
reset_calls
check "converge succeeds"                   'apply "$(delivery 198.18.130.7/32 "$CA1")"'
check "sshd_config: ListenAddress is only the /32" '[[ "$(grep -c "^ListenAddress" "$CFG")" == 1 ]] && grep -qx "ListenAddress 198.18.130.7" "$CFG" && grep -qx "Port 22" "$CFG"'
check "sshd_config: no password auth"       'grep -qx "PasswordAuthentication no" "$CFG" && grep -qx "KbdInteractiveAuthentication no" "$CFG" && grep -qx "PermitEmptyPasswords no" "$CFG"'
check "sshd_config: AuthorizedKeysFile none" 'grep -qx "AuthorizedKeysFile none" "$CFG"'
check "sshd_config: trusts only the CA"     'grep -qx "TrustedUserCAKeys $AW_ETC/ssh-ca.pub" "$CFG" && grep -qx "PubkeyAuthentication yes" "$CFG"'
check "sshd_config: root, users, forwarding" 'grep -qx "PermitRootLogin no" "$CFG" && grep -qx "AllowUsers aw" "$CFG" && grep -qx "AllowTcpForwarding no" "$CFG" && grep -qx "X11Forwarding no" "$CFG"'
check "sshd_config: limits and logging"     'grep -qx "MaxAuthTries 3" "$CFG" && grep -qx "LoginGraceTime 20" "$CFG" && grep -qx "ClientAliveInterval 60" "$CFG" && grep -qx "LogLevel VERBOSE" "$CFG" && grep -qx "UsePAM yes" "$CFG"'
check "sshd_config: host key under etc/alwayswork/ssh" 'grep -qx "HostKey $AW_ETC/ssh/ssh_host_ed25519_key" "$CFG" && [[ -f "$AW_ETC/ssh/ssh_host_ed25519_key" ]]'
check "CA written verbatim"                 '[[ "$(cat "$AW_ETC/ssh-ca.pub")" == "$CA1" ]]'
check "config validated with sshd -t first" 'calls | grep -q "^sshd -t -f $CFG.new"'
check "separate unit runs sshd -D -f"       'grep -q "^ExecStart=$S/sshd -D -f $CFG$" "$UNIT" && grep -q "^ExecStartPre=$S/sshd -t -f $CFG$" "$UNIT"'
check "distro sshd is never touched"        '! calls | grep -Eq "systemctl .*(^| )(ssh|sshd)(\.service)?( |$)"'
check "oneshot interface unit (no networkd)" 'grep -q "ip link add awinfra0 type dummy" "$NET" && grep -q "ip addr replace 198.18.130.7/32 dev awinfra0" "$NET" && grep -q "WantedBy=multi-user.target" "$NET"'
check "interface unit enabled and started"  'calls | grep -q "systemctl enable alwayswork-infra-net.service" && calls | grep -q "systemctl restart alwayswork-infra-net.service"'
check "sshd unit enabled and started"       'calls | grep -q "systemctl enable alwayswork-sshd.service" && calls | grep -q "systemctl restart alwayswork-sshd.service"'
check "user created with a locked password" 'calls | grep -q "^useradd -m -s /bin/bash aw$" && calls | grep -q "^passwd -l aw$"'
check "state: address, fingerprint, active" '[[ "$(jq -r "[.address,.caFingerprint,.sshd] | join(\" \")" "$STATE")" == "198.18.130.7/32 $CA1_FP active" ]]'
check "no firewall opening for 22"          '! calls | grep -q "^ufw"'
check "health reports public facts only" \
  '( source "$ROOT/lib/core.sh"; source "$ROOT/lib/infra.sh"; infra_health_json ) > "$TMP/h" && [[ "$(jq -c . "$TMP/h")" == "{\"address\":\"198.18.130.7/32\",\"sshd\":\"active\",\"caFingerprint\":\"$CA1_FP\"}" ]]'

echo "== infraAccess: idempotent re-apply =="
cp "$CFG" "$TMP/cfg1"; reset_calls
check "re-apply succeeds"                   'apply "$(delivery 198.18.130.7/32 "$CA1")"'
check "re-apply changes nothing"            'cmp -s "$CFG" "$TMP/cfg1" && ! calls | grep -Eq "restart|reload|useradd|daemon-reload|ssh-keygen"'
check "re-apply says already current"       'grep -q "already current" "$TMP/out"'

echo "== infraAccess: CA change =="
reset_calls
check "CA change applies"                   'apply "$(delivery 198.18.130.7/32 "$CA2")"'
check "CA file rewritten"                   '[[ "$(cat "$AW_ETC/ssh-ca.pub")" == "$CA2" ]]'
check "CA change reloads sshd"              'calls | grep -q "systemctl reload alwayswork-sshd.service"'
check "CA change keeps the config"          'cmp -s "$CFG" "$TMP/cfg1"'

echo "== infraAccess: invalid input is rejected =="
cp "$CFG" "$TMP/cfg2"; reset_calls
for a in 198.18.127.1/32 198.18.144.1/32 10.255.0.1/32 198.18.130.7/24 198.18.130.7 198.18.130.07/32 "198.18.130.7/32;rm" ""; do
  check "address '$a' refused, state kept"  'apply "$(delivery "$a" "$CA2")" && grep -q "not a /32 inside 198.18.128.0/20" "$TMP/out" && cmp -s "$CFG" "$TMP/cfg2" && [[ ! -s "$CALLS" ]]'
done
check "multi-line CA refused"               'apply "$(delivery 198.18.130.7/32 "$CA1"$'"'"'\n'"'"'"$CA2")" && grep -q "caPublicKey is not" "$TMP/out" && [[ "$(cat "$AW_ETC/ssh-ca.pub")" == "$CA2" ]]'
check "garbage CA refused"                  'apply "$(delivery 198.18.130.7/32 "ssh-ed25519 notbase64!!")" && grep -q "caPublicKey is not" "$TMP/out"'
check "CA type/blob mismatch refused"       'apply "$(delivery 198.18.130.7/32 "ssh-ed25519 ${CA1#* }")" && grep -q "caPublicKey is not" "$TMP/out"'
check "root user refused"                   'apply "$(delivery 198.18.130.7/32 "$CA2" "[\"root\"]")" && grep -q "invalid name" "$TMP/out"'
check "bad user name refused"               'apply "$(delivery 198.18.130.7/32 "$CA2" "[\"a b\"]")" && grep -q "invalid name" "$TMP/out"'
check "empty users refused"                 'apply "$(delivery 198.18.130.7/32 "$CA2" "[]")" && grep -q "1-16 users" "$TMP/out"'
check "nothing changed by rejected input"   'cmp -s "$CFG" "$TMP/cfg2" && [[ ! -s "$CALLS" ]]'

echo "== infraAccess: sshd -t rejects the candidate =="
reset_calls
check "rejected candidate is not fatal"     'SSHD_REJECT=1 apply "$(delivery 198.18.131.9/32 "$CA2" "[\"aw\",\"ops\"]")"'
check "live config kept on rejection"       'cmp -s "$CFG" "$TMP/cfg2" && [[ ! -f "$CFG.new" ]] && grep -q "rejected by sshd -t" "$TMP/out"'
check "interface and users untouched on rejection" 'grep -q "198.18.130.7/32" "$NET" && ! calls | grep -q "^useradd" && jq -e ".address == \"198.18.130.7/32\"" "$STATE" >/dev/null'
check "no restart on rejection"             '! calls | grep -Eq "systemctl (reload|restart) alwayswork-sshd"'
check "health says failed"                  '( source "$ROOT/lib/core.sh"; source "$ROOT/lib/infra.sh"; infra_health_json ) | jq -e ".sshd == \"failed\"" >/dev/null'

echo "== infraAccess: address and users change =="
reset_calls
check "new address applies"                 'apply "$(delivery 198.18.131.9/32 "$CA2" "[\"aw\",\"ops\",\"aw\"]")"'
check "ListenAddress follows"               'grep -qx "ListenAddress 198.18.131.9" "$CFG" && [[ "$(grep -c "^ListenAddress" "$CFG")" == 1 ]]'
check "users deduplicated in AllowUsers"    'grep -qx "AllowUsers aw ops" "$CFG" && calls | grep -q "^useradd -m -s /bin/bash ops$" && ! calls | grep -q "^useradd -m -s /bin/bash aw$"'
check "interface unit rewritten + restarted" 'grep -q "198.18.131.9/32" "$NET" && calls | grep -q "systemctl restart alwayswork-infra-net.service"'
check "health back to active"               '( source "$ROOT/lib/core.sh"; source "$ROOT/lib/infra.sh"; infra_health_json ) | jq -e ".sshd == \"active\" and .address == \"198.18.131.9/32\"" >/dev/null'

echo "== infraAccess: doctor binding check =="
doctor_infra() { # SS_OUT -> prints PASS/FAIL lines of the infra block
  ( source "$ROOT/lib/core.sh"; source "$ROOT/lib/infra.sh"
    _dpass() { echo "PASS $1"; }; _dfail() { echo "FAIL $1"; }; _dwarn() { echo "WARN $1"; }
    eval "_doctor_infra() {
$(sed -n '/# --- infra ssh/,/# --- secrets/p' "$ROOT/commands/doctor.sh" | sed '$d')
}"; _doctor_infra
  ) 2>/dev/null
}
L_INFRA='LISTEN 0 128 198.18.131.9:22 0.0.0.0:* users:(("sshd",pid=10,fd=3))'
L_ANY='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=11,fd=3))'
L_LO='LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:(("sshd",pid=12,fd=3))'
check "doctor PASS: sshd only on awinfra0"  'SS_OUT="$L_INFRA" doctor_infra | grep -q "^PASS sshd bound only to awinfra0"'
check "doctor FAIL: sshd also on 0.0.0.0"   'SS_OUT="$L_INFRA"$'"'"'\n'"'"'"$L_ANY" doctor_infra | grep -q "^FAIL sshd listens on 0.0.0.0:22"'
check "doctor FAIL: sshd also on loopback"  'SS_OUT="$L_INFRA"$'"'"'\n'"'"'"$L_LO" doctor_infra | grep -q "^FAIL sshd listens on 127.0.0.1:22"'
check "doctor FAIL: infra sshd not listening" 'SS_OUT="" doctor_infra | grep -q "^FAIL infra sshd is not listening"'

echo "== infraAccess: networkd mode =="
reset_calls
check "networkd: converge"                  'NETWORKD=1 apply "$(delivery 198.18.131.9/32 "$CA2" "[\"aw\",\"ops\"]")"'
check "networkd: .netdev/.network written"  'grep -qx "Kind=dummy" "$AW_NETWORKD_DIR/50-awinfra0.netdev" && grep -qx "Address=198.18.131.9/32" "$AW_NETWORKD_DIR/50-awinfra0.network" && grep -qx "RequiredForOnline=no" "$AW_NETWORKD_DIR/50-awinfra0.network"'
check "networkd: oneshot unit removed"      '[[ ! -f "$NET" ]] && calls | grep -q "^networkctl reload"'
check "networkd: sshd unit ordered after networkd" 'grep -q "^After=network.target systemd-networkd.service" "$UNIT"'

echo "== infraAccess: removal =="
touch "$IFACE_FLAG"; reset_calls
check "absent infraAccess removes it all"   'apply "{\"state\":\"approved\",\"config\":{\"configVersion\":2}}"'
check "units, config, CA, keys, state gone" '[[ ! -f "$UNIT" && ! -f "$NET" && ! -f "$CFG" && ! -f "$AW_ETC/ssh-ca.pub" && ! -f "$AW_ETC/ssh/ssh_host_ed25519_key" && ! -f "$STATE" ]]'
check "networkd files gone"                 '[[ ! -f "$AW_NETWORKD_DIR/50-awinfra0.netdev" && ! -f "$AW_NETWORKD_DIR/50-awinfra0.network" ]]'
check "service stopped, interface deleted"  'calls | grep -q "systemctl disable --now alwayswork-sshd.service" && calls | grep -q "^ip link del awinfra0"'
check "users are kept"                      '! calls | grep -q "userdel"'
check "health reports off"                  '( source "$ROOT/lib/core.sh"; source "$ROOT/lib/infra.sh"; infra_health_json ) | jq -e ". == {sshd:\"off\"}" >/dev/null'
rm -f "$IFACE_FLAG"; reset_calls
check "null infraAccess on a clean node is a no-op" 'apply "{\"state\":\"approved\",\"config\":{\"configVersion\":3,\"infraAccess\":null}}" && [[ ! -s "$CALLS" ]]'

echo "== infraAccess: sshd fails to start =="
reset_calls
check "start failure is retryable (rc 1)"   '! SSHD_START_FAIL=1 apply "$(delivery 198.18.128.1/32 "$CA1")"'
check "start failure reported as failed"    'jq -e ".sshd == \"failed\"" "$STATE" >/dev/null'

echo "== infraAccess: wiring =="
check "cli sources lib/infra.sh"            'grep -q "lib/infra.sh" "$ROOT/bin/alwayswork"'
check "delivery applies infraAccess"        'grep -q "infra_apply_from_delivery" "$ROOT/lib/control.sh"'
check "heartbeat carries health.infraAccess" 'grep -q "_health_raw infraAccess" "$ROOT/lib/health.sh"'
check "status prints an infra ssh line"     'grep -q "infra ssh" "$ROOT/commands/status.sh"'

printf 'infra-access passed: %s   failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
