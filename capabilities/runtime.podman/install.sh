# anakut-worker capability: runtime.podman

log "runtime.podman: installing podman"
run pacman -S --needed --noconfirm podman podman-compose

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

cfg_set_str '.engine.runtime' podman
ok "podman installed"
