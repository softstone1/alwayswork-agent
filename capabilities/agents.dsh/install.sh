# alwayswork capability: agents.dsh
# Installs a systemd unit that serves this node's DeepSeek Harness web UI on
# loopback, trusted for the public hostname the tunnel publishes it under. The
# host is written to the state file the control agent reports on heartbeat.

dsh_bin="$(cap_config dsh)"
[[ -n "$dsh_bin" ]] || dsh_bin="$(command -v dsh 2>/dev/null || true)"
[[ -n "$dsh_bin" && -x "$dsh_bin" ]] || die "no executable dsh; set one with: aw enable agents.dsh --dsh /path/to/dsh"

# Same account rule as the preflight: explicit, recorded, then the harness owner.
ds_user="$(cap_config user)"
[[ -n "$ds_user" ]] || ds_user="$(cfg_get '.agent.user' '')"
[[ -n "$ds_user" ]] || ds_user="$(stat -Lc %U "$dsh_bin" 2>/dev/null || true)"
id "$ds_user" >/dev/null 2>&1 || die "no such user: $ds_user"
ds_home="$(getent passwd "$ds_user" | cut -d: -f6)"

port="$(cap_config port)"
[[ -n "$port" ]] || port="$(cfg_get '.expose.webUi.port' 3080)"
port="${port:-3080}"

# The public name: explicit wins, otherwise <hostname>.<base domain>. The
# control plane can pin it later via .expose.webUi.host.
host="$(cap_config host)"
[[ -n "$host" ]] || host="$(cfg_get '.expose.webUi.host' '')"
if [[ -z "$host" ]]; then
  base="$(cfg_get '.expose.webUi.baseDomain' 'alwayswork.space')"
  host="$(hostname).$base"
fi

# The unit needs node on PATH; the harness CLI is a node script.
dsh_dir="$(dirname "$dsh_bin")"
node_dir=""
for candidate in "$ds_home/.local/node/bin" /usr/local/bin /usr/bin; do
  if [[ -x "$candidate/node" ]]; then node_dir="$candidate"; break; fi
done
svc_path="$dsh_dir:$ds_home/.local/bin:/usr/local/bin:/usr/bin"
[[ -n "$node_dir" ]] && svc_path="$node_dir:$svc_path"

log "agents.dsh: serving this node's UI on 127.0.0.1:$port for $ds_user"
aw_write /etc/systemd/system/alwayswork-webui.service <<UNIT
[Unit]
Description=AlwaysWork node web UI (DeepSeek Harness)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ds_user
WorkingDirectory=$ds_home
Environment=HOME=$ds_home
Environment=PATH=$svc_path
ExecStart=$dsh_bin web --host 127.0.0.1 --port $port --no-open --trusted-host $host
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

run systemctl daemon-reload
run systemctl enable --now alwayswork-webui.service

# Reported on heartbeat so the console can link straight to it.
aw_write "$AW_STATE/webui.json" <<JSON
{"host":"$host","port":$port}
JSON
chmod 644 "$AW_STATE/webui.json" 2>/dev/null || true
ok "node web ui: https://$host/ -> 127.0.0.1:$port"
