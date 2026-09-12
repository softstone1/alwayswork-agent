# alwayswork capability: access.tunnel (remove)
run systemctl disable --now cloudflared 2>/dev/null || true
run cloudflared service uninstall 2>/dev/null || true
