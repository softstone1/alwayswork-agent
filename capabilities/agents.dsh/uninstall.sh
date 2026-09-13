# alwayswork capability: agents.dsh
run systemctl disable --now alwayswork-webui.service 2>/dev/null || true
run rm -f /etc/systemd/system/alwayswork-webui.service
run systemctl daemon-reload
run rm -f "$AW_STATE/webui.json"
ok "node web ui removed"
