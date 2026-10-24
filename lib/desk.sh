# shellcheck shell=bash
# alwayswork · developer desks (control plane docs/DESK.md).
#
# A desk is a developer's own workstation that is also a node: a person signs
# in at the desktop, and the agent keeps it managed and reported. Compared
# with a headless node it differs in exactly these ways:
#
#   - power is left to the desktop (no masked sleep, no logind overrides);
#   - the Cloudflare One Client (warp-svc) is enrolled into the operator's
#     Zero Trust organization for the developer's own traffic;
#   - the agentic CLIs live in the developer's home, per user;
#   - a remote terminal exists only inside a time-boxed grant delivered by
#     the control plane: a dedicated sshd on 127.0.0.1:22 (the tunnel's only
#     SSH origin) that trusts the grant's short-lived-certificate CA, admits
#     one UNIX user, and is stopped by systemd at the grant's deadline even if
#     the control plane is never heard from again;
#   - the heartbeat carries the desk's session, posture and key software.
#
# The contract, from the signed delivery:
#   desk: { user, organization, terminal: null | { grantId, until (unix ms),
#           hostname, caPublicKey, principals[], user } }

DESK_TERMINAL_UNIT="alwayswork-terminal-sshd.service"
DESK_WARP_MDM="${AW_WARP_MDM:-/var/lib/cloudflare-warp/mdm.xml}"

desk_mode() { [[ "$(cfg_get '.profile' '' 2>/dev/null)" == "desk" ]]; }

# The developer: the delivered desk user, else the user who installed the agent.
desk_user() {
  local u; u="$(cfg_get '.desk.user' '' 2>/dev/null)"
  [[ -n "$u" ]] || u="$(cfg_get '.agent.user' '' 2>/dev/null)"
  [[ "$u" == "root" ]] && u=""
  printf '%s' "$u"
}

desk_user_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }

desk_terminal_dir()   { printf '%s\n' "$AW_ETC/terminal"; }
desk_terminal_state() { printf '%s\n' "$AW_STATE/terminal.json"; }
desk_systemd_dir()    { printf '%s\n' "${AW_SYSTEMD_DIR:-/etc/systemd/system}"; }
desk_now_ms()         { printf '%s000\n' "$(date +%s)"; }

# --- delivery -------------------------------------------------------------------

# desk_apply_from_delivery <delivery-json> — record who the desk is for and
# which organization the One Client joins, then converge the terminal. A
# delivery without a desk block closes any terminal (the node left the desk
# role, or the control plane stopped sending it).
desk_apply_from_delivery() {
  local json="$1" user org
  if ! jq -e '.desk | type == "object"' >/dev/null 2>&1 <<<"$json"; then
    desk_terminal_close "no desk block in the delivery"
    return 0
  fi
  user="$(jq -r '.desk.user // ""' <<<"$json")"
  org="$(jq -r '.desk.organization // ""' <<<"$json")"
  if [[ -n "$user" ]]; then
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != "root" ]] || { warn "desk: refusing desk user '$user'"; return 1; }
    cfg_set_str '.desk.user' "$user"
  fi
  if [[ -n "$org" && "$org" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    cfg_set_str '.desk.organization' "$org"
    desk_warp_enrol "$org" || warn "desk: Cloudflare One Client enrolment is not configured yet"
  fi
  desk_terminal_apply "$json"
}

# --- Cloudflare One Client ------------------------------------------------------

# desk_warp_render_mdm <organization> — the managed-deployment file warp-svc
# reads: the developer signs in with their identity in the browser, and the
# device joins this organization only. No secret is involved.
desk_warp_render_mdm() {
  cat <<EOF
<dict>
  <!-- managed by alwayswork (desk) -->
  <key>organization</key>
  <string>$1</string>
  <key>auto_connect</key>
  <integer>1</integer>
  <key>onboarding</key>
  <false/>
</dict>
EOF
}

desk_warp_enrol() {
  local org="$1" want have=""
  have warp-cli || [[ "${AW_TEST:-0}" == "1" ]] || return 1
  want="$(desk_warp_render_mdm "$org")"
  [[ -f "$DESK_WARP_MDM" ]] && have="$(cat "$DESK_WARP_MDM" 2>/dev/null)"
  [[ "$have" == "$want" ]] && return 0
  ensure_dir "$(dirname "$DESK_WARP_MDM")"
  printf '%s\n' "$want" | aw_write "$DESK_WARP_MDM"
  run chmod 0644 "$DESK_WARP_MDM"
  log "desk: Cloudflare One Client set to organization '$org' (the developer signs in once in the browser)"
  run systemctl restart warp-svc 2>/dev/null || true
}

desk_warp_json() {
  local installed=false state="unknown" version="" out org
  org="$(cfg_get '.desk.organization' '' 2>/dev/null)"
  if have warp-cli; then
    installed=true
    version="$(timeout 5 warp-cli --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)"
    out="$(timeout 5 warp-cli --accept-tos status 2>/dev/null | tr 'A-Z' 'a-z')"
    case "$out" in
      *"registration missing"*|*unregistered*) state="unregistered" ;;
      *disconnected*) state="disconnected" ;;
      *connecting*) state="connecting" ;;
      *connected*) state="connected" ;;
    esac
  fi
  jq -nc --argjson i "$installed" --arg s "$state" --arg v "$version" --arg o "$org" \
    '{installed:$i} + (if $i then {state:$s} else {} end) + (if $v != "" then {version:$v} else {} end) + (if $o != "" then {org:$o} else {} end)'
}

# --- terminal grants -----------------------------------------------------------

# desk_terminal_render_config <user> <principals-dir> <ca-file> <hostkey>
desk_terminal_render_config() {
  cat <<EOF
# managed by alwayswork (desk terminal grant) — rewritten on every delivery; do not edit.
# Reachable only through the node's Cloudflare Tunnel (<node>-ssh.<base> ->
# ssh://127.0.0.1:22) behind the grant's Cloudflare Access application. The
# only credential is a short-lived certificate from that application's CA.
ListenAddress 127.0.0.1
Port 22
AddressFamily inet
HostKey $4
PidFile /run/alwayswork-terminal-sshd.pid

PubkeyAuthentication yes
TrustedUserCAKeys $3
AuthorizedKeysFile none
AuthorizedPrincipalsFile $2/%u
PasswordAuthentication no
KbdInteractiveAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
UsePAM yes
AllowUsers $1

X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 60
ClientAliveCountMax 3
LogLevel VERBOSE
SyslogFacility AUTH
PrintMotd no
EOF
}

# desk_terminal_render_unit <config> <seconds-left> — systemd stops the unit
# (and every session in its cgroup) after RuntimeMaxSec: the deadline holds
# on the node's own clock. Never enabled: a reboot never reopens a grant;
# only a fresh delivery with a future deadline does.
desk_terminal_render_unit() {
  local sshd; sshd="${AW_SSHD_BIN:-$(command -v sshd 2>/dev/null || echo /usr/bin/sshd)}"
  cat <<EOF
# managed by alwayswork (desk terminal grant)
[Unit]
Description=alwayswork desk terminal (time-boxed grant, loopback only)
After=network.target

[Service]
Type=simple
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
ExecStartPre=$sshd -t -f $1
ExecStart=$sshd -D -f $1
KillMode=control-group
RuntimeMaxSec=$2
Restart=no
EOF
}

# desk_terminal_apply <delivery-json>
desk_terminal_apply() {
  local json="$1" t gid until user ca now left dir cfg unit principals changed=0
  t="$(jq -c '.desk.terminal // null' <<<"$json")"
  if [[ "$t" == "null" ]]; then desk_terminal_close "no open grant"; return 0; fi
  gid="$(jq -r '.grantId // ""' <<<"$t")"; until="$(jq -r '.until // 0' <<<"$t")"
  user="$(jq -r '.user // ""' <<<"$t")"; ca="$(jq -r '.caPublicKey // ""' <<<"$t")"
  now="$(desk_now_ms)"
  if [[ ! "$gid" =~ ^tg_[A-Za-z0-9_-]{4,40}$ || ! "$until" =~ ^[0-9]+$ ]]; then warn "desk: malformed terminal grant; closing"; desk_terminal_close "malformed"; return 1; fi
  if (( until <= now )); then desk_terminal_close "grant $gid expired"; return 0; fi
  # Closed at the desk (aw desk terminal-close): the developer's veto holds for this grant.
  if [[ "$(cat "$AW_STATE/terminal-veto" 2>/dev/null)" == "$gid" ]]; then desk_terminal_close "grant $gid closed at the desk"; return 0; fi
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != "root" ]] || { warn "desk: refusing terminal user '$user'"; desk_terminal_close "bad user"; return 1; }
  getent passwd "$user" >/dev/null 2>&1 || [[ "${AW_TEST:-0}" == "1" ]] || { warn "desk: terminal user '$user' does not exist on this desk"; return 1; }
  [[ "$ca" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+\ [A-Za-z0-9+/=]+ ]] || { warn "desk: refusing a terminal CA that is not an OpenSSH public key"; desk_terminal_close "bad CA"; return 1; }
  principals="$(jq -r '(.principals // [])[] | select(test("^[a-z0-9._-]{1,64}$"))' <<<"$t")"
  [[ -n "$principals" ]] || { warn "desk: terminal grant names no usable principal"; desk_terminal_close "no principal"; return 1; }
  if [[ "${AW_TEST:-0}" != "1" ]] && ss -Htln 'sport = :22' 2>/dev/null | grep -q . && ! systemctl is-active --quiet "$DESK_TERMINAL_UNIT" 2>/dev/null; then
    warn "desk: port 22 on this desk is held by another sshd; the terminal waits until it is off (the lockdown stops it)"
    return 1
  fi

  dir="$(desk_terminal_dir)"; ensure_dir "$dir/principals"; run chmod 0755 "$dir" "$dir/principals"
  if [[ ! -f "$dir/ssh_host_ed25519_key" ]]; then
    run ssh-keygen -q -t ed25519 -N '' -C "alwayswork-terminal@$(hostname 2>/dev/null || echo desk)" -f "$dir/ssh_host_ed25519_key" </dev/null >/dev/null 2>&1 \
      || { warn "desk: could not create the terminal host key"; return 1; }
  fi
  _desk_put() { local f="$1" body="$2"; if [[ "$(cat "$f" 2>/dev/null)" != "$body" ]]; then printf '%s\n' "$body" | aw_write "$f"; changed=1; fi; }
  _desk_put "$dir/ca.pub" "$ca"
  # Only the grant's user has a principals file: every other account has
  # none, so no certificate can log in as anyone else.
  local f; for f in "$dir"/principals/*; do [[ -e "$f" && "$(basename "$f")" != "$user" ]] && { run rm -f "$f"; changed=1; }; done
  _desk_put "$dir/principals/$user" "$principals"
  cfg="$dir/sshd_config"
  _desk_put "$cfg" "$(desk_terminal_render_config "$user" "$dir/principals" "$dir/ca.pub" "$dir/ssh_host_ed25519_key")"
  run chmod 0644 "$dir/ca.pub" "$dir/principals/$user" "$cfg"
  left=$(( (until - now) / 1000 )); (( left < 1 )) && left=1
  unit="$(desk_systemd_dir)/$DESK_TERMINAL_UNIT"
  local prev; prev="$(jq -r '.grantId // ""' "$(desk_terminal_state)" 2>/dev/null || true)"
  [[ "$prev" != "$gid" ]] && changed=1
  if (( changed )) || [[ ! -f "$unit" ]] || ! systemctl is-active --quiet "$DESK_TERMINAL_UNIT" 2>/dev/null; then
    desk_terminal_render_unit "$cfg" "$left" | aw_write "$unit"
    run systemctl daemon-reload
    run systemctl restart "$DESK_TERMINAL_UNIT" || { warn "desk: the terminal sshd did not start"; return 1; }
    log "desk: terminal open for $user until $(date -d "@$((until / 1000))" 2>/dev/null || echo "$until") (grant $gid)"
  fi
  jq -nc --arg g "$gid" --argjson u "$until" --arg user "$user" '{grantId:$g, until:$u, user:$user}' | aw_write "$(desk_terminal_state)"
}

# desk_terminal_close [why] — idempotent: stop the sshd (ending every session),
# remove its unit, CA and principals. The host key stays so a later grant
# presents the same identity.
desk_terminal_close() {
  local why="${1:-closed}" unit dir had=0
  unit="$(desk_systemd_dir)/$DESK_TERMINAL_UNIT"; dir="$(desk_terminal_dir)"
  [[ -f "$unit" || -f "$(desk_terminal_state)" ]] && had=1
  (( had )) || return 0
  run systemctl stop "$DESK_TERMINAL_UNIT" 2>/dev/null || true
  run rm -f "$unit" "$dir/ca.pub" "$dir/sshd_config" "$(desk_terminal_state)"
  run rm -rf "$dir/principals"
  run systemctl daemon-reload 2>/dev/null || true
  log "desk: terminal closed ($why)"
}

desk_terminal_json() {
  local st open=false
  st="$(cat "$(desk_terminal_state)" 2>/dev/null || true)"
  systemctl is-active --quiet "$DESK_TERMINAL_UNIT" 2>/dev/null && open=true
  [[ "${AW_TEST_TERMINAL_UP:-}" == "1" ]] && open=true
  if [[ -n "$st" ]] && jq -e . >/dev/null 2>&1 <<<"$st"; then
    jq -c --argjson o "$open" '{open:$o, grantId, until}' <<<"$st"
  else
    jq -nc --argjson o "$open" '{open:$o}'
  fi
}

# --- reporting ------------------------------------------------------------------

# desk_cached <name> <ttl-seconds> <fn> — reports that cost a few process
# spawns are refreshed at most every ttl, not on every heartbeat.
desk_cached() {
  local name="$1" ttl="$2" fn="$3" f age
  f="$AW_STATE/desk-$name.json"
  if [[ -f "$f" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if (( age < ttl )) && jq -e . >/dev/null 2>&1 <"$f"; then cat "$f"; return 0; fi
  fi
  local out; out="$("$fn" 2>/dev/null)"
  if jq -e . >/dev/null 2>&1 <<<"$out"; then printf '%s' "$out" | aw_write "$f" 2>/dev/null || true; printf '%s' "$out"
  else printf 'null'; fi
}

desk_info_json() {
  local user sid desktop="" dm="" active=false model fw
  user="$(desk_user)"
  if [[ -n "$user" ]] && have loginctl; then
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$user" '$3 == u {print $1}'); do
      local d st; d="$(loginctl show-session "$sid" -p Desktop --value 2>/dev/null)"; st="$(loginctl show-session "$sid" -p State --value 2>/dev/null)"
      [[ -n "$d" && -z "$desktop" ]] && desktop="$d"
      [[ "$st" == "active" ]] && active=true
    done
  fi
  dm="$(systemctl show display-manager -p Id --value 2>/dev/null | sed 's/\.service$//')"
  model="$(printf '%s %s' "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" | xargs 2>/dev/null)"
  fw="$(cat /sys/class/dmi/id/bios_version 2>/dev/null | head -c 120)"
  jq -nc --arg u "$user" --arg d "$desktop" --arg m "$dm" --argjson a "$active" --arg hm "$model" --arg fw "$fw" \
    '{sessionActive:$a} + (if $u != "" then {user:$u} else {} end) + (if $d != "" then {desktop:$d} else {} end)
     + (if $m != "" then {displayManager:$m} else {} end) + (if $hm != "" then {hostModel:$hm} else {} end) + (if $fw != "" then {firmware:$fw} else {} end)'
}

# Package name -> category, for the host packages a developer desk is judged by.
DESK_PKGS=(
  "git:dev" "github-cli:dev" "gh:dev" "base-devel:dev" "neovim:dev" "code:dev" "visual-studio-code-bin:dev" "zed:dev"
  "nodejs:runtime" "nodejs-lts-jod:runtime" "npm:runtime" "pnpm:runtime" "bun:runtime" "python:runtime" "python3:runtime" "go:runtime" "rust:runtime" "rustup:runtime"
  "podman:runtime" "docker:runtime" "cloudflared:security" "cloudflare-warp-bin:security" "cloudflare-warp:security" "ufw:security" "arch-audit:security"
  "firefox:desktop" "chromium:desktop" "google-chrome:desktop" "plasma-desktop:desktop" "gnome-shell:desktop"
)

# One semver-ish token out of a --version line.
_desk_ver() { grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([.-][0-9A-Za-z.]+)?' | head -n1; }

# desk_agent_cli <user> <home> <name> — where the developer's CLI is and its
# version, without trusting PATH: the user's own bin dirs first.
desk_agent_cli() {
  local user="$1" home="$2" name="$3" bin="" ver="" src="native" d
  for d in "$home/.local/bin" "$home/.$name/bin" "$home/.npm-global/bin" /usr/local/bin /usr/bin; do
    [[ -x "$d/$name" ]] && { bin="$d/$name"; break; }
  done
  [[ -n "$bin" ]] || return 0
  # Native Claude Code links to versions/<semver>; npm installs keep package.json.
  local real; real="$(readlink -f "$bin" 2>/dev/null)"
  if [[ "$real" =~ /versions/([0-9][0-9A-Za-z.+-]*)$ ]]; then ver="${BASH_REMATCH[1]}"
  elif [[ "$real" == */node_modules/* ]]; then
    # Walk up from the entry point to the package's own package.json.
    src="npm"; local pd; pd="$(dirname "$real")"
    while [[ "$pd" == */node_modules/* && ! -f "$pd/package.json" ]]; do pd="$(dirname "$pd")"; done
    ver="$(jq -r '.version // empty' "$pd/package.json" 2>/dev/null)"
  fi
  if [[ -z "$ver" ]]; then
    if [[ "${AW_TEST:-0}" == "1" || "$(id -u)" != "0" ]]; then ver="$(timeout 5 "$bin" --version 2>/dev/null | _desk_ver)"
    else ver="$(timeout 5 runuser -u "$user" -- "$bin" --version </dev/null 2>/dev/null | _desk_ver)"; fi
  fi
  [[ "$bin" == /usr/bin/* ]] && src="pacman"
  jq -nc --arg n "$name" --arg v "$ver" --arg s "$src" '{name:$n, source:$s, category:"agent"} + (if $v != "" then {version:$v} else {} end)'
}

desk_software_json() {
  local user home out=() e name cat ver
  user="$(desk_user)"; home="$([[ -n "$user" ]] && desk_user_home "$user")"
  if [[ -n "$home" ]]; then
    for name in claude codex opencode dsh gemini; do
      e="$(desk_agent_cli "$user" "$home" "$name")"; [[ -n "$e" ]] && out+=("$e")
    done
  fi
  if have pacman; then
    local names=(); for e in "${DESK_PKGS[@]}"; do names+=("${e%%:*}"); done
    while read -r name ver; do
      [[ -n "$name" ]] || continue
      cat="other"; for e in "${DESK_PKGS[@]}"; do [[ "${e%%:*}" == "$name" ]] && cat="${e#*:}"; done
      out+=("$(jq -nc --arg n "$name" --arg v "$ver" --arg c "$cat" '{name:$n, version:$v, source:"pacman", category:$c}')")
    done < <(pacman -Q "${names[@]}" 2>/dev/null)
  elif have dpkg-query; then
    for e in "${DESK_PKGS[@]}"; do
      name="${e%%:*}"; ver="$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null)" || continue
      [[ -n "$ver" ]] && out+=("$(jq -nc --arg n "$name" --arg v "$ver" --arg c "${e#*:}" '{name:$n, version:$v, source:"apt", category:$c}')")
    done
  fi
  if have flatpak; then
    while IFS=$'\t' read -r name ver; do
      [[ -n "$name" ]] && out+=("$(jq -nc --arg n "$name" --arg v "$ver" '{name:$n, source:"flatpak", category:"desktop"} + (if $v != "" then {version:$v} else {} end)')")
    done < <(flatpak list --app --columns=application,version 2>/dev/null | head -n 40)
  fi
  ((${#out[@]})) || { printf '[]'; return 0; }
  printf '%s\n' "${out[@]}" | jq -sc 'map(.name |= .[0:64] | if .version then .version |= .[0:64] else . end) | unique_by(.name) | .[0:128]'
}

desk_disk_encrypted() {
  local src; src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]$//')"
  [[ -n "$src" ]] || return 2
  lsblk -no TYPE -s "$src" 2>/dev/null | grep -qx crypt
}

desk_secure_boot() {
  local f; f="$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1)"
  [[ -n "$f" ]] || return 1
  [[ "$(od -An -t u1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')" == "1" ]]
}

desk_posture_json() {
  local enc=null sb=false fw=false guard=false last="" vuln=""
  if desk_disk_encrypted; then enc=true; elif [[ $? == 1 ]]; then enc=false; fi
  desk_secure_boot && sb=true
  if have ufw && timeout 5 ufw status 2>/dev/null | grep -q '^Status: active'; then fw=true; fi
  [[ -f /etc/pacman.d/hooks/00-alwayswork-guard.hook || -f /etc/apt/apt.conf.d/99alwayswork-guard ]] && guard=true
  if [[ -r /var/log/pacman.log ]]; then
    local ts; ts="$(grep -F 'starting full system upgrade' /var/log/pacman.log 2>/dev/null | tail -n1 | grep -oE '^\[[^]]+\]' | tr -d '[]')"
    [[ -n "$ts" ]] && last="$(date -d "$ts" +%s 2>/dev/null)"
  fi
  if have arch-audit; then vuln="$(timeout 20 arch-audit -q 2>/dev/null | grep -c . || true)"; fi
  jq -nc --argjson e "$enc" --argjson sb "$sb" --argjson fw "$fw" --argjson g "$guard" --arg last "$last" --arg vuln "$vuln" --argjson warp "$(desk_warp_json)" \
    '{secureBoot:$sb, firewall:$fw, updatesGuarded:$g, warp:$warp}
     + (if $e != null then {diskEncrypted:$e} else {} end)
     + (if $last != "" then {lastUpgradeAt:(($last|tonumber)*1000)} else {} end)
     + (if $vuln != "" then {vulnerablePackages:($vuln|tonumber)} else {} end)'
}

# desk_health_fields — called by control_health_json on desks only.
desk_health_fields() {
  desk_mode || return 0
  local v
  v="$(desk_cached info 120 desk_info_json)"; [[ "$v" != "null" ]] && _health_raw desk "$v"
  v="$(desk_cached software 900 desk_software_json)"; [[ "$v" != "null" ]] && _health_raw software "$v"
  v="$(desk_cached posture 900 desk_posture_json)"; [[ "$v" != "null" ]] && _health_raw posture "$v"
  _health_raw terminal "$(desk_terminal_json)"
}

# desk_audit — doctor findings for a desk, one per line.
desk_audit() {
  desk_mode || return 0
  [[ -n "$(desk_user)" ]] || printf '%s\n' "desk has no developer user (set by the desk group; install with sudo from the developer's account)"
  have warp-cli || printf '%s\n' "the Cloudflare One Client (warp-cli) is not installed"
  if desk_disk_encrypted; then :; elif [[ $? == 1 ]]; then printf '%s\n' "the root filesystem is not encrypted (LUKS): a stolen desk exposes its data"; fi
}
