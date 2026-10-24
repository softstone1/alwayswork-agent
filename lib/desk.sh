# shellcheck shell=bash
# alwayswork · developer desks (control plane docs/DESK.md).
#
# A desk is a developer's own workstation that is also a node: a person signs
# in at the desktop, and the agent keeps it managed and reported. Compared
# with a headless node it differs in exactly these ways:
#
#   - power is left to the desktop (no masked sleep, no logind overrides);
#   - the Cloudflare One Client (desk.warp) carries the developer's identity
#     out (what the operator's Access apps check); the agent installs or
#     adopts it, enrols it into the operator's organization and keeps it
#     locked on unless the desk group allows otherwise;
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
    rm -f "$AW_STATE/desk-delivery.json" 2>/dev/null || true
    desk_terminal_close "no desk block in the delivery"
    return 0
  fi
  user="$(jq -r '.desk.user // ""' <<<"$json")"
  org="$(jq -r '.desk.organization // ""' <<<"$json")"
  # Absent (an older control plane) = locked, the safe default.
  cfg_set_expr '.desk.warpLocked' "$(jq -c 'if .desk.warpLocked == false then false else true end' <<<"$json")"
  if [[ -n "$user" ]]; then
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != "root" ]] || { warn "desk: refusing desk user '$user'"; return 1; }
    cfg_set_str '.desk.user' "$user"
  fi
  if [[ -n "$org" && "$org" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    cfg_set_str '.desk.organization' "$org"
    # Only a desk that runs desk.warp is enrolled; a client the developer
    # installed on their own is left exactly as they configured it.
    if cfg_list '.capabilities.enabled' 2>/dev/null | grep -qx desk.warp; then
      desk_warp_enrol "$org" || warn "desk: Cloudflare One Client enrolment is not configured yet"
    fi
  fi
  # The desk block is kept so the agent tick can retry the terminal on its
  # own (desk_tick); a terminal that cannot open yet never holds up the rest
  # of the delivery, an agent update included.
  jq -c '.desk' <<<"$json" | aw_write "$AW_STATE/desk-delivery.json" 2>/dev/null || true
  desk_terminal_apply "$json" || warn "desk: terminal not converged yet; retried every tick"
  return 0
}

# desk_tick — every agent tick: converge the terminal from the last desk
# delivery (open it if it should be and is not, close it once it lapsed).
desk_tick() {
  local f="$AW_STATE/desk-delivery.json" block
  [[ -f "$f" ]] || return 0
  block="$(cat "$f" 2>/dev/null)"; jq -e . >/dev/null 2>&1 <<<"$block" || return 0
  desk_terminal_apply "$(jq -c '{desk: .}' <<<"$block")" >/dev/null 2>&1 || true
}

# --- Cloudflare One Client ------------------------------------------------------

# desk_warp_render_mdm <organization> — the managed-deployment file warp-svc
# reads: the developer signs in with their identity in the browser, and the
# device joins this organization only. No secret is involved.
# desk_warp_render_mdm <organization> [locked true|false] — locked: the
# developer cannot switch the client off; unlocked: it comes back on after
# 15 minutes. The control plane's device profile says the same server-side.
desk_warp_render_mdm() {
  local locked="${2:-true}" auto=0
  [[ "$locked" == true ]] || auto=15
  cat <<EOF
<dict>
  <!-- managed by alwayswork (desk) -->
  <key>organization</key>
  <string>$1</string>
  <key>switch_locked</key>
  <$locked/>
  <key>auto_connect</key>
  <integer>$auto</integer>
  <key>onboarding</key>
  <false/>
</dict>
EOF
}

desk_warp_enrol() {
  local org="$1" want have=""
  have warp-cli || [[ "${AW_TEST:-0}" == "1" ]] || return 1
  local locked; locked="$(cfg_get '.desk.warpLocked' true)"; [[ "$locked" == false ]] || locked=true
  want="$(desk_warp_render_mdm "$org" "$locked")"
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
    out="$(timeout 5 warp-cli --accept-tos status 2>/dev/null | tr '[:upper:]' '[:lower:]')"
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
# Browser-rendered SSH asks the person for the UNIX user while the
# connection waits: 20 s was too short to type it.
LoginGraceTime 120
ClientAliveInterval 60
ClientAliveCountMax 3
LogLevel VERBOSE
SyslogFacility AUTH
PrintMotd no
$(desk_sshd_penalties_line)
EOF
}

# Every connection reaches this sshd from 127.0.0.1 (cloudflared), so
# OpenSSH 9.8+'s per-source penalties would lock every operator out after
# one bad attempt. The grant's Access app is the gate; penalties are off.
desk_sshd_penalties_line() {
  local v; v="$("${AW_SSHD_BIN:-sshd}" -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | head -n1 | cut -d_ -f2)"
  [[ -n "$v" ]] || return 0
  local maj="${v%%.*}" min="${v#*.}"
  if (( maj > 9 || (maj == 9 && min >= 8) )); then printf 'PerSourcePenalties no'; fi
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

# desk_loopback22_taken — another sshd holds 127.0.0.1:22 (itself, or the
# wildcard). Infra access's sshd on its 198.18.x.y/32 does not conflict.
desk_loopback22_taken() {
  local out
  if [[ -n "${AW_TEST_SS22:-}" ]]; then out="$AW_TEST_SS22"; elif [[ "${AW_TEST:-0}" == "1" ]]; then return 1; else out="$(ss -Htln 'sport = :22' 2>/dev/null | awk '{print $4}')"; fi
  grep -Eq '^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::1\]|::):22$' <<<"$out"
}

# --- the operator account ------------------------------------------------------
#
# A grant logs in as the operator's own account, named after their email
# prefix: Cloudflare's browser-rendered SSH issues its short-lived
# certificate only for that name, and the desk's logs then say who it was.
# The account is created on first use (no password, locked), gets
# passwordless sudo for the grant only, and keeps its home afterwards.
# An existing account that this agent did not create is never taken over
# (except the desk's own developer).

desk_terminal_operators_file() { printf '%s\n' "$AW_STATE/terminal-operators"; }
desk_terminal_sudoers_file()   { printf '%s\n' "${AW_SUDOERS_DIR:-/etc/sudoers.d}/alwayswork-terminal"; }

desk_terminal_ensure_operator() {
  local user="$1"
  [[ "$user" == "$(desk_user)" ]] && return 0
  if getent passwd "$user" >/dev/null 2>&1; then
    grep -qx "$user" "$(desk_terminal_operators_file)" 2>/dev/null && return 0
    warn "desk: '$user' is an existing account this agent did not create; refusing to use it for a terminal grant"
    return 1
  fi
  log "desk: creating operator account $user (no password; reachable only inside terminal grants)"
  run useradd -m -s /bin/bash -c "AlwaysWork operator (desk terminal grants)" "$user" || { warn "desk: could not create $user"; return 1; }
  run passwd -l "$user" >/dev/null 2>&1 || true
  printf '%s\n' "$user" >> "$(desk_terminal_operators_file)"
}

# desk_terminal_sudo <user|""> — passwordless sudo for the grant's operator, or none.
desk_terminal_sudo() {
  local f cand; f="$(desk_terminal_sudoers_file)"
  if [[ -z "$1" ]]; then run rm -f "$f"; return 0; fi
  local want; want="$(printf '# managed by alwayswork (desk terminal grant) — removed when the grant closes.\n%s ALL=(ALL:ALL) NOPASSWD: ALL' "$1")"
  [[ -f "$f" && "$(cat "$f" 2>/dev/null)" == "$want" ]] && return 0
  ensure_dir "$(dirname "$f")"; cand="$(dirname "$f")/.alwayswork-terminal.new"
  ( umask 0337; printf '%s\n' "$want" > "$cand" ) || return 1
  run chmod 0440 "$cand" 2>/dev/null || true
  if ! visudo -cf "$cand" >/dev/null 2>&1; then run rm -f "$cand"; warn "desk: visudo rejected the terminal sudoers drop-in"; return 1; fi
  run mv -f "$cand" "$f"
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
  [[ "$user" =~ ^[a-z_][a-z0-9._-]{0,31}$ && "$user" != "root" ]] || { warn "desk: refusing terminal user '$user'"; desk_terminal_close "bad user"; return 1; }
  [[ "$ca" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+\ [A-Za-z0-9+/=]+ ]] || { warn "desk: refusing a terminal CA that is not an OpenSSH public key"; desk_terminal_close "bad CA"; return 1; }
  principals="$(jq -r '(.principals // [])[] | select(test("^[a-z0-9._-]{1,64}$"))' <<<"$t")"
  [[ -n "$principals" ]] || { warn "desk: terminal grant names no usable principal"; desk_terminal_close "no principal"; return 1; }
  if desk_loopback22_taken && ! systemctl is-active --quiet "$DESK_TERMINAL_UNIT" 2>/dev/null; then
    warn "desk: port 22 on this desk is held by another sshd; the terminal waits until it is off (the lockdown stops it)"
    return 1
  fi

  desk_terminal_ensure_operator "$user" || { desk_terminal_close "operator account unavailable"; return 1; }
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
  desk_terminal_sudo "$user" || warn "desk: the operator has no sudo for this grant"
  jq -nc --arg g "$gid" --argjson u "$until" --arg user "$user" '{grantId:$g, until:$u, user:$user}' | aw_write "$(desk_terminal_state)"
}

# desk_terminal_close [why] — idempotent: stop the sshd (ending every session),
# remove its unit, CA and principals. The host key stays so a later grant
# presents the same identity.
desk_terminal_close() {
  local why="${1:-closed}" unit dir had=0
  unit="$(desk_systemd_dir)/$DESK_TERMINAL_UNIT"; dir="$(desk_terminal_dir)"
  [[ -f "$unit" || -f "$(desk_terminal_state)" || -f "$(desk_terminal_sudoers_file)" ]] && had=1
  (( had )) || return 0
  run systemctl stop "$DESK_TERMINAL_UNIT" 2>/dev/null || true
  desk_terminal_sudo ""
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
  fw="$(head -c 120 /sys/class/dmi/id/bios_version 2>/dev/null)"
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
  local f=""
  for f in /sys/firmware/efi/efivars/SecureBoot-*; do [[ -e "$f" ]] && break; f=""; done
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

# desk_metrics_json — what the developer's machine is doing right now: CPU and
# GPU busy, network rates on the physical interfaces, swap, how long the
# session has been idle, connected displays. Rates are deltas against the
# previous heartbeat's counters ($AW_STATE/desk-counters).
desk_metrics_json() {
  local sys="${AW_SYS:-}" st="$AW_STATE/desk-counters" now cpu_t cpu_i rx=0 tx=0 i name
  now="$(date +%s)"
  read -r _ a b c d e f g h _ < "$sys/proc/stat" 2>/dev/null || true
  cpu_t=$(( ${a:-0} + ${b:-0} + ${c:-0} + ${d:-0} + ${e:-0} + ${f:-0} + ${g:-0} + ${h:-0} )); cpu_i=$(( ${d:-0} + ${e:-0} ))
  for i in "$sys"/sys/class/net/*; do
    name="$(basename "$i")"; [[ -e "$i/device" ]] || continue
    rx=$(( rx + $(cat "$i/statistics/rx_bytes" 2>/dev/null || echo 0) )); tx=$(( tx + $(cat "$i/statistics/tx_bytes" 2>/dev/null || echo 0) ))
  done
  local prev; prev="$(cat "$st" 2>/dev/null || true)"
  printf '%s %s %s %s %s\n' "$now" "$cpu_t" "$cpu_i" "$rx" "$tx" > "$st" 2>/dev/null || true
  local cpu_pct="" rxk="" txk=""
  if [[ -n "$prev" ]]; then
    local pn pt pi pr ptx; read -r pn pt pi pr ptx <<<"$prev"
    local dt=$(( now - pn )) dct=$(( cpu_t - pt )) dci=$(( cpu_i - pi ))
    (( dct > 0 )) && cpu_pct=$(( 100 * (dct - dci) / dct ))
    if (( dt > 0 && rx >= pr && tx >= ptx )); then rxk=$(( (rx - pr) * 8 / 1000 / dt )); txk=$(( (tx - ptx) * 8 / 1000 / dt )); fi
  fi
  local gpu="" g; for g in "$sys"/sys/class/drm/card*/device/gpu_busy_percent; do gpu="$(cat "$g" 2>/dev/null || true)"; [[ "$gpu" =~ ^[0-9]+$ ]] && break; gpu=""; done
  local swap_t swap_f swap=""; swap_t="$(awk '/^SwapTotal:/{print $2}' "$sys/proc/meminfo" 2>/dev/null)"; swap_f="$(awk '/^SwapFree:/{print $2}' "$sys/proc/meminfo" 2>/dev/null)"
  [[ "$swap_t" =~ ^[0-9]+$ && "$swap_f" =~ ^[0-9]+$ ]] && swap=$(( (swap_t - swap_f) / 1024 ))
  local displays=0 s; for s in "$sys"/sys/class/drm/card*-*/status; do [[ "$(cat "$s" 2>/dev/null)" == connected ]] && displays=$(( displays + 1 )); done
  local idle="" user sid hint; user="$(desk_user)"
  if [[ -n "$user" ]] && have loginctl; then
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$user" '$3 == u {print $1; exit}')"
    if [[ -n "$sid" ]]; then
      if [[ "$(loginctl show-session "$sid" -p IdleHint --value 2>/dev/null)" == yes ]]; then
        hint="$(loginctl show-session "$sid" -p IdleSinceHint --value 2>/dev/null)"
        [[ "$hint" =~ ^[0-9]+$ && "$hint" -gt 0 ]] && idle=$(( now - hint / 1000000 ))
      else idle=0; fi
    fi
  fi
  jq -nc --arg c "$cpu_pct" --arg g "$gpu" --arg r "$rxk" --arg t "$txk" --arg s "$swap" --arg i "$idle" --argjson d "$displays" \
    '{displays:$d} + (if $c != "" then {cpuPct:($c|tonumber)} else {} end) + (if $g != "" then {gpuBusyPct:($g|tonumber)} else {} end)
     + (if $r != "" then {netRxKbps:($r|tonumber), netTxKbps:($t|tonumber)} else {} end) + (if $s != "" then {swapUsedMb:($s|tonumber)} else {} end)
     + (if $i != "" then {idleSec:($i|tonumber)} else {} end)'
}

# desk_health_fields — called by control_health_json on desks only.
desk_health_fields() {
  desk_mode || return 0
  local v
  v="$(desk_cached info 120 desk_info_json)"
  if [[ "$v" != "null" ]]; then
    local m; m="$(desk_metrics_json 2>/dev/null || printf '{}')"
    jq -e . >/dev/null 2>&1 <<<"$m" || m='{}'
    _health_raw desk "$(jq -c --argjson m "$m" '. + {metrics:$m}' <<<"$v")"
  fi
  v="$(desk_cached software 900 desk_software_json)"; [[ "$v" != "null" ]] && _health_raw software "$v"
  v="$(desk_cached posture 900 desk_posture_json)"; [[ "$v" != "null" ]] && _health_raw posture "$v"
  _health_raw terminal "$(desk_terminal_json)"
}

# desk_audit — doctor findings for a desk, one per line.
desk_audit() {
  desk_mode || return 0
  [[ -n "$(desk_user)" ]] || printf '%s\n' "desk has no developer user (set by the desk group; install with sudo from the developer's account)"
  # The One Client is optional on a desk: only a desk that asked for it is told it is missing.
  if cfg_list '.capabilities.enabled' 2>/dev/null | grep -qx desk.warp && ! have warp-cli; then
    printf '%s\n' "desk.warp is enabled but the Cloudflare One Client (warp-cli) is not installed"
  fi
  if desk_disk_encrypted; then :; elif [[ $? == 1 ]]; then printf '%s\n' "the root filesystem is not encrypted (LUKS): a stolen desk exposes its data"; fi
}
