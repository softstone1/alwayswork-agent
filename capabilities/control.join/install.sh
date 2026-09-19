# alwayswork capability: control.join
# Installs a systemd unit that keeps the control agent running.

url="$(cap_config url)"
if [[ -n "$url" ]]; then
  cfg_set_str '.control.url' "$url"
fi

aw_write /etc/systemd/system/alwayswork-agent.service <<'UNIT'
[Unit]
Description=AlwaysWork control agent
# time-sync: the agent signs timestamped requests and refuses to until the
# clock is trusted, so let NTP settle first where the target exists.
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=simple
ExecStart=/usr/local/bin/alwayswork agent 60
# on-failure (not always): a clean exit — e.g. after the operator revokes this
# worker — must stop the agent instead of restarting it into a revoke loop.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

run systemctl daemon-reload
run systemctl enable --now alwayswork-agent.service
ok "control agent installed"

# First-boot / headless provisioning: on every boot, `aw provision` resumes an
# interrupted decommission, enrolls from a USB provisioning stick when one is
# present, or registers/checks a pending claim for console approval. The timer
# disables itself once the node is enrolled.
aw_write /etc/systemd/system/alwayswork-provision.service <<'UNIT'
[Unit]
Description=AlwaysWork first-boot provisioning (USB / pending claim)
After=network-online.target
Wants=network-online.target
Before=alwayswork-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alwayswork provision
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

aw_write /etc/systemd/system/alwayswork-provision.timer <<'UNIT'
[Unit]
Description=Retry AlwaysWork provisioning until the node is enrolled

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

run systemctl daemon-reload
run systemctl enable --now alwayswork-provision.timer
ok "provisioning timer installed"
