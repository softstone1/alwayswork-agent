# anakut-worker capability: core (remove)
if systemctl is-enabled --quiet anakut-worker-update.timer 2>/dev/null; then
  run systemctl disable --now anakut-worker-update.timer 2>/dev/null || true
fi
run rm -f /etc/systemd/system/anakut-worker-update.service
run rm -f /etc/systemd/system/anakut-worker-update.timer
run rm -f /etc/sysctl.d/99-anakut-worker.conf
run systemctl daemon-reload
warn "core removed; firewall, firewall rules and secrets were left in place"
