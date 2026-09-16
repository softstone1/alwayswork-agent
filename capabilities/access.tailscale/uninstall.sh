# alwayswork capability: access.tailscale (remove)
run tailscale down 2>/dev/null || true
run systemctl disable --now tailscaled 2>/dev/null || true
# Close the interface rule fw_allow_iface opened at install; without this the
# allow rule stays live while the tracker claims it is gone.
fw_close_iface "$CAP_ID" "tailscale0" 2>/dev/null || true
