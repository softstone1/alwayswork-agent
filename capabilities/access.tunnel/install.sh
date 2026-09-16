# alwayswork capability: access.tunnel

log "access.tunnel: installing cloudflared"
if pacman -Si cloudflared >/dev/null 2>&1; then
  run pacman -S --needed --noconfirm cloudflared
else
  run_paru -S --needed --noconfirm cloudflared-bin
fi

domain="$(cap_config domain)"
if [[ -z "$domain" ]]; then
  warn "no domain set; re-enable with: aw enable access.tunnel --domain worker.example.com"
fi

if sec_has CLOUDFLARE_TUNNEL_TOKEN; then
  token="$(sec_get CLOUDFLARE_TUNNEL_TOKEN)"
  bin="$(command -v cloudflared)"
  unit=/etc/systemd/system/cloudflared.service
  token_file=/etc/cloudflared/token
  # The token is never passed on a command line (visible in ps) or echoed by
  # --dry-run: it lives in a 0600 file from the moment of creation, and the
  # systemd unit references it via --token-file.
  write_token() {
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '    [dry-run] write %s (0600)\n' "$token_file" >&2
    else
      ensure_dir /etc/cloudflared
      ( umask 077; printf '%s' "$token" > "$token_file" )
      chmod 600 "$token_file"
    fi
  }
  write_unit() {
    aw_write "$unit" <<UNIT
[Unit]
Description=AlwaysWork Cloudflare tunnel
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$bin tunnel --no-autoupdate --token-file $token_file run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  }
  current="$(cat "$token_file" 2>/dev/null || true)"
  if [[ ! -f "$unit" ]]; then
    # Idempotent adoption: a unit left behind by an older install (or deleted
    # and recreated tunnel) heals itself instead of aborting the reconcile.
    if [[ -z "$current" ]]; then
      log "access.tunnel: installing service from stored token"
    else
      log "access.tunnel: adopting existing token file"
    fi
    write_token
    write_unit
    run systemctl daemon-reload
    run systemctl enable --now cloudflared
  elif [[ "$current" != "$token" ]]; then
    log "access.tunnel: tunnel token changed; updating the service"
    write_token
    run systemctl restart cloudflared
  else
    info "cloudflared service already installed with the current token"
    run systemctl enable --now cloudflared 2>/dev/null || true
  fi
else
  warn "no CLOUDFLARE_TUNNEL_TOKEN in the secret store"
  info "in Cloudflare Zero Trust: Networks > Tunnels > Create tunnel"
  info "then: sudo aw secrets set CLOUDFLARE_TUNNEL_TOKEN <token> && sudo aw apply"
fi
ok "access.tunnel ready (still no inbound ports)"
