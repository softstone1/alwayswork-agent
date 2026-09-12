# anakut-worker capability: access.tailscale (remove)
run tailscale down 2>/dev/null || true
run systemctl disable --now tailscaled 2>/dev/null || true
fw_close_port "$CAP_ID" "iface:tailscale0" "-" 2>/dev/null || true
