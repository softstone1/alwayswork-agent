# alwayswork capability: control.join
# Installs a systemd unit that keeps the control agent running.

url="$(cap_config url)"
if [[ -n "$url" ]]; then
  cfg_set_str '.control.url' "$url"
fi

aw_write /etc/systemd/system/alwayswork-agent.service <<'UNIT'
[Unit]
Description=AlwaysWork control agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/alwayswork agent 60
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

run systemctl daemon-reload
run systemctl enable --now alwayswork-agent.service
ok "control agent installed"
