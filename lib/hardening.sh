# shellcheck shell=bash
# alwayswork · hardening primitives shared by `aw bootstrap` and the control
# agent.
#
# apply_ssh_policy [policy] — enforce the SSH hardening policy (default: the
# configured .hardening.ssh value). Idempotent. Runs at `aw bootstrap` time
# for interactive installs AND, automatically, from the control agent when a
# verified desired-state delivery marks a tunnel-managed node active. It must
# NEVER run at zero-touch install time: it would cut off access before the
# tunnel is verified. See docs/ENROLLMENT.md for the ordering.

apply_ssh_policy() {
  local policy="${1:-$(cfg_get '.hardening.ssh' disabled)}"
  case "$policy" in
    disabled)
      # A previous 'lan' policy may have left a subnet-scoped SSH rule behind.
      fw_close_cap_subnet_ports "hardening.ssh" 2>/dev/null || true
      if systemctl is-enabled --quiet sshd 2>/dev/null; then
        log "Disabling SSH (policy: disabled)"
        run systemctl disable --now sshd 2>/dev/null || true
      else
        ok "SSH already disabled"
      fi
      ;;
    tailscale)
      # Enforced: sshd stays enabled but is reachable only over Tailscale —
      # the firewall default-denies inbound and access.tailscale opens only
      # the tailscale0 interface, so nothing else can reach port 22.
      cap_is_enabled access.tailscale \
        || die "SSH policy 'tailscale' needs the access.tailscale capability (aw enable access.tailscale)"
      # A previous 'lan' policy may have left a subnet-scoped SSH rule behind.
      fw_close_cap_subnet_ports "hardening.ssh" 2>/dev/null || true
      if systemctl is-enabled --quiet sshd 2>/dev/null; then
        ok "SSH enabled (policy: tailscale; reachable via the tailnet only)"
      else
        log "Enabling SSH (policy: tailscale; reachable via the tailnet only)"
        run systemctl enable --now sshd
      fi
      ;;
    lan)
      # Enforced: sshd is bound to the LAN address via a drop-in, so it never
      # listens on WAN-facing interfaces. Binding alone is not enough: the
      # default-deny firewall would still drop the packets, so open port 22
      # for the LAN subnet only — never 0.0.0.0/0.
      local lan_ip lan_cidr
      lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
      [[ -n "$lan_ip" ]] || die "SSH policy 'lan' could not detect the LAN address; configure sshd manually"
      lan_cidr="$(ip -4 -o addr show 2>/dev/null | awk -v ip="$lan_ip" 'index($4, ip"/")==1 {print $4; exit}')"
      log "Binding SSH to the LAN interface ($lan_ip) (policy: lan)"
      aw_write /etc/ssh/sshd_config.d/10-alwayswork-lan.conf <<EOF
# managed by alwayswork (hardening.ssh=lan)
ListenAddress $lan_ip
EOF
      # A stale tunnel drop-in would keep loopback bound too; drop it.
      run rm -f /etc/ssh/sshd_config.d/10-alwayswork-tunnel.conf
      # Close any stale rule first (the LAN subnet may have changed).
      fw_close_cap_subnet_ports "hardening.ssh" 2>/dev/null || true
      if [[ -n "$lan_cidr" ]] && cfg_bool '.hardening.firewall' true; then
        fw_allow_subnet_port "hardening.ssh" "$lan_cidr" 22 \
          || warn "could not open SSH for $lan_cidr in the firewall"
      else
        warn "SSH policy 'lan': could not determine the LAN subnet ($lan_ip); open port 22 for it manually"
      fi
      run systemctl enable --now sshd
      run systemctl try-restart sshd 2>/dev/null || run systemctl restart sshd
      ok "SSH bound to $lan_ip"
      ;;
    tunnel)
      # Enforced: sshd listens on loopback only, so the sole way in is the
      # Cloudflare Access SSH ingress (<node>-ssh.<base> -> ssh://127.0.0.1:22)
      # with short-lived certificates signed by the Access CA. The CA public
      # key is delivered as access.sshCa and written by the control agent
      # (control_apply_access); no authorized_keys are ever written. The
      # firewall never opens 22: any earlier LAN opening is closed here.
      local ca_file ca_line=""
      ca_file="$(control_access_ca_file)"
      if [[ -f "$ca_file" ]]; then
        ca_line="TrustedUserCAKeys $ca_file"
      else
        warn "SSH policy 'tunnel': no access CA at $ca_file yet (delivered as access.sshCa); certificate logins start once it arrives"
      fi
      fw_close_cap_subnet_ports "hardening.ssh" 2>/dev/null || true
      # A stale LAN drop-in would keep a LAN ListenAddress alongside loopback.
      run rm -f /etc/ssh/sshd_config.d/10-alwayswork-lan.conf
      log "Binding SSH to loopback (policy: tunnel; reachable via the Access SSH ingress only)"
      aw_write /etc/ssh/sshd_config.d/10-alwayswork-tunnel.conf <<EOF
# managed by alwayswork (hardening.ssh=tunnel)
ListenAddress 127.0.0.1
ListenAddress ::1
PasswordAuthentication no
${ca_line}
EOF
      run systemctl enable --now sshd
      # SIGHUP makes sshd re-exec and rebind, so a reload picks up the new
      # ListenAddress lines as well as the CA.
      run systemctl reload-or-restart sshd
      ok "SSH bound to loopback (policy: tunnel)"
      ;;
    *)
      warn "unknown hardening.ssh policy: $policy"
      ;;
  esac
}

# ssh_loopback_only — 0 when every TCP listener on port 22 is bound to a
# loopback address. Used by doctor to grade policy `tunnel`. Without `ss`
# (or with no listener at all) the answer is "not proven": returns 1.
ssh_loopback_only() {
  have ss || return 1
  local listeners
  listeners="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E '(^|:)22$' || true)"
  [[ -n "$listeners" ]] || return 1
  ! grep -Ev '^(127\.0\.0\.1|\[::1\]):22$' <<<"$listeners" >/dev/null
}
