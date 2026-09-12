# alwayswork capability: runtime.docker (remove)
warn "removing runtime.docker stops the docker daemon but keeps images and volumes"
run systemctl disable --now docker 2>/dev/null || true
