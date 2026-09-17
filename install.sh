#!/usr/bin/env bash
# AlwaysWork installer.
#
#   curl -fsSL https://raw.githubusercontent.com/softstone1/alwayswork-agent/main/install.sh | sudo bash
#   sudo ./install.sh --dry-run
#
# Idempotent: safe to re-run. Installs dependencies, places the runtime in
# ${INSTALL_DIR}, links the CLI and its short alias.
set -euo pipefail

VERSION="0.1.0"
REPO_SLUG="${REPO_SLUG:-softstone1/alwayswork-agent}"
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
INSTALL_FAMILY=""

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
  --force          Continue on an unsupported distribution
  --dir <path>     Install directory (default: ${INSTALL_DIR})
  --ref <gitref>   Branch/tag to download (default: ${REPO_REF})
  --from <path>    Install from a local checkout
  -h, --help       Show this help

Zero-touch (the platform bootstrapper at https://alwayswork.space/install.sh
sets these; not for hand use):

  curl -fsSL https://alwayswork.space/install.sh | sudo bash

  ALWAYSWORK_AUTO_ENROLL=1   Enroll only: no bootstrap, no SSH lockdown at
                             install time. The node registers a pending claim
                             and waits for console approval; the lockdown
                             happens later, automatically, when signed
                             desired-state marks the node active.
  ALWAYSWORK_CONTROL_URL     Control plane URL (default: https://alwayswork.space)
  ALWAYSWORK_PROFILE         Starting profile (default: worker)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --no-alias)  NO_ALIAS=1 ;;
    --force)     FORCE=1 ;;
    --dir)       [[ -n "${2-}" ]] || die "missing value for --dir";  INSTALL_DIR="$2"; shift ;;
    --ref)       [[ -n "${2-}" ]] || die "missing value for --ref";  REPO_REF="$2"; shift ;;
    --from)      [[ -n "${2-}" ]] || die "missing value for --from"; SRC_DIR="$2"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
  shift
done

detect_platform() {
  [[ -f /etc/os-release ]] || die "unsupported system: missing /etc/os-release"
  # Standalone copy of the lib/distro.sh family detection: install.sh can run
  # from a pipe (curl | bash), where lib/ is not available yet. Parsed, not
  # sourced, so os-release values (e.g. VERSION=) can never clobber the
  # installer's own variables.
  local id="" like="" fam="unknown"
  id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1 || true)"
  like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1 || true)"
  case "$id" in
    arch|cachyos|endeavouros|manjaro|garuda|artix) fam="arch" ;;
    debian|ubuntu|kali|raspbian|pop|linuxmint|elementary|zorin|mx) fam="debian" ;;
  esac
  if [[ "$fam" == "unknown" ]]; then
    case " $like " in
      *" arch "*)                fam="arch" ;;
      *" debian "*|*" ubuntu "*) fam="debian" ;;
    esac
  fi
  INSTALL_FAMILY="$fam"
  if [[ "$fam" == "unknown" ]]; then
    warn "alwayswork supports Arch- and Debian-family systems; detected ${id:-unknown}"
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
  # sops is not in Debian/Ubuntu's apt repositories, so it is handled
  # separately per family below (official .deb on debian).
  local -a pkgs=(git curl jq openssl age restic ufw)
  log "Installing base dependencies: ${pkgs[*]} sops"
  case "${INSTALL_FAMILY:-unknown}" in
    arch)   run pacman -Syu --needed --noconfirm "${pkgs[@]}" sops ;;
    debian) run apt-get update
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
            install_sops_debian ;;
    *)      warn "no package manager for this distribution; install manually: ${pkgs[*]} sops" ;;
  esac
}

# sops ships no Debian/Ubuntu package: install the official .deb from the
# GitHub release on the debian family.
#
# The version is pinned and the download is sha256-verified. The sops
# release's published checksums.txt does not cover the .deb assets, so a
# "latest" lookup could never be verified against anything the release
# publishes — and, as with bundle_yq above, fetching unverified code to run
# as root is not acceptable.
SOPS_VERSION="v3.13.3"
SOPS_SHA256_AMD64="927c45f2ccb5b1c9acb1e80c7befaea0672c721fd3f222697a51e0a7081e3f3b"
SOPS_SHA256_ARM64="21cf1ee8860bb9c2a0b09ac97901b41ca9f95734f3402ea358e31e296e6be823"

install_sops_debian() {
  # sops backs the sealed secret store, but a node must still enroll without
  # it: auto_enroll() documents the degraded path (the agent loudly refuses
  # the tunnel token until sops/age exist, and the delivery stays unacked).
  # So every failure here is a loud warning, never a fatal error — a hard
  # failure in an optional component would brick zero-touch enrollment.
  local arch asset want deb tmp
  if have sops; then
    ok "sops present"
    return 0
  fi
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  asset="sops_${SOPS_VERSION#v}_amd64.deb"; want="$SOPS_SHA256_AMD64" ;;
    aarch64) asset="sops_${SOPS_VERSION#v}_arm64.deb"; want="$SOPS_SHA256_ARM64" ;;
    *) warn "no sops .deb for ${arch}; continuing without sops (sealed secret store unavailable until sops is installed manually)"; return 0 ;;
  esac
  tmp="$(mktemp -d)"
  deb="$tmp/$asset"
  log "Fetching sops ${SOPS_VERSION} (${asset})"
  if ! run curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/${asset}" -o "$deb"; then
    rm -rf "$tmp"
    warn "could not download sops ${SOPS_VERSION}/${asset}; continuing without sops (sealed secret store unavailable until sops is installed manually)"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    rm -rf "$tmp"
    ok "sops ${SOPS_VERSION} (checksum check runs on a real install)"
    return 0
  fi
  if [[ "$(sha256sum "$deb" | cut -d' ' -f1)" != "$want" ]]; then
    rm -rf "$tmp"
    warn "sops checksum mismatch for ${SOPS_VERSION}/${asset}; refusing to install this binary and continuing without sops"
    return 0
  fi
  ok "sops ${SOPS_VERSION} (sha256 verified)"
  if ! run dpkg -i "$deb"; then
    warn "dpkg reported missing dependencies; attempting to fix"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -f -y
    run dpkg -i "$deb"
  fi
  rm -rf "$tmp"
  if ! have sops; then
    warn "sops install finished but 'sops' is not on PATH; continuing without sops"
    return 0
  fi
  ok "sops installed"
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
  bundle_yq
}

# Arch's `yq` package is the Python build, which is not command-compatible
# with the mikefarah Go yq this project uses. Bundle the Go build beside the
# CLI; bin/alwayswork puts that directory first on PATH.
#
# The version is pinned and the download is sha256-verified against the
# release's published checksums: fetching `latest` unverified lets a
# compromised release or mirror ship arbitrary code as root.
YQ_VERSION="v4.47.2"
YQ_SHA256_AMD64="1bb99e1019e23de33c7e6afc23e93dad72aad6cf2cb03c797f068ea79814ddb0"
YQ_SHA256_ARM64="05df1f6aed334f223bb3e6a967db259f7185e33650c3b6447625e16fea0ed31f"
# Distro-appropriate hint for getting mikefarah's Go yq by hand.
yq_install_hint() {
  if [[ "${INSTALL_FAMILY:-}" == "debian" ]]; then
    printf "install mikefarah yq (e.g. from https://github.com/mikefarah/yq/releases)"
  else
    printf "install the AUR 'go-yq'"
  fi
}

bundle_yq() {
  local arch asset target want
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  asset="yq_linux_amd64"; want="$YQ_SHA256_AMD64" ;;
    aarch64) asset="yq_linux_arm64"; want="$YQ_SHA256_ARM64" ;;
    *) warn "no bundled yq for ${arch}; $(yq_install_hint)"; return 0 ;;
  esac
  target="${INSTALL_DIR}/bin/yq"
  if [[ -x "$target" ]] && "$target" --version 2>/dev/null | grep -qi mikefarah; then
    ok "bundled yq present"
    return 0
  fi
  if have yq && yq --version 2>/dev/null | grep -qi mikefarah; then
    run cp "$(command -v yq)" "$target"
    run chmod 755 "$target"
    ok "bundled system yq"
    return 0
  fi
  log "Fetching mikefarah yq ${YQ_VERSION} (${asset})"
  if run curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${asset}" -o "$target"; then
    if [[ "$DRY_RUN" == "1" ]]; then
      ok "bundled yq (checksum check runs on a real install)"
      return 0
    fi
    if [[ "$(sha256sum "$target" | cut -d' ' -f1)" == "$want" ]]; then
      run chmod 755 "$target"
      ok "bundled yq ${YQ_VERSION} (sha256 verified)"
    else
      rm -f "$target"
      die "yq checksum mismatch for ${YQ_VERSION}/${asset}; refusing to install"
    fi
  else
    warn "could not fetch yq; $(yq_install_hint), or place mikefarah yq at ${target}"
  fi
}

# Zero-touch enrollment (the platform bootstrapper sets ALWAYSWORK_AUTO_ENROLL=1).
#
# Enrolls ONLY: init, secret store, the control.join capability (agent units +
# provision timer), and one non-blocking provision run that registers the
# pending claim. No bootstrap, no firewall, no SSH lockdown at install time —
# cutting SSH here would strand the box before the tunnel is verified.
#
# After the console approves the claim, the provision timer completes
# enrollment, the agent starts, and the first signed desired-state delivery
# applies everything automatically: tunnel token -> cloudflared up, config,
# then the deferred lockdown (public SSH off). Ordering:
#   install -> pending -> (console approval) -> active -> lockdown.
auto_enroll() {
  local url="${ALWAYSWORK_CONTROL_URL:-https://alwayswork.space}"
  local profile="${ALWAYSWORK_PROFILE:-worker}"
  log "Zero-touch install: enrolling against ${url} (profile: ${profile})"
  info "no lockdown at install time — SSH stays up until the tunnel is verified"
  run "$BIN_LINK" init --profile "$profile"
  # The secret store must exist before the control plane can deliver the
  # tunnel token into it. Non-fatal: on distros where sops is not yet
  # installable the agent loudly refuses the token and the delivery stays
  # unacked until the store exists.
  run "$BIN_LINK" secrets init \
    || warn "secret store not initialised; run 'sudo aw secrets init' once sops/age are present"
  # --url lands in .capabilities.config.control.join.url; the capability's
  # install script persists it as .control.url and installs the agent unit
  # plus the provision timer.
  run "$BIN_LINK" enable control.join --url "$url"
  # The agent must not run before enrollment completes: with no identity it
  # would only crash-loop. The provision timer registers the pending claim
  # now; claim completion starts the agent on approval.
  run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  run "$BIN_LINK" provision
  ok "enrollment started: approve the pending claim in the console"
  info "after approval the node configures itself: tunnel, capabilities, lockdown"
}

main() {
  log "AlwaysWork ${VERSION} installer"
  detect_platform
  local src
  src="$(resolve_source)"
  [[ "${SKIP_DEPS:-0}" == "1" ]] || install_deps
  install_files "$src"

  if [[ "$ASSUME_YES" == "1" ]]; then
    if [[ "${ALWAYSWORK_AUTO_ENROLL:-0}" == "1" ]]; then
      auto_enroll
    else
      log "Bootstrapping foundation profile"
      run "$BIN_LINK" init --yes
      run "$BIN_LINK" bootstrap --yes
    fi
  else
    log "Done. Next steps:"
    info "sudo aw init --profile foundation"
    info "sudo aw bootstrap"
    info "sudo aw doctor"
  fi
}

main "$@"
