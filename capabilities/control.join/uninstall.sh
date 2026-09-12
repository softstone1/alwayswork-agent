# anakut-worker capability: control.join (remove)
run systemctl disable --now anakut-worker-agent.service 2>/dev/null || true
run rm -f /etc/systemd/system/anakut-worker-agent.service
run systemctl daemon-reload
warn "control agent removed; device identity and enrollment were kept"
