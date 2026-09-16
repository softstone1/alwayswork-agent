# alwayswork capability: runtime.podman (remove)
run systemctl disable alwayswork-containers.service 2>/dev/null || true
run rm -f /etc/systemd/system/alwayswork-containers.service
run systemctl daemon-reload 2>/dev/null || true
warn "removing runtime.podman leaves images and volumes in place"
