# anakut-worker capability: control.join
# Installs a systemd unit that keeps the control agent running.

url="$(cap_config url)"
if [[ -n "$url" ]]; then
  cfg_set_str '.control.url' "$url"
fi

aw_write /etc/systemd/system/anakut-worker-agent.service <<'UNIT'
[Unit]
Description=Anakut Worker control agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/anakut-worker agent 60
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

run systemctl daemon-reload
run systemctl enable --now anakut-worker-agent.service
ok "control agent installed"
