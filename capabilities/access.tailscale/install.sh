# alwayswork capability: access.tailscale

log "access.tailscale: installing tailscale"
run pacman -S --needed --noconfirm tailscale
run systemctl enable --now tailscaled
fw_allow_iface "$CAP_ID" tailscale0 || true

if tailscale status >/dev/null 2>&1; then
  ok "tailscale already connected"
else
  info "authenticate this node: sudo tailscale up"
fi
ok "tailscale installed"
