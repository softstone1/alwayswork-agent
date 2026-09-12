# alwayswork capability: core (remove)
if systemctl is-enabled --quiet alwayswork-update.timer 2>/dev/null; then
  run systemctl disable --now alwayswork-update.timer 2>/dev/null || true
fi
run rm -f /etc/systemd/system/alwayswork-update.service
run rm -f /etc/systemd/system/alwayswork-update.timer
run rm -f /etc/sysctl.d/99-alwayswork.conf
run systemctl daemon-reload
warn "core removed; firewall, firewall rules and secrets were left in place"
