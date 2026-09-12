# alwayswork capability: dev.toolchain

log "dev.toolchain: installing language runtimes"
run pacman -S --needed --noconfirm nodejs npm python python-pip git

if ! have pnpm; then
  log "dev.toolchain: installing pnpm"
  run npm install -g pnpm
fi

ok "toolchain ready: node $(node --version 2>/dev/null), python $(python --version 2>&1 | awk '{print $2}')"
