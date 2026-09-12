# alwayswork capability: obs.uptime

name="alwayswork-uptime"
engine_present || die "obs.uptime needs a container runtime"
engine_rm "$name" 2>/dev/null || true
engine_pull "louislam/uptime-kuma:1"
engine_run "$name" "louislam/uptime-kuma:1" \
  -v "alwayswork-uptime:/app/data" \
  -p "127.0.0.1:3001:3001"
ok "Uptime Kuma on http://127.0.0.1:3001 (localhost only)"
