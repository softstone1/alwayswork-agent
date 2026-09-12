# anakut-worker capability: runtime.docker

log "runtime.docker: installing docker"
run pacman -S --needed --noconfirm docker docker-compose

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

run systemctl enable --now docker
cfg_set_str '.engine.runtime' docker
ok "docker installed and enabled"
