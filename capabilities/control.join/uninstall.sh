# alwayswork capability: control.join (remove)
run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
run rm -f /etc/systemd/system/alwayswork-agent.service
run systemctl daemon-reload
warn "control agent removed; device identity and enrollment were kept"
