# alwayswork capability: control.join (remove)
run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
run systemctl disable --now alwayswork-provision.timer 2>/dev/null || true
run rm -f /etc/systemd/system/alwayswork-agent.service \
          /etc/systemd/system/alwayswork-provision.service \
          /etc/systemd/system/alwayswork-provision.timer \
          /etc/udev/rules.d/90-alwayswork-provision.rules
run systemctl daemon-reload
run udevadm control --reload-rules 2>/dev/null || true
warn "control agent removed; device identity and enrollment were kept"
