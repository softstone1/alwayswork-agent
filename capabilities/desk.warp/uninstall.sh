# alwayswork capability: desk.warp (remove)
# The client stays installed (the developer may use it on their own); only
# the organization this node enrolled it into is withdrawn.
if [[ -f "$DESK_WARP_MDM" ]] && grep -q 'managed by alwayswork' "$DESK_WARP_MDM" 2>/dev/null; then
  run rm -f "$DESK_WARP_MDM"
  run systemctl restart warp-svc 2>/dev/null || true
fi
