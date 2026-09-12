# alwayswork capability: core
# Sourced with CAP_ID and CAP_DIR exported.

BASE_PKGS=(git curl jq yq sops age ufw snapper snap-pac)
if cfg_bool '.hardening.cve_scan' true; then
  BASE_PKGS+=(arch-audit)
fi

log "core: installing base packages"
run pacman -S --needed --noconfirm "${BASE_PKGS[@]}"

if cfg_bool '.hardening.firewall' true; then
  log "core: hardening firewall"
  fw_ensure || warn "firewall was not configured"
fi

log "core: applying kernel hardening"
aw_write /etc/sysctl.d/99-alwayswork.conf <<'SYSCTL'
# Managed by alwayswork
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
SYSCTL
run sysctl --system >/dev/null

if [[ "$(sec_backend)" == "sops" ]]; then
  sec_init
fi

if cfg_bool '.hardening.auto_update' false; then
  log "core: enabling weekly update timer"
  aw_write /etc/systemd/system/alwayswork-update.service <<'UNIT'
[Unit]
Description=AlwaysWork automatic update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alwayswork update --yes
UNIT
  aw_write /etc/systemd/system/alwayswork-update.timer <<'UNIT'
[Unit]
Description=Run AlwaysWork update weekly

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  run systemctl daemon-reload
  run systemctl enable --now alwayswork-update.timer
else
  info "auto_update is off; run 'aw update' manually (snapshots make it safe)"
fi

if cfg_bool '.always_on.enabled' true; then
  power_apply
fi

ok "core foundation ready"
