# alwayswork capability: desk.base (remove)
desk_terminal_close "desk.base removed"
run rm -f /etc/systemd/resolved.conf.d/90-alwayswork-desk.conf
run systemctl try-restart systemd-resolved 2>/dev/null || true
