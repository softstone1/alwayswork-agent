# anakut-worker capability: agents.core (remove)
run rm -f /etc/systemd/system/anakut-worker-agent@.service
run rm -f /usr/local/bin/anakut-worker-agent
run systemctl daemon-reload
warn "workspaces under /srv/anakut-worker/agents were kept"
