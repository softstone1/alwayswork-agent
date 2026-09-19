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
STATE_DIR="${STATE_DIR:-/var/lib/alwayswork}"
BIN_LINK="${BIN_LINK:-/usr/local/bin/alwayswork}"
ALIAS="${ALIAS:-aw}"
DRY_RUN=0
ASSUME_YES=0
SKIP_DEPS=0
NO_ALIAS=0
FORCE=0
SRC_DIR=""
INSTALL_FAMILY=""
# Zero-touch enrol inputs: flags win over the ALWAYSWORK_* env equivalents.
ENROLL_TOKEN="${ALWAYSWORK_JOIN_TOKEN:-}"
ENROLL_HOSTNAME="${ALWAYSWORK_HOSTNAME:-}"
ENROLL_CONTROL="${ALWAYSWORK_CONTROL_URL:-}"
ENROLL_PROFILE="${ALWAYSWORK_PROFILE:-}"

C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf ' %serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

# --- footprint ledger --------------------------------------------------------
# `aw` does not exist yet, so the installer appends its own entries, in the
# format lib/ledger.sh writes (docs/DECOMMISSION.md), BEFORE each change:
# `aw decommission` replays them last and the machine ends up as it was
# before this script ran. One entry per (kind, name/path): a re-run never
# records a second, contradictory entry, so the first — the pristine state
# — is what restore returns to. No jq yet: the values are plain paths and
# package names, escaped by hand.
ledger_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
ledger_append() { # <kind> <ident-field> <ident-value> [extra-json-fields]
  local kind="$1" field="$2" value="$3" extra="${4:-}" key line
  key="\"kind\":\"$kind\",\"$field\":\"$(ledger_str "$value")\""
  line="{\"t\":$(date +%s),\"by\":\"install\",$key${extra:+,$extra}}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] ledger %s %s=%s\n' "$kind" "$field" "$value"
    return 0
  fi
  if [[ -f "$STATE_DIR/ledger.jsonl" ]] && grep -qF -- "$key" "$STATE_DIR/ledger.jsonl"; then
    return 0
  fi
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$line" >> "$STATE_DIR/ledger.jsonl"
}
pkg_installed() {
  case "${INSTALL_FAMILY:-unknown}" in
    arch)   pacman -Qi "$1" >/dev/null 2>&1 ;;
    debian) dpkg-query -s "$1" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}
# ledger_pkg <pkg...> — packages about to be installed, with whether each
# was already here (those are never removed by restore).
ledger_pkg() {
  local p prior
  for p in "$@"; do
    if pkg_installed "$p"; then prior=true; else prior=false; fi
    ledger_append pkg name "$p" "\"priorInstalled\":$prior"
  done
}
# ledger_path <file|dir> <path> — a file or directory about to be created.
ledger_path() {
  local kind="$1" path="$2" existed=false
  [[ -e "$path" || -L "$path" ]] && existed=true
  ledger_append "$kind" path "$path" "\"existed\":$existed"
}

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

Zero-touch (what the platform bootstrapper at https://alwayswork.space/install.sh
runs; also usable by hand on a box you already have a shell on):

  curl -fsSL https://alwayswork.space/install.sh | sudo bash -s -- --token <t>

  --control <url>  Control plane URL          (env ALWAYSWORK_CONTROL_URL; default https://alwayswork.space)
  --token <t>      Join token from the console (env ALWAYSWORK_JOIN_TOKEN). Enrols directly:
                   active at once if the group auto-approves, else pending one approval.
                   Without a token the node registers a pending claim instead.
  --hostname <h>   Set the machine hostname first (env ALWAYSWORK_HOSTNAME); becomes <h>.<base>
  --profile <p>    Starting profile            (env ALWAYSWORK_PROFILE; default worker)

  ALWAYSWORK_AUTO_ENROLL=1   Required with --yes for the zero-touch path: enrol only,
                             no bootstrap, no firewall and no SSH lockdown at install
                             time. The lockdown happens later, automatically, once
                             signed desired state marks the node active and its
                             tunnel is verified.
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
    --token)     [[ -n "${2-}" ]] || die "missing value for --token";    ENROLL_TOKEN="$2"; shift ;;
    --token=*)   ENROLL_TOKEN="${1#--token=}" ;;
    --hostname)  [[ -n "${2-}" ]] || die "missing value for --hostname"; ENROLL_HOSTNAME="$2"; shift ;;
    --hostname=*) ENROLL_HOSTNAME="${1#--hostname=}" ;;
    --control)   [[ -n "${2-}" ]] || die "missing value for --control";  ENROLL_CONTROL="$2"; shift ;;
    --control=*) ENROLL_CONTROL="${1#--control=}" ;;
    --profile)   [[ -n "${2-}" ]] || die "missing value for --profile";  ENROLL_PROFILE="$2"; shift ;;
    --profile=*) ENROLL_PROFILE="${1#--profile=}" ;;
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
    arch)   ledger_pkg "${pkgs[@]}" sops
            run pacman -Syu --needed --noconfirm "${pkgs[@]}" sops ;;
    debian) ledger_pkg "${pkgs[@]}"
            run apt-get update
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
  ledger_pkg sops
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
  ledger_path file "$alias_path"
  run ln -sf "$INSTALL_DIR/bin/alwayswork" "$alias_path"
  ok "Alias ${ALIAS} -> alwayswork"
}

install_files() {
  local src="$1"
  log "Installing runtime to ${INSTALL_DIR}"
  ledger_path dir "$INSTALL_DIR"
  run mkdir -p "$INSTALL_DIR"
  run cp -a "$src/." "$INSTALL_DIR/"
  run chmod +x "$INSTALL_DIR/bin/alwayswork" "$INSTALL_DIR/install.sh"
  run find "$INSTALL_DIR" -name '*.sh' -exec chmod +x {} +
  # Which commit this is: from the control plane's tarball header (one-liner),
  # from git (a checkout), or whatever the source already recorded (image).
  # The heartbeat reports it; `aw update` compares it with what the control
  # plane ships and upgrades when behind.
  local commit="${AW_AGENT_COMMIT:-}"
  [[ -n "$commit" ]] || commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$commit" ]] || commit="$(cat "$src/COMMIT" 2>/dev/null || true)"
  if [[ "$commit" =~ ^[a-f0-9]{7,40}$ ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then info "[dry-run] record commit $commit"; else printf '%s\n' "$commit" > "$INSTALL_DIR/COMMIT"; fi
  fi
  ledger_path dir /etc/alwayswork
  run mkdir -p /etc/alwayswork
  ledger_path file "$BIN_LINK"
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
  ledger_path file "$target"
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

# Zero-touch enrollment (the platform bootstrapper sets ALWAYSWORK_AUTO_ENROLL=1
# and passes --control/--token/--hostname/--profile; env equivalents work too).
#
# Enrols ONLY: hostname, init, secret store, the control.join capability
# (agent unit + provision timer + USB hotplug rule), then either a direct
# token enrolment or a pending claim. No bootstrap, no firewall, no SSH
# lockdown at install time — cutting SSH here would strand the box before
# the tunnel is verified.
#
# With a token: `aw enroll --token` announces the node and waits a bounded
# time for approval (immediate when the group auto-approves). If the group
# needs a human, the wait ends cleanly, the node stays "pending" on disk and
# the provision timer completes enrolment on its own after the console click
# — so cloud-init and the USB stick never hang.
#
# Without a token: `aw provision` registers a pending claim; the timer polls
# it and completes enrolment on approval.
#
# Either way the first signed desired-state delivery applies everything:
# tunnel token -> cloudflared up, config, then the deferred lockdown.
# Ordering: install -> pending -> (approval) -> active -> lockdown.
# An enrolled node re-running the installer (the same one-liner, `aw update`,
# or an operator fixing a stale box) keeps its identity: files are already
# replaced above, so converge and restart the agent — never re-enrol.
upgrade_in_place() {
  log "This node is already enrolled: upgrading the agent in place (identity kept)"
  run "$BIN_LINK" apply || warn "apply reported a problem; the control agent retries desired state on its next tick"
  if have systemctl && systemctl list-unit-files alwayswork-agent.service >/dev/null 2>&1; then
    run systemctl restart alwayswork-agent.service 2>/dev/null || true
  fi
  ok "agent upgraded in place; the next heartbeat reports the new version"
}
already_enrolled() { [[ -f /etc/alwayswork/control.json ]] && grep -q '"deviceId"' /etc/alwayswork/control.json 2>/dev/null; }

auto_enroll() {
  local url="${ENROLL_CONTROL:-https://alwayswork.space}"
  local profile="${ENROLL_PROFILE:-worker}"
  url="${url%/}"
  if already_enrolled; then
    [[ -z "$ENROLL_TOKEN" ]] || warn "already enrolled; the join token is ignored (Remove the node in the console first to re-enrol)"
    upgrade_in_place
    return 0
  fi
  log "Zero-touch install: enrolling against ${url} (profile: ${profile})"
  info "no lockdown at install time — SSH stays up until the tunnel is verified"
  if [[ -n "$ENROLL_HOSTNAME" ]]; then
    [[ "$ENROLL_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
      || die "--hostname must be one DNS label (letters, digits, dashes): ${ENROLL_HOSTNAME}"
    log "Setting hostname to ${ENROLL_HOSTNAME}"
    if have hostnamectl; then
      run hostnamectl set-hostname "$ENROLL_HOSTNAME"
    else
      run sh -c "printf '%s\\n' '$ENROLL_HOSTNAME' > /etc/hostname"
      run hostname "$ENROLL_HOSTNAME"
    fi
  fi
  run "$BIN_LINK" init --profile "$profile"
  # The secret store must exist before the control plane can deliver the
  # tunnel token into it. Non-fatal: on distros where sops is not yet
  # installable the agent loudly refuses the token and the delivery stays
  # unacked until the store exists.
  run "$BIN_LINK" secrets init \
    || warn "secret store not initialised; run 'sudo aw secrets init' once sops/age are present"
  # --url lands in .capabilities.config.control.join.url; the capability's
  # install script persists it as .control.url and installs the agent unit,
  # the provision timer and the USB hotplug rule.
  run "$BIN_LINK" enable control.join --url "$url"
  # The agent must not run before enrollment completes: with no identity it
  # would only crash-loop. Enrolment (below) or the provision timer starts it.
  run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  if [[ -n "$ENROLL_TOKEN" ]]; then
    # Bounded wait: auto-approve groups answer at once; otherwise the timer
    # resumes the pending enrolment after the operator approves.
    if AW_ENROLL_WAIT="${AW_ENROLL_WAIT:-90}" run "$BIN_LINK" enroll --control "$url" --token "$ENROLL_TOKEN"; then
      ok "enrolled: the node configures itself (tunnel, capabilities, web UI) and appears in the console"
    else
      die "enrolment with the join token failed (expired, revoked or wrong control plane?)"
    fi
  else
    run "$BIN_LINK" provision
    ok "enrollment started: approve the pending claim in the console"
    info "after approval the node configures itself: tunnel, capabilities, lockdown"
  fi
}

main() {
  log "AlwaysWork ${VERSION} installer"
  detect_platform
  local src
  src="$(resolve_source)"
  [[ "${SKIP_DEPS:-0}" == "1" ]] || install_deps
  install_files "$src"

  if [[ "$ASSUME_YES" == "1" ]]; then
    # A token or a control URL on the command line is the zero-touch path too.
    if [[ "${ALWAYSWORK_AUTO_ENROLL:-0}" == "1" || -n "$ENROLL_TOKEN" || -n "$ENROLL_CONTROL" ]]; then
      auto_enroll
    elif already_enrolled; then
      upgrade_in_place
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
