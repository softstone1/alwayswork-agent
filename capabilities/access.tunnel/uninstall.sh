# alwayswork capability: access.tunnel (remove)
run systemctl disable --now cloudflared 2>/dev/null || true
run rm -f /etc/systemd/system/cloudflared.service
# The token file holds the tunnel credential: remove it on uninstall so a
# disabled tunnel leaves no secret behind.
run rm -f /etc/cloudflared/token
run systemctl daemon-reload 2>/dev/null || true
