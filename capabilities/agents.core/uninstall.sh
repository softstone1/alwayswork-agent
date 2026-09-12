# alwayswork capability: agents.core (remove)
run rm -f /etc/systemd/system/alwayswork-agent@.service
run rm -f /usr/local/bin/alwayswork-agent
run systemctl daemon-reload
warn "workspaces under /srv/alwayswork/agents were kept"
