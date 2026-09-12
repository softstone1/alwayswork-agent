#!/usr/bin/env bash
# AlwaysWork installer.
#
#   curl -fsSL https://raw.githubusercontent.com/softstone1/alwayswork/main/install.sh | sudo bash
#   sudo ./install.sh --dry-run
#
# Idempotent: safe to re-run. Installs dependencies, places the runtime in
# ${INSTALL_DIR}, links the CLI and its short alias.
set -euo pipefail

VERSION="0.1.0"
REPO_SLUG="${REPO_SLUG:-softstone1/alwayswork}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/alwayswork}"
BIN_LINK="${BIN_LINK:-/usr/local/bin/alwayswork}"
ALIAS="${ALIAS:-aw}"
DRY_RUN=0
ASSUME_YES=0
SKIP_DEPS=0
NO_ALIAS=0
FORCE=0
SRC_DIR=""

C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf ' %serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() {
  cat <<EOF
AlwaysWork installer ${VERSION}

Usage: install.sh [options]

  --dry-run        Print actions without changing the system
  --yes, -y        Non-interactive; bootstrap the foundation after install
  --skip-deps      Do not install system packages
  --no-alias       Do not create the short ${ALIAS} alias
  --force          Continue on a non-Arch distribution
  --dir <path>     Install directory (default: ${INSTALL_DIR})
  --ref <gitref>   Branch/tag to download (default: ${REPO_REF})
  --from <path>    Install from a local checkout
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --no-alias)  NO_ALIAS=1 ;;
    --force)     FORCE=1 ;;
    --dir)       INSTALL_DIR="$2"; shift ;;
    --ref)       REPO_REF="$2"; shift ;;
    --from)      SRC_DIR="$2"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
  shift
done

detect_platform() {
  [[ -f /etc/os-release ]] || die "unsupported system: missing /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "arch" && "${ID:-}" != "cachyos" && "${ID_LIKE:-}" != *arch* ]]; then
    warn "alwayswork targets Arch-based systems; detected ${PRETTY_NAME:-unknown}"
    [[ "$FORCE" == "1" ]] || die "refusing to continue without --force"
  fi
}

resolve_source() {
  if [[ -n "$SRC_DIR" ]]; then
    [[ -f "$SRC_DIR/bin/alwayswork" ]] || die "--from ${SRC_DIR} is not an alwayswork checkout"
    printf '%s\n' "$SRC_DIR"; return
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/bin/alwayswork" ]]; then
    printf '%s\n' "$here"; return
  fi
  have curl || die "curl is required to download alwayswork"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading ${REPO_SLUG}${REPO_REF}"
  run curl -fsSL "https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REPO_REF}" -o "$tmp/src.tgz"
  run tar -xzf "$tmp/src.tgz" -C "$tmp"
  printf '%s\n' "$tmp/${REPO_SLUG##*/}-${REPO_REF}"
}

install_deps() {
  local -a pkgs=(git curl jq yq sops age restic ufw)
  log "Installing base dependencies: ${pkgs[*]}"
  if have pacman; then
    run pacman -Sy --needed --noconfirm "${pkgs[@]}"
  else
    warn "pacman not found; install manually: ${pkgs[*]}"
  fi
}

install_alias() {
  [[ "$NO_ALIAS" == "1" ]] && return 0
  local alias_path="/usr/local/bin/${ALIAS}"
  if [[ -e "$alias_path" && ! -L "$alias_path" ]]; then
    warn "alias ${ALIAS} already exists and is not a symlink; skipping"
    return 0
  fi
  run ln -sf "$INSTALL_DIR/bin/alwayswork" "$alias_path"
  ok "Alias ${ALIAS} -> alwayswork"
}

install_files() {
  local src="$1"
  log "Installing runtime to ${INSTALL_DIR}"
  run mkdir -p "$INSTALL_DIR"
  run cp -a "$src/." "$INSTALL_DIR/"
  run chmod +x "$INSTALL_DIR/bin/alwayswork" "$INSTALL_DIR/install.sh"
  run find "$INSTALL_DIR" -name '*.sh' -exec chmod +x {} +
  run mkdir -p /etc/alwayswork
  run ln -sf "$INSTALL_DIR/bin/alwayswork" "$BIN_LINK"
  ok "CLI linked at ${BIN_LINK}"
  install_alias
}

main() {
  log "AlwaysWork ${VERSION} installer"
  detect_platform
  local src
  src="$(resolve_source)"
  [[ "${SKIP_DEPS:-0}" == "1" ]] || install_deps
  install_files "$src"

  if [[ "$ASSUME_YES" == "1" ]]; then
    log "Bootstrapping foundation profile"
    run "$BIN_LINK" init --yes
    run "$BIN_LINK" bootstrap --yes
  else
    log "Done. Next steps:"
    info "sudo aw init --profile foundation"
    info "sudo aw bootstrap"
    info "sudo aw doctor"
  fi
}

main "$@"
