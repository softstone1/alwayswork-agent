# alwayswork capability: runtime.podman

log "runtime.podman: installing podman"
pkg_install podman podman-compose

if cfg_bool '.engine.rootless' true; then
  log "runtime.podman: enabling rootless socket for ${SUDO_USER:-root}"
  local_user="${SUDO_USER:-}"
  if [[ -n "$local_user" && "$local_user" != "root" ]]; then
    run loginctl enable-linger "$local_user" 2>/dev/null || true
    run systemctl --user -M "${local_user}@" enable --now podman.socket 2>/dev/null || true
  else
    warn "enable rootless mode after logging in as your user: systemctl --user enable --now podman.socket"
  fi
fi

# Reboot persistence: unlike Docker, daemonless Podman does not restart
# containers on boot by itself (--restart is only honored under systemd).
# This system unit starts every alwayswork-managed container that is not
# running. It runs as root because the agent itself runs as root (see
# lib/engine.sh — no user switching), so this is the same container storage
# the agent writes to. The rootless podman socket enabled above is for the
# human operator's own containers, not the agent's.
podman_bin="$(command -v podman)"
aw_write /etc/systemd/system/alwayswork-containers.service <<UNIT
[Unit]
Description=AlwaysWork: start managed containers after boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=$podman_bin

[Service]
Type=oneshot
ExecStart=/bin/sh -c '$podman_bin ps --all --filter label=alwayswork=true --filter status=exited --format "{{.Names}}" | xargs -r $podman_bin start'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
run systemctl daemon-reload
run systemctl enable alwayswork-containers.service

cfg_set_str '.engine.runtime' podman
ok "podman installed"
