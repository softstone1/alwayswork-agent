# shellcheck shell=bash
# alwayswork · curated app/tool catalog.
#
# Ships catalog/apps.yaml; an operator can extend or override it with
# /etc/alwayswork/apps.yaml. User entries are searched first.

apps_file_shipped() { printf '%s\n' "$AW_ROOT/catalog/apps.yaml"; }
apps_file_user()    { printf '%s\n' "$AW_ETC/apps.yaml"; }

apps_file_for() {
  local id="$1" u
  u="$(apps_file_user)"
  if [[ -f "$u" ]] && yq -e ".apps.\"$id\"" "$u" >/dev/null 2>&1; then
    printf '%s\n' "$u"; return 0
  fi
  printf '%s\n' "$(apps_file_shipped)"
}

app_ids() {
  local f
  f="$(apps_file_shipped)"
  [[ -f "$f" ]] && yq -r '.apps | keys[]' "$f" 2>/dev/null
  f="$(apps_file_user)"
  [[ -f "$f" ]] && yq -r '.apps | keys[]' "$f" 2>/dev/null
}

app_exists() {
  local f
  f="$(apps_file_for "$1")"
  [[ -f "$f" ]] && yq -e ".apps.\"$1\"" "$f" >/dev/null 2>&1
}

app_meta() {
  local id="$1" path="$2" f
  f="$(apps_file_for "$id")"
  yq -r ".apps.\"$id\"$path // \"\"" "$f" 2>/dev/null || true
}

app_manager()  { app_meta "$1" '.manager'; }
app_category() { app_meta "$1" '.category'; }
app_name()     { app_meta "$1" '.name'; }
app_desc()     { app_meta "$1" '.description'; }

app_packages() {
  local id="$1" f
  f="$(apps_file_for "$id")"
  yq -r ".apps.\"$id\".packages[]" "$f" 2>/dev/null || true
}

app_is_installed() {
  local id="$1" manager pkg
  manager="$(app_manager "$id")"
  pkg="$(app_packages "$id" | head -1)"
  [[ -n "$pkg" ]] || return 1
  case "$manager" in
    pacman|paru) pkg_is_installed "$pkg" ;;
    npm)         have npm && npm ls -g --depth=0 2>/dev/null | grep -q -- "$(printf '%s' "$pkg" | sed 's#^@[^/]*/##')" ;;
    pipx)        have pipx && pipx list --short 2>/dev/null | grep -qi -- "$pkg" ;;
    *)           return 1 ;;
  esac
}

app_install() {
  local id="$1" manager
  app_exists "$id" || die "unknown app: $id (try: aw app list)"
  manager="$(app_manager "$id")"
  local -a pkgs=()
  mapfile -t pkgs < <(app_packages "$id")
  (( "${#pkgs[@]}" > 0 )) || die "app '$id' declares no packages"

  log "app: installing $id via $manager"
  case "$manager" in
    pacman) pkg_install "${pkgs[@]}" ;;
    paru)
      # No AUR off Arch: refuse loudly instead of feeding AUR package names
      # (e.g. cloudflared-bin) to apt, which would fail obscurely.
      distro_is_arch || die "app '$id' is AUR-only (paru); the AUR exists only on Arch-based systems"
      run_paru -S --needed --noconfirm "${pkgs[@]}" ;;
    npm)
      have npm || pkg_install nodejs npm
      run npm install -g "${pkgs[@]}"
      ;;
    pipx)
      have pipx || pkg_install python-pipx
      run pipx install "${pkgs[@]}"
      ;;
    *) die "unknown manager '$manager' for app '$id'" ;;
  esac
  ok "app $id installed"
}

app_remove() {
  local id="$1" manager
  app_exists "$id" || die "unknown app: $id"
  manager="$(app_manager "$id")"
  local -a pkgs=()
  mapfile -t pkgs < <(app_packages "$id")
  (( "${#pkgs[@]}" > 0 )) || die "app '$id' declares no packages"

  log "app: removing $id via $manager"
  case "$manager" in
    pacman|paru)
      if distro_is_arch; then
        run pacman -Rns --noconfirm "${pkgs[@]}" 2>/dev/null || run pacman -Rdd --noconfirm "${pkgs[@]}"
      else
        pkg_remove "${pkgs[@]}"
      fi ;;
    npm)         run npm uninstall -g "${pkgs[@]}" ;;
    pipx)        run pipx uninstall "${pkgs[@]}" ;;
    *) die "unknown manager '$manager' for app '$id'" ;;
  esac
  ok "app $id removed"
}

app_list() {
  local category="${1:-}" id cat marker
  printf '%s%-16s %-12s %-10s %s%s\n' "$C_BOLD" "ID" "CATEGORY" "INSTALLED" "DESCRIPTION" "$C_RESET"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    cat="$(app_category "$id")"
    [[ -n "$category" && "$cat" != "$category" ]] && continue
    if app_is_installed "$id"; then marker="yes"; else marker="-"; fi
    printf '%-16s %-12s %-10s %s\n' "$id" "$cat" "$marker" "$(app_desc "$id")"
  done < <(app_ids | sort -u)
}

app_search() {
  local term="$1" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if printf '%s %s\n' "$id" "$(app_desc "$id")" | grep -qi -- "$term"; then
      printf '%-16s %-12s %s\n' "$id" "$(app_category "$id")" "$(app_desc "$id")"
    fi
  done < <(app_ids | sort -u)
}
