# alwayswork capability: obs.uptime

name="alwayswork-uptime"
image="louislam/uptime-kuma:1"
engine_present || die "obs.uptime needs a container runtime"
# Idempotent: adopt an existing container instead of destroying and re-pulling
# it on every reconcile; the data volume survives either way.
if engine_exists "$name"; then
  info "$name already present; adopting (not recreating)"
  engine_start "$name" 2>/dev/null || true
else
  engine_pull "$image"
  engine_run "$name" "$image" \
    -v "alwayswork-uptime:/app/data" \
    -p "127.0.0.1:3001:3001"
fi
ok "Uptime Kuma on http://127.0.0.1:3001 (localhost only)"
