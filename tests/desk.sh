#!/usr/bin/env bash
# Developer desks (lib/desk.sh): the delivery's desk block, the One Client
# enrolment file, the time-boxed terminal sshd, the local veto, power left to
# the desktop, and the desk heartbeat fields. No host mutation: systemctl,
# sshd, ssh-keygen, warp-cli, pacman, loginctl, lsblk, findmnt and ufw are
# stubs on a temporary PATH; every path lives under $TMP.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

CA='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN3X1Z7VxX open-ssh-ca@cloudflareaccess.org'

S="$TMP/stubs"; mkdir -p "$S"
export CALLS="$TMP/calls" ACTIVE="$TMP/active"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$S/$1"; chmod +x "$S/$1"; }
stub systemctl '
quiet=0; args=(); for a in "$@"; do [[ "$a" == --quiet ]] && quiet=1 || args+=("$a"); done
case "${args[0]}" in
  is-active) [[ -f "$ACTIVE/${args[1]}" ]] ;;
  is-enabled) echo "${SLEEP_STATE:-enabled}" ;;
  restart|start) mkdir -p "$ACTIVE"; touch "$ACTIVE/${args[1]}" ;;
  stop) rm -f "$ACTIVE/${args[1]}" ;;
  show) echo sddm.service ;;
  *) exit 0 ;;
esac'
stub sshd 'exit 0'
stub ssh-keygen 'while [[ $# -gt 0 ]]; do [[ "$1" == -f ]] && { : > "$2"; : > "$2.pub"; }; shift; done'
stub warp-cli 'case "$*" in *--version*) echo "warp-cli 2026.8.2115.0";; *status*) echo "Status update: ${WARP_STATE:-Connected}";; esac'
stub pacman '[[ "$1" == -Q ]] && { echo "git 2.51.0-1"; echo "podman 5.6.1-1"; echo "cloudflare-warp-bin 2026.8.2115-1"; }; exit 0'
stub loginctl 'case "$1" in list-sessions) echo "2 1000 t1 seat0 tty2";; show-session) [[ "$*" == *Desktop* ]] && echo KDE || echo active;; esac'
stub findmnt 'echo "/dev/nvme0n1p2[/@]"'
stub lsblk 'printf "%s\n" ${LSBLK_TYPES:-part disk}'
stub ufw 'echo "Status: active"'
export PATH="$S:$PATH"

export AW_TEST=1 DRY_RUN=0 AW_ROOT="$ROOT"
export AW_ETC="$TMP/etc/alwayswork" AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log"
export AW_SYSTEMD_DIR="$TMP/systemd/system" AW_SSHD_BIN="$S/sshd" AW_WARP_MDM="$TMP/warp/mdm.xml"
export AW_CONFIG="$AW_ETC/worker.yaml"
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_SYSTEMD_DIR"
printf 'profile: desk\nagent:\n  user: t1\n' > "$AW_CONFIG"

libs() { source "$ROOT/lib/core.sh"; source "$ROOT/lib/distro.sh"; source "$ROOT/lib/config.sh"; source "$ROOT/lib/power.sh"; source "$ROOT/lib/desk.sh"; }
apply() { ( libs; desk_apply_from_delivery "$1" ) > "$TMP/out" 2>&1; }
now_ms() { printf '%s000' "$(date +%s)"; }
delivery() { # <until-ms|null> [grant] [user]
  local term=null
  [[ "$1" != null ]] && term="$(jq -nc --arg g "${2:-tg_abcdef123456}" --argjson u "$1" --arg ca "$CA" --arg user "${3:-t1}" \
    '{grantId:$g, until:$u, hostname:"always1-ssh.example.test", caPublicKey:$ca, principals:["dev"], user:$user}')"
  jq -nc --argjson t "$term" '{state:"approved", config:{configVersion:3}, desk:{user:"t1", organization:"anakut", terminal:$t}}'
}
UNIT="$AW_SYSTEMD_DIR/alwayswork-terminal-sshd.service"; CFG="$AW_ETC/terminal/sshd_config"
calls() { cat "$CALLS" 2>/dev/null; }

echo "== desk: delivery and Cloudflare One =="
check "a desk delivery applies"                 'apply "$(delivery null)"'
check "desk user and organization recorded"     '( libs; [[ "$(cfg_get .desk.user)" == t1 && "$(cfg_get .desk.organization)" == anakut ]] )'
check "without desk.warp the developer's own client is left alone" '[[ ! -e "$AW_WARP_MDM" ]] && ! calls | grep -q "restart warp-svc"'
printf 'profile: desk\nagent:\n  user: t1\ncapabilities:\n  enabled: [core, desk.base, desk.warp]\n' > "$AW_CONFIG"
check "with desk.warp the delivery applies"     'apply "$(delivery null)"'
check "One Client enrolment names the organization" 'grep -q "<string>anakut</string>" "$AW_WARP_MDM" && grep -q "<key>organization</key>" "$AW_WARP_MDM"'
check "warp-svc restarted on enrolment change"  'calls | grep -q "systemctl restart warp-svc"'
: > "$CALLS"
check "an unchanged enrolment restarts nothing" 'apply "$(delivery null)" && ! calls | grep -q "restart warp-svc"'
check "locked by default: switch_locked true, no auto-reconnect needed" 'grep -q "<true/>" "$AW_WARP_MDM" && grep -A1 "<key>switch_locked</key>" "$AW_WARP_MDM" | grep -q "<true/>" && grep -A1 "<key>auto_connect</key>" "$AW_WARP_MDM" | grep -q "<integer>0</integer>"'
check "unlocked by the group: switch free, back on after 15 minutes" 'apply "$(jq -c ".desk.warpLocked = false" <<<"$(delivery null)")" && grep -A1 "<key>switch_locked</key>" "$AW_WARP_MDM" | grep -q "<false/>" && grep -A1 "<key>auto_connect</key>" "$AW_WARP_MDM" | grep -q "<integer>15</integer>"'
check "locked again when the control plane says so"  'apply "$(delivery null)" && grep -A1 "<key>switch_locked</key>" "$AW_WARP_MDM" | grep -q "<true/>"'
check "no open grant: no terminal unit"         '[[ ! -f "$UNIT" ]]'
check "root is refused as the desk user"        '! apply "$(jq -c ".desk.user = \"root\"" <<<"$(delivery null)")"'

echo "== desk: terminal grant =="
UNTIL=$(( $(now_ms) + 1800000 ))
check "an open grant applies"                   'apply "$(delivery "$UNTIL")"'
check "sshd listens on loopback only, port 22"  '[[ "$(grep -c "^ListenAddress" "$CFG")" == 1 ]] && grep -qx "ListenAddress 127.0.0.1" "$CFG" && grep -qx "Port 22" "$CFG"'
check "certificates from the grant CA only"     'grep -qx "TrustedUserCAKeys $AW_ETC/terminal/ca.pub" "$CFG" && [[ "$(cat "$AW_ETC/terminal/ca.pub")" == "$CA" ]] && grep -qx "AuthorizedKeysFile none" "$CFG" && grep -qx "PasswordAuthentication no" "$CFG"'
check "one user, its principals, no root"       'grep -qx "AllowUsers t1" "$CFG" && grep -qx "PermitRootLogin no" "$CFG" && [[ "$(cat "$AW_ETC/terminal/principals/t1")" == dev ]] && [[ "$(ls "$AW_ETC/terminal/principals")" == t1 ]]'
check "no forwarding of any kind"               'grep -qx "AllowTcpForwarding no" "$CFG" && grep -qx "X11Forwarding no" "$CFG" && grep -qx "AllowAgentForwarding no" "$CFG" && grep -qx "PermitTunnel no" "$CFG"'
check "systemd enforces the deadline"           'secs=$(grep -oP "^RuntimeMaxSec=\K[0-9]+" "$UNIT") && (( secs > 1790 && secs <= 1800 )) && grep -qx "KillMode=control-group" "$UNIT" && grep -qx "Restart=no" "$UNIT"'
check "never enabled at boot"                   '! grep -q "^\[Install\]" "$UNIT" && ! calls | grep -q "systemctl enable alwayswork-terminal"'
check "unit started; state recorded"            '[[ -f "$ACTIVE/alwayswork-terminal-sshd.service" ]] && [[ "$(jq -r .grantId "$AW_STATE/terminal.json")" == tg_abcdef123456 ]]'
check "health reports the open grant"           '( libs; desk_terminal_json ) | jq -e ".open == true and .grantId == \"tg_abcdef123456\"" >/dev/null'
: > "$CALLS"
check "the same grant again restarts nothing"   'apply "$(delivery "$UNTIL")" && ! calls | grep -q "restart alwayswork-terminal"'
check "a grant for another user swaps principals" 'apply "$(delivery "$UNTIL" tg_second0000001 dev2)" && [[ "$(ls "$AW_ETC/terminal/principals")" == dev2 ]] && grep -qx "AllowUsers dev2" "$CFG"'

echo "== desk: closing =="
check "no terminal in the delivery closes it"   'apply "$(delivery null)" && [[ ! -f "$UNIT" && ! -f "$AW_STATE/terminal.json" && ! -e "$AW_ETC/terminal/ca.pub" && ! -d "$AW_ETC/terminal/principals" ]]'
check "sshd stopped"                            '[[ ! -f "$ACTIVE/alwayswork-terminal-sshd.service" ]]'
check "the host key is kept for the next grant" '[[ -f "$AW_ETC/terminal/ssh_host_ed25519_key" ]]'
check "an expired grant is closed, not opened"  'apply "$(delivery $(( $(now_ms) - 1000 )))" && [[ ! -f "$UNIT" ]]'
check "no desk block at all closes it"          'apply "$(delivery "$UNTIL")" && [[ -f "$UNIT" ]] && apply "{\"state\":\"approved\",\"config\":{}}" && [[ ! -f "$UNIT" ]]'
check "a malformed grant id is refused and closes (the delivery still applies)" 'apply "$(delivery "$UNTIL")" && apply "$(delivery "$UNTIL" "bad id")" && [[ ! -f "$UNIT" ]] && grep -q "malformed terminal grant" "$TMP/out"'
check "a non-OpenSSH CA is refused"             'apply "$(jq -c ".desk.terminal.caPublicKey = \"-----BEGIN\"" <<<"$(delivery "$UNTIL")")" && [[ ! -f "$UNIT" ]] && grep -q "not an OpenSSH public key" "$TMP/out"'
check "infra sshd on its /32 does not block the terminal" '( libs; ! AW_TEST_SS22="198.18.128.6:22" desk_loopback22_taken )'
check "a loopback or wildcard sshd does"           '( libs; AW_TEST_SS22="0.0.0.0:22" desk_loopback22_taken ) && ( libs; AW_TEST_SS22="127.0.0.1:22" desk_loopback22_taken ) && ( libs; AW_TEST_SS22="[::]:22" desk_loopback22_taken )'
check "a held port defers the terminal, the delivery applies, the tick opens it later" 'AW_TEST_SS22="0.0.0.0:22" apply "$(delivery "$UNTIL" tg_tick00000001)" && [[ ! -f "$UNIT" ]] && ( libs; desk_tick ) && [[ -f "$UNIT" ]]'
check "veto: closed at the desk stays closed"   'apply "$(delivery "$UNTIL" tg_veto00000001)" && printf "tg_veto00000001\n" > "$AW_STATE/terminal-veto" && apply "$(delivery "$UNTIL" tg_veto00000001)" && [[ ! -f "$UNIT" ]]'
check "veto: a new grant opens again"           'apply "$(delivery "$UNTIL" tg_new000000001)" && [[ -f "$UNIT" ]]'

echo "== desk: power, reporting =="
: > "$CALLS"
check "power_apply leaves a desk alone"         '( libs; power_apply ) >/dev/null 2>&1 && ! calls | grep -q "systemctl mask"'
check "power_audit has no finding on a desk"    '[[ -z "$( libs; power_audit )" ]]'
check "posture: firewall, unencrypted root, warp connected" '( libs; desk_posture_json ) | jq -e ".firewall == true and .diskEncrypted == false and .warp.installed and .warp.state == \"connected\" and .warp.org == \"anakut\"" >/dev/null'
check "posture: LUKS root is reported encrypted" '( export LSBLK_TYPES="part crypt disk"; libs; desk_posture_json ) | jq -e ".diskEncrypted == true" >/dev/null'
check "posture: unregistered client"            '( export WARP_STATE="Registration Missing"; libs; desk_posture_json ) | jq -e ".warp.state == \"unregistered\"" >/dev/null'
HOME_T1="$TMP/home/t1"; mkdir -p "$HOME_T1/.local/bin" "$HOME_T1/.local/share/claude/versions"
printf '#!/bin/sh\n' > "$HOME_T1/.local/share/claude/versions/2.1.310"; chmod +x "$HOME_T1/.local/share/claude/versions/2.1.310"
ln -s "$HOME_T1/.local/share/claude/versions/2.1.310" "$HOME_T1/.local/bin/claude"
printf '#!/bin/sh\necho "codex-cli 0.120.4"\n' > "$HOME_T1/.local/bin/codex"; chmod +x "$HOME_T1/.local/bin/codex"
mkdir -p "$HOME_T1/.local/lib/node_modules/@deepseek-ai/dsh/bin"; printf '{"name":"@deepseek-ai/dsh","version":"0.1.5"}' > "$HOME_T1/.local/lib/node_modules/@deepseek-ai/dsh/package.json"
printf '#!/bin/sh\n' > "$HOME_T1/.local/lib/node_modules/@deepseek-ai/dsh/bin/dsh.js"; chmod +x "$HOME_T1/.local/lib/node_modules/@deepseek-ai/dsh/bin/dsh.js"
ln -s "$HOME_T1/.local/lib/node_modules/@deepseek-ai/dsh/bin/dsh.js" "$HOME_T1/.local/bin/dsh"
stub getent "[[ \"\$1 \$2\" == 'passwd t1' ]] && echo 't1:x:1000:1000::$HOME_T1:/bin/bash'"
SW="$( libs; desk_software_json )"
check "software: native Claude Code version from its link" 'jq -e "any(.[]; .name == \"claude\" and .version == \"2.1.310\" and .category == \"agent\")" <<<"$SW" >/dev/null'
check "software: a standalone CLI by --version" 'jq -e "any(.[]; .name == \"codex\" and .version == \"0.120.4\")" <<<"$SW" >/dev/null'
check "software: an npm CLI from its package.json" 'jq -e "any(.[]; .name == \"dsh\" and .version == \"0.1.5\" and .source == \"npm\")" <<<"$SW" >/dev/null'
check "software: host packages with categories" 'jq -e "any(.[]; .name == \"git\" and .source == \"pacman\" and .category == \"dev\") and any(.[]; .name == \"cloudflare-warp-bin\" and .category == \"security\")" <<<"$SW" >/dev/null'
check "desk info: user, KDE, active session, display manager" '( libs; desk_info_json ) | jq -e ".user == \"t1\" and .desktop == \"KDE\" and .sessionActive and .displayManager == \"sddm\"" >/dev/null'
check "health fields only on desks"             '( libs; _HEALTH_ARGS=(); _HEALTH_FIELDS=""; _health_raw() { _HEALTH_FIELDS+="$1,"; }; desk_health_fields; [[ "$_HEALTH_FIELDS" == "desk,software,posture,terminal," ]] ) && ( printf "profile: worker\n" > "$AW_CONFIG"; libs; _HEALTH_FIELDS=""; _health_raw() { _HEALTH_FIELDS+="$1,"; }; desk_health_fields; [[ -z "$_HEALTH_FIELDS" ]] )'
printf 'profile: desk\nagent:\n  user: t1\n' > "$AW_CONFIG"
SYSF="$TMP/sysfs"; mkdir -p "$SYSF/proc" "$SYSF/sys/class/hwmon/hwmon2" "$SYSF/sys/class/net/enp1s0/statistics" "$SYSF/sys/class/net/enp1s0/device" "$SYSF/sys/class/drm/card1/device" "$SYSF/sys/class/drm/card1-HDMI-A-1" "$SYSF/sys/class/drm/card1-DP-1"
echo k10temp > "$SYSF/sys/class/hwmon/hwmon2/name"; echo 42250 > "$SYSF/sys/class/hwmon/hwmon2/temp1_input"
echo 37 > "$SYSF/sys/class/drm/card1/device/gpu_busy_percent"; echo connected > "$SYSF/sys/class/drm/card1-HDMI-A-1/status"; echo disconnected > "$SYSF/sys/class/drm/card1-DP-1/status"
printf 'SwapTotal: 2048000 kB\nSwapFree: 1024000 kB\n' > "$SYSF/proc/meminfo"
echo "cpu  100 0 100 800 0 0 0 0 0 0" > "$SYSF/proc/stat"; echo 1000 > "$SYSF/sys/class/net/enp1s0/statistics/rx_bytes"; echo 1000 > "$SYSF/sys/class/net/enp1s0/statistics/tx_bytes"
check "CPU temperature from hwmon when there is no thermal zone" '[[ "$( export AW_SYS="$SYSF"; source "$ROOT/lib/core.sh"; source "$ROOT/lib/health.sh"; health_cpu_temp_c )" == 42 ]]'
rm -f "$AW_STATE/desk-counters"
( export AW_SYS="$SYSF"; libs; desk_metrics_json ) > /dev/null
printf '%s 0 0 0 0\n' "$(( $(date +%s) - 10 ))" > "$AW_STATE/desk-counters"
echo "cpu  200 0 200 1600 0 0 0 0 0 0" > "$SYSF/proc/stat"; echo 126000 > "$SYSF/sys/class/net/enp1s0/statistics/rx_bytes"; echo 63500 > "$SYSF/sys/class/net/enp1s0/statistics/tx_bytes"
M="$( export AW_SYS="$SYSF"; libs; desk_metrics_json )"
check "desk metrics: CPU %, GPU busy, network rates, swap, displays" 'jq -e ".cpuPct == 20 and .gpuBusyPct == 37 and .netRxKbps == 100 and .netTxKbps == 50 and .swapUsedMb == 1000 and .displays == 1" <<<"$M" >/dev/null'
check "desk.base turns off LLMNR and mDNS responders" 'grep -q "LLMNR=no" "$ROOT/capabilities/desk.base/install.sh" && grep -q "MulticastDNS=no" "$ROOT/capabilities/desk.base/install.sh"'
check "doctor: unencrypted root is a desk finding" '( libs; desk_audit ) | grep -q "not encrypted"'
check "doctor: no One Client finding unless desk.warp is enabled" '( stub warp-cli "exit 1"; rm -f "$S/warp-cli"; libs; ! desk_audit | grep -q warp-cli )'

echo "       desk: passed $PASS failed $FAIL"
(( FAIL == 0 ))
