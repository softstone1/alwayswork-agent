# alwayswork capability: core
# Sourced with CAP_ID and CAP_DIR exported.

# yq is deliberately absent: Arch packages the Python build, so install.sh
# bundles mikefarah's Go yq beside the CLI instead.
BASE_PKGS=(git curl jq sops age ufw snapper)
if distro_is_arch; then
  BASE_PKGS+=(snap-pac)
  if cfg_bool '.hardening.cve_scan' true; then
    BASE_PKGS+=(arch-audit)
  fi
else
  # snap-pac (btrfs pacman hooks) and arch-audit exist only on Arch.
  info "skipping Arch-only packages (snap-pac, arch-audit) on $(distro_pretty)"
fi

log "core: installing base packages"
pkg_install "${BASE_PKGS[@]}"

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

# Safe unattended updates (lib/updates.sh): only `aw update` changes packages,
# and every boot after an update verifies health or rolls back.
upd_install_guard_hooks
upd_install_units

ok "core foundation ready"
