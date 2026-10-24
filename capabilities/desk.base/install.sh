# alwayswork capability: desk.base
#
# What makes a node a desk (lib/desk.sh). The headless always-on policy is
# undone here, because core may have applied it before the profile was known.
# The terminal sshd is not installed: it exists only while a grant is open.

log "desk.base: leaving power management to the desktop"
if [[ "$(systemctl is-enabled sleep.target 2>/dev/null || true)" == "masked" || -f "$(power_logind_conf)" ]]; then
  power_unapply
fi
# Name resolution stays on DNS (through the One Client): no LLMNR or mDNS
# responders listening on the LAN. avahi, printers and KDE Connect remain
# the developer's choice and are reported as LAN listeners.
if [[ -d /etc/systemd/resolved.conf.d || -f /etc/systemd/resolved.conf ]]; then
  ensure_dir /etc/systemd/resolved.conf.d
  aw_write /etc/systemd/resolved.conf.d/90-alwayswork-desk.conf <<'CONF'
# managed by alwayswork (desk.base)
[Resolve]
LLMNR=no
MulticastDNS=no
CONF
  run systemctl try-restart systemd-resolved 2>/dev/null || true
fi

# sshd is needed only for terminal grants, never enabled at boot (lib/desk.sh).
if ! have sshd; then
  if distro_is_arch; then pkg_install openssh; else pkg_install openssh-server; fi
fi
user="$(desk_user)"
if [[ -z "$user" ]]; then
  warn "desk.base: no developer user yet (the desk group names it; install with sudo from the developer's account)"
else
  ok "desk.base: desk for $user"
fi
