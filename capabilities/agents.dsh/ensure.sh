# shellcheck shell=bash
# alwayswork capability: agents.dsh — harness discovery + zero-touch install.
#
# Sourced by preflight.sh and install.sh (each hook runs in its own
# subshell, hence the shared file). Needs from the sourcer: die, warn, ok,
# log, info, have, run (lib/core.sh), cap_config (lib/capability.sh),
# distro_family/distro_pretty (lib/distro.sh), DRY_RUN (lib/core.sh).

# --- pinned releases -------------------------------------------------------
# DeepSeek Harness on npm. The version is configurable:
#   aw enable agents.dsh --dsh_version 0.1.6-alpha.2
# (or: aw config set .capabilities.config.agents.dsh.dsh_version <v>).
# The default is the publisher's `latest` dist-tag at the time of pinning.
DSH_NPM_VERSION_DEFAULT="0.1.5-rc.2"
# Pinned sha512 (base64) of the default version's npm tarball. npm verifies
# the tarball against the registry metadata over HTTPS on install; we
# additionally verify the downloaded file against this pin before npm ever
# sees it — a tampered tarball never reaches the installer.
DSH_NPM_SHA512_DEFAULT="8Xc8hCQHcIWRmTCVU/xZdp6/qMsWMeAd2ObChKDEsfhUPJFXx6H0lgeb1DxUMD86HZrrVN+1bCvn1ppjZ/fOxw=="

# Node.js 22 LTS ("Jod"). Debian/Ubuntu ship an ancient node, so on the
# debian family we install the official binary tarball, sha256-verified
# like sops. On Arch the distro package is current (always >= 22.19).
NODE_VERSION="v22.23.2"
NODE_SHA256_X64="d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307"
NODE_SHA256_ARM64="fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8"

# --- discovery (unchanged) ---------------------------------------------------
# The harness CLI is a node script, so look beyond root's PATH: an operator
# installs it under their own home. Set one explicitly with --dsh to override.
ds_dsh_bin() {
  local candidate
  for candidate in "$(cap_config dsh)" "$(command -v dsh 2>/dev/null || true)" \
    /usr/local/bin/dsh /opt/*/dsh /home/*/.local/bin/dsh; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Effective harness version (SYSTEM_SPEC §12.4): explicit dsh_version wins,
# else the channel the manifest names (dsh_channel overrides: latest | next |
# pinned) resolved by the control plane, else the pin above.
ds_want_version() {
  local v
  v="$(cap_config dsh_version)"
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  if declare -F wl_want_version >/dev/null; then
    v="$(CAP_ID="${CAP_ID:-agents.dsh}" wl_want_version agents.dsh 2>/dev/null)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi
  printf '%s' "$DSH_NPM_VERSION_DEFAULT"
}

# --- node.js -----------------------------------------------------------------
# The harness needs node >= 22.19 with npm alongside it.
ds_node_ok() {
  have node && have npm || return 1
  local v major minor
  v="$(node -v 2>/dev/null || true)"; v="${v#v}"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 22 || (major == 22 && minor >= 19) ))
}

# Install node when no usable one exists. Dies loudly: without node the
# harness cannot run at all, so there is no degraded path here.
ds_install_node() {
  ds_node_ok && return 0
  local fam
  fam="$(distro_family)"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "agents.dsh: dry-run — would install node >= 22.19 for the ${fam} family"
    return 0
  fi
  log "agents.dsh: installing node.js (need >= 22.19 for the harness)"
  case "$fam" in
    arch)
      # Arch tracks current node in the repos (npm ships inside the
      # nodejs package — there is no separate npm package on Arch).
      pkg_install nodejs
      ;;
    debian)
      ds_install_node_debian
      ;;
    *)
      die "agents.dsh: no usable node found and automatic install is unsupported on $(distro_pretty); install node >= 22.19 with npm, then re-run"
      ;;
  esac
  hash -r 2>/dev/null || true
  ds_node_ok || die "agents.dsh: node install finished but no node >= 22.19 with npm is on PATH"
  ok "node $(node -v) + npm ready"
}

ds_install_node_debian() {
  local arch asset want tmp tarball
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  asset="node-${NODE_VERSION}-linux-x64.tar.xz";   want="$NODE_SHA256_X64" ;;
    aarch64) asset="node-${NODE_VERSION}-linux-arm64.tar.xz";  want="$NODE_SHA256_ARM64" ;;
    *) die "agents.dsh: no node ${NODE_VERSION} binary for ${arch}; install node >= 22.19 manually" ;;
  esac
  tmp="$(mktemp -d)"
  tarball="$tmp/$asset"
  log "agents.dsh: fetching node ${NODE_VERSION} (${asset})"
  if ! run curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/${asset}" -o "$tarball"; then
    rm -rf "$tmp"
    die "agents.dsh: could not download node ${NODE_VERSION}/${asset}"
  fi
  if [[ "$(sha256sum "$tarball" | cut -d' ' -f1)" != "$want" ]]; then
    rm -rf "$tmp"
    die "agents.dsh: node checksum mismatch for ${NODE_VERSION}/${asset}; refusing to install this binary"
  fi
  ok "node ${NODE_VERSION} (sha256 verified)"
  # /usr/local/bin is already on the webui unit's PATH (see install.sh).
  run tar -xf "$tarball" -C /usr/local --strip-components=1
  rm -rf "$tmp"
  hash -r 2>/dev/null || true
}

# --- the harness ---------------------------------------------------------------
# Install the pinned @deepseek-ai/dsh release into the global npm prefix
# (/usr/local → /usr/local/bin/dsh, an explicit ds_dsh_bin candidate and on
# the webui unit's PATH). The tarball is fetched over HTTPS and its sha512
# verified before npm ever sees it; nothing is piped to a shell.
ds_install_dsh() {
  local version want_pin tmp tgz url integrity got
  version="$(ds_want_version)"
  # Never let a config value smuggle flags or paths into the commands below.
  [[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || die "agents.dsh: refusing suspicious dsh_version '$version'"
  if [[ "$version" == "$DSH_NPM_VERSION_DEFAULT" ]]; then
    want_pin="$DSH_NPM_SHA512_DEFAULT"
  else
    want_pin=""
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    ok "@deepseek-ai/dsh@${version} (download + integrity check run on a real install)"
    return 0
  fi
  tmp="$(mktemp -d)"
  tgz="$tmp/dsh.tgz"
  url="https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${version}.tgz"
  log "agents.dsh: fetching @deepseek-ai/dsh@${version}"
  if ! run curl -fsSL "$url" -o "$tgz"; then
    rm -rf "$tmp"
    die "agents.dsh: could not download @deepseek-ai/dsh@${version} from the npm registry"
  fi
  if [[ -z "$want_pin" ]]; then
    # Operator-overridden version: no baked-in pin exists, so verify against
    # the integrity the registry itself advertises for this version (still
    # fetched over HTTPS) — a corrupted download never reaches npm.
    integrity="$(curl -fsSL "https://registry.npmjs.org/@deepseek-ai%2fdsh" \
      | jq -r --arg v "$version" '.versions[$v].dist.integrity // empty')"
    [[ -n "$integrity" ]] || { rm -rf "$tmp"; die "agents.dsh: version ${version} not found in the npm registry"; }
    want_pin="${integrity#sha512-}"
    [[ -n "$want_pin" && "$want_pin" != "$integrity" ]] \
      || { rm -rf "$tmp"; die "agents.dsh: registry advertised no sha512 integrity for ${version}; refusing to install"; }
  fi
  got="$(openssl dgst -sha512 -binary "$tgz" | openssl base64 -A)"
  if [[ "$got" != "$want_pin" ]]; then
    rm -rf "$tmp"
    die "agents.dsh: dsh tarball integrity mismatch for ${version}; refusing to install"
  fi
  ok "@deepseek-ai/dsh@${version} (sha512 verified)"
  run npm install -g --no-audit --no-fund --prefix /usr/local "$tgz"
  rm -rf "$tmp"
  hash -r 2>/dev/null || true
}

# --- entry point -----------------------------------------------------------------
# Print an executable dsh path, installing the pinned release (and node 22
# LTS first) when none is found. An already-present binary is returned
# untouched: no reinstall, no version churn.
ds_ensure_harness() {
  local bin version
  if bin="$(ds_dsh_bin)"; then
    printf '%s' "$bin"
    return 0
  fi
  version="$(ds_want_version)"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "agents.dsh: dry-run — would install node ${NODE_VERSION} then @deepseek-ai/dsh@${version} to /usr/local"
    printf '%s' "/usr/local/bin/dsh"
    return 0
  fi
  log "agents.dsh: no dsh found — installing the DeepSeek Harness (zero-touch)"
  ds_install_node
  ds_install_dsh
  bin="$(ds_dsh_bin)" || die "agents.dsh: install finished but no executable dsh was found"
  printf '%s' "$bin"
}
