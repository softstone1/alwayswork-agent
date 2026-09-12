# shellcheck shell=bash
# alwayswork · remove what is no longer used.
#
# Every step is a toggle under cleanup.* so a box can be as aggressive or
# as conservative as it needs to be.

cleanup_apply() {
  if cfg_bool '.cleanup.orphans' true; then
    log "clean: removing orphaned packages"
    local -a orphans=()
    mapfile -t orphans < <(pacman -Qtdq 2>/dev/null || true)
    if (( "${#orphans[@]}" > 0 )); then
      run pacman -Rns --noconfirm "${orphans[@]}"
    else
      info "no orphaned packages"
    fi
  fi

  if cfg_bool '.cleanup.package_cache' true; then
    log "clean: trimming package cache"
    if have paccache; then
      run paccache -rk2
    else
      run pacman -Sc --noconfirm
    fi
  fi

  if cfg_bool '.cleanup.journal' true && have journalctl; then
    log "clean: vacuuming the system journal"
    run journalctl --vacuum-size=200M >/dev/null
  fi

  if cfg_bool '.cleanup.containers' true && engine_present; then
    log "clean: pruning unused container images"
    run "$(engine_bin)" image prune -f
  fi

  if cfg_bool '.cleanup.volumes' false && engine_present; then
    log "clean: pruning unused volumes (destructive)"
    run "$(engine_bin)" volume prune -f
  fi

  if cfg_bool '.cleanup.tmp' true; then
    log "clean: removing stale temporary files"
    local age
    age="$(cfg_get '.cleanup.max_age_days' 2)"
    run find /tmp -mindepth 1 -maxdepth 1 -mtime "+${age}" -exec rm -rf {} + 2>/dev/null || true
  fi

  ok "cleanup complete"
}

cleanup_status() {
  local orphans
  orphans="$(pacman -Qtdq 2>/dev/null | wc -l)"
  kv "orphan packages" "$orphans"
  if have paccache; then kv "paccache" "present"; else kv "paccache" "absent (pacman -Sc)"; fi
  if engine_present; then
    local imgs
    imgs="$("$(engine_bin)" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | wc -l || echo 0)"
    kv "container images" "$imgs"
  fi
}
