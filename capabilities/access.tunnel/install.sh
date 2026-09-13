# alwayswork capability: access.tunnel

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
  token="$(sec_get CLOUDFLARE_TUNNEL_TOKEN)"
  # Idempotent: 'cloudflared service install' refuses to run twice, and apply
  # runs the install hook on every reconcile. Adopt an existing service and
  # only touch it when the token actually changed.
  if systemctl list-unit-files cloudflared.service >/dev/null 2>&1 && [[ -f /etc/cloudflared/token ]]; then
    info "cloudflared service already installed"
    if [[ "$(cat /etc/cloudflared/token 2>/dev/null || true)" != "$token" ]]; then
      log "access.tunnel: tunnel token changed; updating the service"
      if [[ "$DRY_RUN" != "1" ]]; then
        printf '%s' "$token" > /etc/cloudflared/token
        chmod 600 /etc/cloudflared/token
      fi
      run systemctl restart cloudflared
    fi
  else
    log "access.tunnel: installing service from stored token"
    run cloudflared service install "$token"
  fi
  run systemctl enable --now cloudflared
else
  warn "no CLOUDFLARE_TUNNEL_TOKEN in the secret store"
  info "in Cloudflare Zero Trust: Networks > Tunnels > Create tunnel"
  info "then: sudo aw secrets set CLOUDFLARE_TUNNEL_TOKEN <token> && sudo aw apply"
fi
ok "access.tunnel ready (still no inbound ports)"
