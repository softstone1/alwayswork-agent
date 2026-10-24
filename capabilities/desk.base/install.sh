# alwayswork capability: desk.base
#
# What makes a node a desk (lib/desk.sh). The headless always-on policy is
# undone here, because core may have applied it before the profile was known.
# The terminal sshd is not installed: it exists only while a grant is open.

log "desk.base: leaving power management to the desktop"
if [[ "$(systemctl is-enabled sleep.target 2>/dev/null || true)" == "masked" || -f "$(power_logind_conf)" ]]; then
  power_unapply
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
