# alwayswork capability: desk.warp
#
# The client comes from the distribution where it is packaged (CachyOS ships
# cloudflare-warp-bin) and from Cloudflare's signed apt repository on Debian
# and Ubuntu. Enrolment needs no secret: the organization arrives in the
# signed delivery and the developer authenticates with their own identity.

warp_install_debian() {
  local keyring=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  local list=/etc/apt/sources.list.d/cloudflare-client.list
  if [[ ! -f "$keyring" ]]; then
    log "desk.warp: adding Cloudflare's client keyring"
    run sh -c "curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o $keyring"
    run chmod 644 "$keyring"
  fi
  if [[ ! -f "$list" ]]; then
    aw_write "$list" <<REPO
# Managed by alwayswork (desk.warp)
deb [signed-by=$keyring] https://pkg.cloudflareclient.com/ $(. /etc/os-release && echo "${VERSION_CODENAME:-noble}") main
REPO
    run apt-get update -q
  fi
  pkg_install cloudflare-warp
}

if have warp-cli; then
  info "desk.warp: the Cloudflare One Client is already installed"
elif distro_is_arch; then
  if pacman -Si cloudflare-warp-bin >/dev/null 2>&1; then
    pkg_install cloudflare-warp-bin
  else
    run_paru -S --needed --noconfirm cloudflare-warp-bin
  fi
elif distro_is_debian; then
  warp_install_debian
else
  distro_require
fi

run systemctl enable --now warp-svc
org="$(cfg_get '.desk.organization' '')"
if [[ -n "$org" ]]; then
  desk_warp_enrol "$org" || warn "desk.warp: could not write the enrolment file"
else
  info "desk.warp: organization arrives with the first desk delivery"
fi
ok "desk.warp ready"
