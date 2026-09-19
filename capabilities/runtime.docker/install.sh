# alwayswork capability: runtime.docker

log "runtime.docker: installing docker"
pkg_install docker docker-compose

if [[ -f /etc/docker/daemon.json ]]; then
  warn "runtime.docker: /etc/docker/daemon.json exists; leaving it untouched"
else
  log "runtime.docker: writing hardened daemon.json"
  aw_write /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true
}
JSON
fi

# Remember whether docker was the operator's before we touched it, so
# disabling the capability later never stops a daemon we did not start.
if have ledger_service_before; then ledger_service_before docker.service || true; fi
run systemctl enable --now docker
cfg_set_str '.engine.runtime' docker
ok "docker installed and enabled"
