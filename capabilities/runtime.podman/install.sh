# alwayswork capability: runtime.podman

log "runtime.podman: installing podman"
pkg_install podman podman-compose

# userns=auto (the workload isolation contract, SYSTEM_SPEC §12) hands each
# container a private uid/gid range taken from the `containers` entry in
# /etc/subuid and /etc/subgid. Neither distro family ships that entry.
#
# The owner must be a real account: shadow >= 4.14 (Arch/CachyOS) resolves the
# owner with getpwnam and silently returns no ranges for an unknown name —
# podman then fails with "no subuid ranges found for user containers". A
# locked system user with no home, never logged into, satisfies it.
podman_ensure_userns_ranges() {
  local f
  if ! getent passwd containers >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] create system user containers (owner of the userns ranges)\n' >&2
    else run useradd --system --no-create-home --shell /usr/sbin/nologin --user-group containers 2>/dev/null \
      || run useradd --system --no-create-home --shell /usr/bin/nologin --user-group containers \
      || warn "runtime.podman: could not create the containers user; userns=auto may find no ranges"; fi
  fi
  for f in /etc/subuid /etc/subgid; do
    if [[ -f "$f" ]] && grep -q '^containers:' "$f"; then continue; fi
    if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] append containers:2147483647:2147483648 to %s\n' "$f" >&2; continue; fi
    if have ledger_file_before; then ledger_file_before "$f" || warn "ledger: could not record $f"; fi
    printf 'containers:2147483647:2147483648\n' >> "$f"
  done
}
podman_ensure_userns_ranges
ok "user-namespace ranges for userns=auto present"

# One node-local network for workloads: containers resolve each other by
# name (the harness reaches the browser at alwayswork-browser:9222) while
# nothing is published to the host except what each workload puts on
# 127.0.0.1. Idempotent.
if [[ "$DRY_RUN" == "1" ]]; then
  info "runtime.podman: dry-run — would create the 'alwayswork' network"
elif ! podman network exists alwayswork 2>/dev/null; then
  run podman network create alwayswork >/dev/null && ok "network 'alwayswork' created"
fi

# A default-deny host firewall also denies the containers' DNS: aardvark-dns
# listens on the bridge gateway, so every lookup from a workload is an
# inbound packet on that interface (`[UFW BLOCK] IN=podmanN … DPT=53`). Open
# 53/udp+tcp from the workload subnet only — nothing else on the host is
# reachable from a container.
podman_allow_workload_dns() {
  local subnet
  [[ "$DRY_RUN" == "1" ]] && { info "runtime.podman: dry-run — would allow DNS from the workload subnet"; return 0; }
  subnet="$(podman network inspect alwayswork --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null)" || true
  [[ "$subnet" =~ ^[0-9./]+$ ]] || { warn "runtime.podman: could not read the workload subnet; containers may not resolve DNS through a strict firewall"; return 0; }
  if declare -F fw_active >/dev/null && fw_active; then
    fw_allow_subnet_port runtime.podman "$subnet" 53 udp >/dev/null 2>&1 || true
    fw_allow_subnet_port runtime.podman "$subnet" 53 tcp >/dev/null 2>&1 || true
    ok "workload DNS allowed from $subnet"
  fi
}
podman_allow_workload_dns

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
