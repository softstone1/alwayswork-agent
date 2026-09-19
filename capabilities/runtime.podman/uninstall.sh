# alwayswork capability: runtime.podman (remove)
run systemctl disable alwayswork-containers.service 2>/dev/null || true
run rm -f /etc/systemd/system/alwayswork-containers.service
run systemctl daemon-reload 2>/dev/null || true
# The DNS allowance for the workload subnet goes with the capability.
if declare -F fw_close_subnet_port >/dev/null; then
  subnet="$(podman network inspect alwayswork --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null || true)"
  if [[ "$subnet" =~ ^[0-9./]+$ ]]; then
    fw_close_subnet_port runtime.podman "$subnet" 53 udp >/dev/null 2>&1 || true
    fw_close_subnet_port runtime.podman "$subnet" 53 tcp >/dev/null 2>&1 || true
    fw_close_forward_from runtime.podman "$subnet" >/dev/null 2>&1 || true
  fi
fi
warn "removing runtime.podman leaves images and volumes in place"
