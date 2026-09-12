# anakut-worker capability: access.tunnel

log "access.tunnel: installing cloudflared"
if pacman -Si cloudflared >/dev/null 2>&1; then
  run pacman -S --needed --noconfirm cloudflared
else
  run paru -S --needed --noconfirm cloudflared-bin
fi

domain="$(cap_config domain)"
if [[ -z "$domain" ]]; then
  warn "no domain set; re-enable with: aw enable access.tunnel --domain worker.example.com"
fi

if sec_has CLOUDFLARE_TUNNEL_TOKEN; then
  log "access.tunnel: installing service from stored token"
  token="$(sec_get CLOUDFLARE_TUNNEL_TOKEN)"
  run cloudflared service install "$token"
  run systemctl enable --now cloudflared
else
  warn "no CLOUDFLARE_TUNNEL_TOKEN in the secret store"
  info "in Cloudflare Zero Trust: Networks > Tunnels > Create tunnel"
  info "then: sudo aw secrets set CLOUDFLARE_TUNNEL_TOKEN <token> && sudo aw apply"
fi
ok "access.tunnel ready (still no inbound ports)"
