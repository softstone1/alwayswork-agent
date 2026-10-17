# shellcheck shell=bash
# alwayswork · operator SSH through Cloudflare Access for Infrastructure
# (control repo docs/NETWORK_SECURITY.md, phase N2; issue #18).
#
# The signed delivery's config may carry
#
#   "infraAccess": { "address":     "198.18.x.y/32",
#                    "caPublicKey": "<one OpenSSH public key line>",
#                    "users":       ["aw"] }
#
# Present: the node converges to
#   - a dummy interface `awinfra0` holding exactly that /32 (systemd-networkd
#     .netdev/.network when networkd runs, else the oneshot unit
#     alwayswork-infra-net.service); the control plane routes the /32 through
#     this node's Cloudflare Tunnel, so the only way to it is Cloudflare One
#     Client -> Access for Infrastructure target -> tunnel -> lo;
#   - a dedicated sshd, alwayswork-sshd.service, running
#     `sshd -D -f /etc/alwayswork/sshd_config`: ListenAddress is the /32 and
#     nothing else, the only credential is a short-lived certificate signed
#     by the Cloudflare SSH CA (TrustedUserCAKeys), no passwords, no
#     authorized_keys, no forwarding. The distro ssh/sshd unit is untouched
#     (it stays as hardening.ssh left it — disabled by default);
#   - every listed UNIX user exists with a locked password.
# Absent or null: all of it is removed (users are kept) and the node is back
# to the plain "SSH off" posture.
#
# Bad input (address outside 198.18.128.0/20, not a /32, a CA that is not one
# key line, a bad user name) is refused with a warning and the previous state
# is kept. A candidate sshd_config that `sshd -t` rejects is never installed:
# the running sshd keeps its previous config and health reports "failed".
#
# The firewall needs nothing: cloudflared delivers the traffic to a local
# address, which the kernel routes over `lo`, and ufw's stock before.rules
# (and firewalld) accept everything on lo. Port 22 is never opened.

INFRA_IFACE="awinfra0"
INFRA_SSHD_UNIT="alwayswork-sshd.service"
INFRA_NET_UNIT="alwayswork-infra-net.service"

infra_unit_dir()      { printf '%s\n' "${AW_SYSTEMD_DIR:-/etc/systemd/system}"; }
infra_networkd_dir()  { printf '%s\n' "${AW_NETWORKD_DIR:-/etc/systemd/network}"; }
infra_sshd_config()   { printf '%s\n' "$AW_ETC/sshd_config"; }
infra_ca_file()       { printf '%s\n' "$AW_ETC/ssh-ca.pub"; }
infra_hostkey_dir()   { printf '%s\n' "$AW_ETC/ssh"; }
infra_sudoers_file()  { printf '%s\n' "${AW_SUDOERS_DIR:-/etc/sudoers.d}/alwayswork-infra"; }
infra_state_file()    { printf '%s\n' "$AW_STATE/infra-access.json"; }
infra_configured()    { [[ -f "$(infra_state_file)" ]]; }

# Absolute paths for unit files (systemd wants them); overridable for tests.
_infra_bin() {
  local name="$1" d
  for d in /usr/sbin /usr/bin /sbin /bin; do
    [[ -x "$d/$name" ]] && { printf '%s\n' "$d/$name"; return 0; }
  done
  printf '/usr/sbin/%s\n' "$name"
}
infra_sshd_bin() { printf '%s\n' "${AW_SSHD_BIN:-$(_infra_bin sshd)}"; }
infra_ip_bin()   { printf '%s\n' "${AW_IP_BIN:-$(_infra_bin ip)}"; }

# --- validation ----------------------------------------------------------------

# infra_valid_address <a.b.c.d/32> — inside 198.18.128.0/20, /32, no leading
# zeros (198.18.128.0 - 198.18.143.255).
infra_valid_address() {
  [[ "$1" =~ ^198\.18\.(12[89]|13[0-9]|14[0-3])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])/32$ ]]
}

# infra_valid_ca <line> — exactly one OpenSSH public key line whose base64
# blob decodes and starts with the same key type.
infra_valid_ca() {
  local line="$1" type blob
  [[ "$line" != *$'\n'* && "$line" != *$'\r'* ]] || return 1
  [[ "$line" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ ([A-Za-z0-9+/]+={0,2})(\ [[:print:]]*)?$ ]] || return 1
  type="${BASH_REMATCH[1]}"; blob="${BASH_REMATCH[2]}"
  # The blob is <uint32 len><type>...; its type must match the prefix.
  local inner
  inner="$(printf '%s' "$blob" | base64 -d 2>/dev/null | head -c $(( 4 + ${#type} )) | tail -c "${#type}" 2>/dev/null)" || return 1
  [[ "$inner" == "$type" ]]
}

infra_valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != "root" ]]
}

# infra_ca_fingerprint <line> — SHA256:<base64> as ssh-keygen -l prints it.
infra_ca_fingerprint() {
  local blob; blob="$(awk '{print $2}' <<<"$1")"
  [[ -n "$blob" ]] || return 0
  if have openssl; then
    printf 'SHA256:%s\n' "$(printf '%s' "$blob" | base64 -d 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '=\n')"
  elif have sha256sum && have xxd; then
    printf 'SHA256:%s\n' "$(printf '%s' "$blob" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1 | xxd -r -p | base64 | tr -d '=\n')"
  fi
}

# --- rendering -----------------------------------------------------------------

# infra_render_sshd_config <address/32> <user...>
infra_render_sshd_config() {
  local addr="${1%/32}"; shift
  local hk; hk="$(infra_hostkey_dir)"
  cat <<EOF
# managed by alwayswork (infraAccess) — rewritten on every delivery; do not edit.
# Reachable only through Cloudflare Access for Infrastructure: the address
# below lives on the dummy interface $INFRA_IFACE and is routed to this node
# through its Cloudflare Tunnel. The only credential is a short-lived
# certificate signed by the Cloudflare SSH CA.
ListenAddress $addr
Port 22
AddressFamily inet
HostKey $hk/ssh_host_ed25519_key
PidFile /run/alwayswork-sshd.pid

PubkeyAuthentication yes
TrustedUserCAKeys $(infra_ca_file)
AuthorizedKeysFile none
AuthorizedPrincipalsFile none
PasswordAuthentication no
KbdInteractiveAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
# PAM only for account/session: with UsePAM no, sshd refuses accounts whose
# password is locked (passwd -l), which is exactly what these users are.
UsePAM yes
AllowUsers $*

# A shell, nothing else: forwarding would turn this node into a pivot onto
# its loopback-only services (databases, UIs) around their own Access apps.
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
Subsystem sftp internal-sftp
EOF
}

infra_render_sshd_unit() {
  local sshd cfg after="network.target" wants=""
  sshd="$(infra_sshd_bin)"; cfg="$(infra_sshd_config)"
  if [[ "${1:-unit}" == "networkd" ]]; then after+=" systemd-networkd.service"
  else after+=" $INFRA_NET_UNIT"; wants="Wants=$INFRA_NET_UNIT"$'\n'; fi
  cat <<EOF
# managed by alwayswork (infraAccess)
[Unit]
Description=alwayswork infrastructure sshd (Access for Infrastructure, $INFRA_IFACE only)
After=$after
${wants}StartLimitIntervalSec=0

[Service]
Type=simple
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
ExecStartPre=$sshd -t -f $cfg
ExecStart=$sshd -D -f $cfg
ExecReload=$sshd -t -f $cfg
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

infra_render_net_unit() {
  local addr="$1" ip; ip="$(infra_ip_bin)"
  cat <<EOF
# managed by alwayswork (infraAccess)
[Unit]
Description=alwayswork infrastructure interface $INFRA_IFACE ($addr)
After=network-pre.target
Before=network.target $INFRA_SSHD_UNIT

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-$ip link add $INFRA_IFACE type dummy
ExecStart=$ip addr flush dev $INFRA_IFACE
ExecStart=$ip addr replace $addr dev $INFRA_IFACE
ExecStart=$ip link set $INFRA_IFACE up
ExecStop=-$ip link del $INFRA_IFACE

[Install]
WantedBy=multi-user.target
EOF
}

infra_render_netdev() {
  cat <<EOF
# managed by alwayswork (infraAccess)
[NetDev]
Name=$INFRA_IFACE
Kind=dummy
EOF
}

infra_render_network() {
  cat <<EOF
# managed by alwayswork (infraAccess)
[Match]
Name=$INFRA_IFACE

[Link]
RequiredForOnline=no

[Network]
Address=$1
EOF
}

# infra_render_sudoers <user...> — passwordless sudo for exactly these users.
infra_render_sudoers() {
  local u
  cat <<'SUDOERS'
# managed by alwayswork (infraAccess) — removed when infraAccess is.
# These users have no password and no keys: each login is a short-lived
# certificate that Cloudflare Access for Infrastructure issued only after
# checking the operator's identity and device posture, so a password prompt
# here would add nothing but a shared secret.
SUDOERS
  for u in "$@"; do printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u"; done
}

# infra_apply_sudoers <user...> — install the drop-in only after `visudo -cf`
# accepts it. The candidate's name contains a dot, so sudo never reads it.
# On rejection the previous file is kept and a warning is printed.
infra_apply_sudoers() {
  local f cand new
  f="$(infra_sudoers_file)"; cand="$(dirname "$f")/.alwayswork-infra.new"
  new="$(infra_render_sudoers "$@")"
  [[ -f "$f" && "$(cat "$f" 2>/dev/null)" == "$new" ]] && return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] write %s (0440, visudo -cf)\n' "$f" >&2; return 0
  fi
  ensure_dir "$(dirname "$f")"
  ( umask 0337; printf '%s\n' "$new" > "$cand" ) || { warn "control: could not write $cand"; return 0; }
  run chmod 0440 "$cand" 2>/dev/null || true
  if ! visudo -cf "$cand" >/dev/null 2>&1; then
    run rm -f "$cand"
    warn "control: the sudoers drop-in was rejected by visudo -cf; keeping the previous $f"
    return 0
  fi
  _aw_write_ledger "$f"
  run mv -f "$cand" "$f" || warn "control: could not install $f"
}

# _infra_put <path> <mode> < content — write only when the content differs.
# Returns 0 when the file changed, 1 when it was already current.
_infra_put() {
  local path="$1" mode="$2" new
  new="$(cat)"
  if [[ -f "$path" && "$(cat "$path" 2>/dev/null)" == "$new" ]]; then return 1; fi
  printf '%s\n' "$new" | aw_write "$path" || return 1
  run chmod "$mode" "$path" 2>/dev/null || true
  return 0
}

_infra_networkd() { have systemctl && systemctl is-active --quiet systemd-networkd.service 2>/dev/null; }

_infra_write_state() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  ensure_dir "$AW_STATE"
  jq -nc --arg a "$1" --arg f "$2" --arg m "$3" --arg s "$4" --argjson u "$5" \
    '{address:$a, caFingerprint:$f, netMode:$m, sshd:$s, users:$u}' > "$(infra_state_file)"
}

# _infra_write_state_failed — mark sshd failed without claiming the new
# address/CA: the state keeps describing what is actually installed.
_infra_write_state_failed() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local f; f="$(infra_state_file)"
  if [[ -f "$f" ]]; then
    jq -c '.sshd = "failed"' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  else
    _infra_write_state "$addr" "$fp" "" failed "$users_json"
  fi
}

# --- converge ------------------------------------------------------------------

# infra_apply_from_delivery <delivery-json>. Returns 1 only on a failure a
# retry can fix (systemd could not start a unit); bad input and a rejected
# sshd config are warnings (a retry of the same delivery cannot fix them).
infra_apply_from_delivery() {
  local json="$1"
  if ! jq -e '.config.infraAccess | type == "object"' >/dev/null 2>&1 <<<"$json"; then
    infra_remove
    return 0
  fi
  local addr ca users_json
  addr="$(jq -r '.config.infraAccess.address // "" | strings' <<<"$json" 2>/dev/null)"
  ca="$(jq -r '.config.infraAccess.caPublicKey // "" | strings' <<<"$json" 2>/dev/null)"
  while [[ "$ca" == *$'\n' ]]; do ca="${ca%$'\n'}"; done
  users_json="$(jq -c '.config.infraAccess.users // [] | if type == "array" then . else [] end' <<<"$json" 2>/dev/null)"
  if ! infra_valid_address "$addr"; then
    warn "control: infraAccess.address '$(printf '%s' "$addr" | head -c 64)' is not a /32 inside 198.18.128.0/20; keeping the previous infra SSH state"
    return 0
  fi
  if ! infra_valid_ca "$ca"; then
    warn "control: infraAccess.caPublicKey is not a single OpenSSH public key line; keeping the previous infra SSH state"
    return 0
  fi
  local users=() u
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    if ! infra_valid_user "$u"; then
      warn "control: infraAccess.users has an invalid name '$(printf '%s' "$u" | head -c 40)'; keeping the previous infra SSH state"
      return 0
    fi
    [[ " ${users[*]:-} " == *" $u "* ]] || users+=("$u")
  done < <(jq -r '.[] | strings' <<<"$users_json" 2>/dev/null)
  if (( ${#users[@]} == 0 || ${#users[@]} > 16 )); then
    warn "control: infraAccess.users must list 1-16 users; keeping the previous infra SSH state"
    return 0
  fi
  infra_converge "$addr" "$ca" "${users[@]}"
}

# infra_converge <address/32> <ca-line> <user...>
infra_converge() {
  local addr="$1" ca="$2"; shift 2
  local users=("$@") u mode fp ud nd cfg cand sshd
  ud="$(infra_unit_dir)"; nd="$(infra_networkd_dir)"; cfg="$(infra_sshd_config)"; sshd="$(infra_sshd_bin)"
  fp="$(infra_ca_fingerprint "$ca")"
  log "control: infra SSH on $INFRA_IFACE $addr (users: ${users[*]}; CA $fp)"

  local users_json sshd_state config_changed=0 ca_changed=0 net_changed=0 unit_changed=0
  # 1. Host keys, generated once under /etc/alwayswork/ssh/.
  local hk; hk="$(infra_hostkey_dir)"
  ensure_dir "$hk"
  run chmod 0700 "$hk" 2>/dev/null || true
  if [[ ! -f "$hk/ssh_host_ed25519_key" ]]; then
    run ssh-keygen -q -t ed25519 -N '' -C "alwayswork-infra@$(hostname 2>/dev/null || echo node)" -f "$hk/ssh_host_ed25519_key" \
      || { warn "control: could not generate the infra SSH host key"; return 1; }
  fi

  # 2. sshd config: validate a candidate with `sshd -t` before anything
  # else changes; a rejected candidate leaves the node exactly as it was.
  users_json="$(printf '%s\n' "${users[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  cand="$cfg.new"
  local rendered; rendered="$(infra_render_sshd_config "$addr" "${users[@]}")"
  if [[ ! -f "$cfg" || "$(cat "$cfg" 2>/dev/null)" != "$rendered" ]]; then
    config_changed=1
    printf '%s\n' "$rendered" | aw_write "$cand"
    run chmod 0600 "$cand" 2>/dev/null || true
    # sshd -t refuses to run without its privilege-separation directory
    # ("Missing privilege separation directory: /run/sshd", exit 255). The
    # distro's ssh.service creates it, and the SSH lockdown stops that
    # service — so on a locked-down node the check failed for a reason that
    # had nothing to do with the config (live on Ubuntu 26.04, 2026-10-17).
    [[ "$DRY_RUN" == "1" ]] || install -d -m 0755 /run/sshd 2>/dev/null || true
    local why=""
    if [[ "$DRY_RUN" != "1" ]] && ! why="$("$sshd" -t -f "$cand" 2>&1)"; then
      err "control: the candidate sshd config was rejected by sshd -t (${why:0:300}); the previous infra sshd config stays in place"
      run rm -f "$cand"
      _infra_write_state_failed
      return 0
    fi
  fi
  # 3. Users: exist, password locked. Never removed here or on disable.
  for u in "${users[@]}"; do
    if ! getent passwd "$u" >/dev/null 2>&1; then
      run useradd -m -s /bin/bash "$u" || { warn "control: could not create user $u"; return 1; }
      ok "created user $u"
    fi
    run passwd -l "$u" >/dev/null 2>&1 || warn "control: could not lock the password of $u"
  done

  # Passwordless sudo for exactly these users, so an operator can run `aw`.
  infra_apply_sudoers "${users[@]}"

  # 4. The interface. The mode sticks once chosen so a later converge cleans
  # up the right files; the other mode's leftovers are removed either way.
  if _infra_networkd; then mode=networkd; else mode=unit; fi
  if [[ "$mode" == networkd ]]; then
    infra_render_netdev | _infra_put "$nd/50-$INFRA_IFACE.netdev" 0644 && net_changed=1
    infra_render_network "$addr" | _infra_put "$nd/50-$INFRA_IFACE.network" 0644 && net_changed=1
    if [[ -f "$ud/$INFRA_NET_UNIT" ]]; then
      run systemctl disable "$INFRA_NET_UNIT" >/dev/null 2>&1 || true
      run rm -f "$ud/$INFRA_NET_UNIT"; unit_changed=1
    fi
  else
    infra_render_net_unit "$addr" | _infra_put "$ud/$INFRA_NET_UNIT" 0644 && { net_changed=1; unit_changed=1; }
    if [[ -f "$nd/50-$INFRA_IFACE.netdev" || -f "$nd/50-$INFRA_IFACE.network" ]]; then
      run rm -f "$nd/50-$INFRA_IFACE.netdev" "$nd/50-$INFRA_IFACE.network"
    fi
  fi
  infra_render_sshd_unit "$mode" | _infra_put "$ud/$INFRA_SSHD_UNIT" 0644 && unit_changed=1
  (( unit_changed )) && run systemctl daemon-reload

  if [[ "$mode" == networkd ]]; then
    if (( net_changed )); then
      run networkctl reload || warn "control: networkctl reload failed"
      run networkctl reconfigure "$INFRA_IFACE" 2>/dev/null || true
    fi
  else
    run systemctl enable "$INFRA_NET_UNIT" >/dev/null 2>&1 || true
    if (( net_changed )) || ! systemctl is-active --quiet "$INFRA_NET_UNIT" 2>/dev/null; then
      run systemctl restart "$INFRA_NET_UNIT" || { warn "control: $INFRA_NET_UNIT failed to start"; _infra_write_state "$addr" "$fp" "$mode" failed "$users_json"; return 1; }
    fi
  fi

  # 5. Install the validated config and the CA.
  if [[ ! -f "$(infra_ca_file)" || "$(cat "$(infra_ca_file)" 2>/dev/null)" != "$ca" ]]; then
    ca_changed=1
    printf '%s\n' "$ca" | aw_write "$(infra_ca_file)"
    run chmod 0644 "$(infra_ca_file)" 2>/dev/null || true
  fi
  (( config_changed )) && run mv -f "$cand" "$cfg"

  # 6. The service: start it, or reload it (SIGHUP re-execs sshd, which
  # rebinds ListenAddress and re-reads the CA) when anything changed.
  run systemctl enable "$INFRA_SSHD_UNIT" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$INFRA_SSHD_UNIT" 2>/dev/null; then
    run systemctl restart "$INFRA_SSHD_UNIT" || true
  elif (( unit_changed )); then
    run systemctl restart "$INFRA_SSHD_UNIT" || true
  elif (( config_changed || ca_changed || net_changed )); then
    run systemctl reload "$INFRA_SSHD_UNIT" || run systemctl restart "$INFRA_SSHD_UNIT" || true
  else
    info "control: infra sshd already current"
  fi
  if [[ "$DRY_RUN" == "1" ]] || systemctl is-active --quiet "$INFRA_SSHD_UNIT" 2>/dev/null; then
    sshd_state=active
  else
    sshd_state=failed
  fi
  _infra_write_state "$addr" "$fp" "$mode" "$sshd_state" "$users_json"
  if [[ "$sshd_state" == failed ]]; then
    warn "control: $INFRA_SSHD_UNIT is not running (journalctl -u $INFRA_SSHD_UNIT); will retry"
    return 1
  fi
  ok "control: infra sshd listening on ${addr%/32}:22 only"
}

# infra_remove — back to "SSH off": stop and delete everything infraAccess
# created except the users. A no-op when nothing was ever configured.
infra_remove() {
  local ud nd hk
  ud="$(infra_unit_dir)"; nd="$(infra_networkd_dir)"; hk="$(infra_hostkey_dir)"
  if ! infra_configured && [[ ! -f "$ud/$INFRA_SSHD_UNIT" && ! -f "$ud/$INFRA_NET_UNIT" \
        && ! -f "$nd/50-$INFRA_IFACE.netdev" && ! -f "$(infra_sshd_config)" && ! -f "$(infra_sudoers_file)" ]]; then
    return 0
  fi
  log "control: removing infra SSH (no infraAccess in desired state)"
  run systemctl disable --now "$INFRA_SSHD_UNIT" >/dev/null 2>&1 || true
  run systemctl disable --now "$INFRA_NET_UNIT" >/dev/null 2>&1 || true
  run rm -f "$ud/$INFRA_SSHD_UNIT" "$ud/$INFRA_NET_UNIT"
  run systemctl daemon-reload || true
  if [[ -f "$nd/50-$INFRA_IFACE.netdev" || -f "$nd/50-$INFRA_IFACE.network" ]]; then
    run rm -f "$nd/50-$INFRA_IFACE.netdev" "$nd/50-$INFRA_IFACE.network"
    run networkctl reload 2>/dev/null || true
  fi
  if have ip && ip link show "$INFRA_IFACE" >/dev/null 2>&1; then
    run ip link del "$INFRA_IFACE" || warn "control: could not delete $INFRA_IFACE"
  fi
  run rm -f "$(infra_sshd_config)" "$(infra_sshd_config).new" "$(infra_ca_file)" \
    "$hk/ssh_host_ed25519_key" "$hk/ssh_host_ed25519_key.pub"
  run rm -f "$(infra_sudoers_file)" "$(dirname "$(infra_sudoers_file)")/.alwayswork-infra.new"
  run rm -f "$(infra_state_file)"
  ok "control: infra SSH removed (SSH off)"
}

# --- reporting -------------------------------------------------------------------

# infra_sshd_word — active | failed | off.
infra_sshd_word() {
  infra_configured || { printf 'off\n'; return 0; }
  if have systemctl && systemctl is-active --quiet "$INFRA_SSHD_UNIT" 2>/dev/null \
     && [[ "$(jq -r '.sshd // ""' "$(infra_state_file)" 2>/dev/null)" != failed ]]; then
    printf 'active\n'
  else
    printf 'failed\n'
  fi
}

# infra_health_json — health.infraAccess: public facts only.
infra_health_json() {
  local f; f="$(infra_state_file)"
  if ! infra_configured; then jq -nc '{sshd:"off"}'; return 0; fi
  jq -c --arg s "$(infra_sshd_word)" '{address:(.address // ""), sshd:$s, caFingerprint:(.caFingerprint // "")}' "$f" 2>/dev/null \
    || jq -nc '{sshd:"failed"}'
}

# infra_sshd_listeners — "addr:port" of every TCP socket sshd listens on.
# Fails when ss is unavailable.
infra_sshd_listeners() {
  have ss || return 1
  ss -Hltnp 2>/dev/null | awk '/users:\(\("sshd"/ {print $4}' | sort -u
}
