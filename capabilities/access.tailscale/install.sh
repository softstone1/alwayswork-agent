# alwayswork capability: access.tailscale

log "access.tailscale: installing tailscale"
# Tailscale is not in Debian's default repositories: apt fails loudly here,
# and the operator gets the documented next step instead of a dead install.
if ! pkg_install tailscale; then
  if distro_is_debian; then
    warn "tailscale is not in this distro's default repositories"
    info "add Tailscale's apt repository (https://tailscale.com/download/linux), then: sudo aw apply"
    return 0
  fi
  die "failed to install tailscale"
fi
run systemctl enable --now tailscaled
fw_allow_iface "$CAP_ID" tailscale0 || true

if tailscale status >/dev/null 2>&1; then
  ok "tailscale already connected"
else
  info "authenticate this node: sudo tailscale up"
fi
ok "tailscale installed"
