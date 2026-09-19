# shellcheck shell=bash
# alwayswork · distro abstraction: detection + package operations.
#
# Sourced by bin/alwayswork right after lib/core.sh; never executed directly.
# Only abstracts what the agent actually uses — package install/remove/query,
# system upgrade, and orphan/cache cleanup — nothing speculative.
#
# Families: `arch` (Arch, CachyOS, EndeavourOS, Manjaro, …) and `debian`
# (Debian, Ubuntu, Kali, Pop!_OS, …). Anything else is `unknown` and refuses
# loudly via distro_require, naming the detected ID.
#
# Needs from the sourcer: die, warn, info, have, run (lib/core.sh provides these).
# Tests override the os-release path with AW_OS_RELEASE.

# --- detection ---------------------------------------------------------------

_distro_os_release() { printf '%s\n' "${AW_OS_RELEASE:-/etc/os-release}"; }

# distro_id — the ID= value from os-release (empty when unavailable).
distro_id() {
  local f; f="$(_distro_os_release)"
  [[ -f "$f" ]] || return 0
  # Subshell: sourcing os-release must not leak its variables or `set -u`
  # failures (ID can be unset) into the caller.
  # shellcheck disable=SC1090
  ( . "$f" 2>/dev/null; printf '%s' "${ID:-}" )
}

# distro_id_like — the ID_LIKE= value from os-release (empty when unavailable).
distro_id_like() {
  local f; f="$(_distro_os_release)"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  ( . "$f" 2>/dev/null; printf '%s' "${ID_LIKE:-}" )
}

distro_pretty() {
  local f; f="$(_distro_os_release)"
  [[ -f "$f" ]] || { printf 'unknown\n'; return 0; }
  # shellcheck disable=SC1090
  ( . "$f" 2>/dev/null; printf '%s\n' "${PRETTY_NAME:-${ID:-unknown}}" )
}

# distro_family — `arch`, `debian`, or `unknown`. ID wins; ID_LIKE is the
# fallback for derivatives that only declare their parent.
distro_family() {
  local id like
  id="$(distro_id)"; like="$(distro_id_like)"
  case "$id" in
    arch|cachyos|endeavouros|manjaro|garuda|artix) printf 'arch\n'; return 0 ;;
    debian|ubuntu|kali|raspbian|pop|linuxmint|elementary|zorin|mx)
      printf 'debian\n'; return 0 ;;
  esac
  case " $like " in
    *" arch "*)                printf 'arch\n'; return 0 ;;
    *" debian "*|*" ubuntu "*) printf 'debian\n'; return 0 ;;
  esac
  printf 'unknown\n'
}

distro_is_arch()   { [[ "$(distro_family)" == "arch" ]]; }
distro_is_debian() { [[ "$(distro_family)" == "debian" ]]; }

# distro_require — die on unsupported distros, naming what was detected.
distro_require() {
  local fam; fam="$(distro_family)"
  [[ "$fam" != "unknown" ]] && return 0
  die "unsupported Linux distribution (ID='$(distro_id)'; $(_distro_os_release)): alwayswork supports Arch- and Debian-family systems"
}

# --- package-name translation -------------------------------------------------
# distro_pkg <arch-name> — print the package name this distro's manager uses.
# The agent's package lists are written in Arch names; only names that
# actually differ are mapped. Arch-only packages are handled at the call
# site (they are skipped with an explanatory message, not mistranslated).
distro_pkg() {
  local name="$1"
  if distro_is_debian; then
    case "$name" in
      python)          printf 'python3\n' ;;
      python-pip)      printf 'python3-pip\n' ;;
      python-pipx)     printf 'pipx\n' ;;
      docker)          printf 'docker.io\n' ;;
      docker-compose)  printf 'docker-compose-plugin\n' ;;
      *)               printf '%s\n' "$name" ;;
    esac
    return 0
  fi
  printf '%s\n' "$name"
}

# --- package operations -------------------------------------------------------

# apt-get update, at most once per process: every pkg_install on Debian would
# otherwise re-download the package lists.
_distro_apt_update() {
  [[ "${_DISTRO_APT_UPDATED:-0}" == "1" ]] && return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  _DISTRO_APT_UPDATED=1
}

# pkg_install <pkgs...> — install system packages (translated via distro_pkg).
pkg_install() {
  local -a pkgs=() p
  (( $# > 0 )) || return 0
  # The agent's own installs pass the package-manager guard (lib/updates.sh).
  export AW_PKG_GUARD_OK=1
  # Footprint ledger: which of these were already here (lib/ledger.sh).
  if have ledger_pkg_before; then
    ledger_pkg_before "$@" || warn "ledger: could not record packages: $*"
  fi
  for p in "$@"; do pkgs+=("$(distro_pkg "$p")"); done
  case "$(distro_family)" in
    arch)   run pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    debian) _distro_apt_update
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    *)      distro_require ;;
  esac
}

# pkg_remove <pkgs...> — remove system packages with their unneeded deps.
pkg_remove() {
  local -a pkgs=() p
  for p in "$@"; do pkgs+=("$(distro_pkg "$p")"); done
  (( "${#pkgs[@]}" > 0 )) || return 0
  case "$(distro_family)" in
    arch)   run pacman -Rns --noconfirm "${pkgs[@]}" ;;
    debian) run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}" ;;
    *)      distro_require ;;
  esac
}

# pkg_is_installed <pkg> — true when the package is installed.
pkg_is_installed() {
  local pkg; pkg="$(distro_pkg "$1")"
  case "$(distro_family)" in
    arch)   pacman -Q "$pkg" >/dev/null 2>&1 ;;
    debian) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' ;;
    *)      distro_require ;;
  esac
}

# pkg_upgrade — full system upgrade. On Arch: paru (repos + AUR) when an
# operator runs this from their own sudo session; pacman when unattended —
# a rollout unit has no unprivileged user to hand paru to, and paru would
# need an interactive sudo for its own pacman step anyway. AUR packages are
# therefore upgraded only by an interactive `sudo aw update`.
pkg_upgrade() {
  export AW_PKG_GUARD_OK=1
  case "$(distro_family)" in
    arch)
      if have paru && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then run_paru -Syu --noconfirm
      else run pacman -Syu --noconfirm; fi ;;
    debian)
      _distro_apt_update
      run env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y ;;
    *) distro_require ;;
  esac
}

# pkg_orphans_remove — drop automatically-installed packages nothing needs.
pkg_orphans_remove() {
  case "$(distro_family)" in
    arch)
      local -a orphans=()
      mapfile -t orphans < <(pacman -Qtdq 2>/dev/null || true)
      if (( "${#orphans[@]}" > 0 )); then
        run pacman -Rns --noconfirm "${orphans[@]}"
      else
        info "no orphaned packages"
      fi ;;
    debian)
      run env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y ;;
    *) distro_require ;;
  esac
}

# pkg_orphan_count — how many orphaned packages exist (for status output).
pkg_orphan_count() {
  case "$(distro_family)" in
    arch)   pacman -Qtdq 2>/dev/null | wc -l ;;
    debian) apt-get --dry-run autoremove 2>/dev/null | grep -c '^Remv' || true ;;
    *)      distro_require ;;
  esac
}

# pkg_cache_clean — trim the local package cache.
pkg_cache_clean() {
  case "$(distro_family)" in
    arch)
      if have paccache; then run paccache -rk2
      else run pacman -Sc --noconfirm; fi ;;
    debian) run env DEBIAN_FRONTEND=noninteractive apt-get clean ;;
    *) distro_require ;;
  esac
}
