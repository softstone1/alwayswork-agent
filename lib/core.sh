# shellcheck shell=bash
# alwayswork · core runtime: logging, guards, dry-run, small helpers.
# Sourced by bin/alwayswork; never executed directly.

: "${AW_CORE_SOURCED:=1}"

AW_VERSION="${AW_VERSION:-0.1.0}"
AW_ROOT="${AW_ROOT:-/opt/alwayswork}"
AW_ETC="${AW_ETC:-/etc/alwayswork}"
AW_STATE="${AW_STATE:-/var/lib/alwayswork}"
AW_LOG_DIR="${AW_LOG_DIR:-/var/log/alwayswork}"
AW_CONFIG="${AW_CONFIG:-$AW_ETC/worker.yaml}"
AW_CAP_USER_DIR="${AW_CAP_USER_DIR:-$AW_ETC/capabilities.d}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
JSON_OUT="${JSON_OUT:-0}"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

log()     { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
info()    { printf '    %s\n' "$*" >&2; }
ok()      { printf '    %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()    { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf ' %serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
die()     { err "$*"; exit 1; }
kv()      { printf '    %-20s %s\n' "$1" "$2" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local c
  for c in "$@"; do have "$c" || die "missing required command: $c"; done
}

require_root() {
  [[ "${AW_TEST:-0}" == "1" ]] && return 0
  [[ "$(id -u)" == "0" ]] && return 0
  # An optional second argument explains why the operator may not need this at
  # all, so the common case reads as guidance rather than a wall.
  local what="${1:-}" hint="${2:-}"
  [[ -n "$hint" ]] && info "$hint"
  die "this command needs root: sudo aw $what"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
    return 0
  fi
  # Under the test suite a real system tool must never run (it would change
  # the developer's machine, or make polkit ask for a password): only stubs
  # on a temporary PATH are allowed through.
  if [[ "${AW_TEST:-0}" == "1" ]]; then
    case "$1" in
      systemctl|systemd-run|useradd|usermod|userdel|ufw|firewall-cmd|pacman|paru|apt-get|apt|dpkg|snapper|hostnamectl|sysctl|podman|docker|btrfs|mount|umount|chown|chmod|shred|ln|cp|rm|mkdir|tee|install)
        local bin; bin="$(command -v "$1" 2>/dev/null || true)"
        case "$bin" in
          /usr/*|/bin/*|/sbin/*)
            case "$1" in
              chown|chmod|ln|cp|rm|mkdir|tee|install) ;;   # file tools are fine on scratch paths
              *) printf '    [test] refusing real %s\n' "$*" >&2; return 0 ;;
            esac ;;
        esac ;;
    esac
  fi
  "$@"
}

# run_masked <display> <cmd...> — like run(), but the dry-run/log line shows
# <display> instead of the real argv, so secret-bearing values never appear in
# dry-run output, logs, or (via display) anywhere else. The real argv is still
# only passed to the command itself; prefer file/env passing over argv.
run_masked() {
  local display="$1"; shift
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$display" >&2
    return 0
  fi
  "$@"
}

# run_paru <paru-args...> — paru refuses to run as root. When we are root via
# sudo, drop to the invoking unprivileged user (SUDO_USER); otherwise run
# directly as the current user. Dies loudly only when root with no unprivileged
# user to drop to, rather than failing obscurely inside paru. Never dies in
# dry-run: a would-be install is printed, not executed.
# Paru is an AUR helper: Arch-family only. The `have` guard keeps core.sh
# usable when lib/distro.sh was not sourced (e.g. standalone test scripts).
run_paru() {
  if have distro_is_arch && ! distro_is_arch; then
    die "paru/AUR is only available on Arch-based systems (this is $(distro_pretty))"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    %s[dry-run]%s paru %s\n' "$C_DIM" "$C_RESET" "$*" >&2
    return 0
  fi
  if [[ "$EUID" != "0" ]]; then
    run paru "$@"
    return
  fi
  local user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != "root" ]] \
    || die "paru cannot run as root; re-run via sudo from your unprivileged user"
  local home; home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  [[ -n "$home" ]] || home="/home/$user"
  if have runuser; then
    run env -u SUDO_USER HOME="$home" runuser -u "$user" -- paru "$@"
  else
    # shellcheck disable=SC2086
    run su -s /bin/bash "$user" -c "$(printf '%q ' paru "$@")"
  fi
}

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  [[ -t 0 ]] || die "no TTY for confirmation; re-run with --yes"
  local reply
  read -r -p "    $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

ensure_dir() { [[ -d "$1" ]] || run mkdir -p "$1"; }

aw_state_init() {
  ensure_dir "$AW_ETC"
  ensure_dir "$AW_STATE"
  ensure_dir "$AW_STATE/capabilities"
  ensure_dir "$AW_LOG_DIR" 2>/dev/null || warn "cannot create $AW_LOG_DIR (continuing)"
}

# --- tiny key/value state ---------------------------------------------------
state_file() { printf '%s\n' "$AW_STATE/state.env"; }

state_get() {
  local key="$1" f
  f="$(state_file)"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  ( . "$f" 2>/dev/null; printf '%s\n' "${!key:-}" )
}

state_set() {
  local key="$1" val="$2" f
  f="$(state_file)"
  ensure_dir "$AW_STATE"
  run touch "$f"
  if grep -q "^${key}=" "$f" 2>/dev/null; then
    run sed -i "s|^${key}=.*|${key}=${val}|" "$f"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '    [dry-run] state %s=%s\n' "$key" "$val" >&2
    else
      printf '%s=%s\n' "$key" "$val" >> "$f"
    fi
  fi
}

# Write a file from stdin, honouring --dry-run and creating parents.
# --- code freshness ---------------------------------------------------------
# The control agent is a long-running process: it holds whatever code it started
# with. Reconciling is the moment the on-disk tree is known to be current, so it
# is also the moment to reload an agent that is still running older code. Without
# this, every change to 'aw' itself would need a human to restart the service.
aw_code_hash() {
  find "$AW_ROOT/lib" "$AW_ROOT/commands" "$AW_ROOT/bin" "$AW_ROOT/capabilities" -type f 2>/dev/null \
    | sort | xargs -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}

aw_agent_reload_if_stale() {
  local f now
  f="$AW_STATE/agent-code-hash"
  now="$(aw_code_hash)"
  [[ -n "$now" ]] || return 0
  if [[ -f "$f" && "$(cat "$f" 2>/dev/null)" == "$now" ]]; then return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] record the code hash and reload the control agent\n' >&2
    return 0
  fi
  printf '%s' "$now" > "$f"
  if systemctl is-active --quiet alwayswork-agent.service 2>/dev/null; then
    info "alwayswork code changed; reloading the control agent"
    run systemctl restart --no-block alwayswork-agent.service || true
  fi
}

aw_write() {
  local path="$1"
  ensure_dir "$(dirname "$path")"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] write %s\n' "$path" >&2
    cat >/dev/null
    return 0
  fi
  _aw_write_ledger "$path"
  cat > "$path"
}

# Record a file's prior state in the footprint ledger (lib/ledger.sh) before
# aw_write replaces it, so decommission can put it back. Our own tree, config
# and state are not ledgered: a full restore removes them wholesale at the
# end. A unit file written under /etc/systemd/system is also recorded as a
# unit, so restore disables it before deleting it.
_aw_write_ledger() {
  local path="$1"
  have ledger_file_before || return 0
  case "$path" in
    "$AW_STATE"/*|"$AW_ETC"/*|"$AW_ROOT"/*) return 0 ;;
  esac
  ledger_file_before "$path" || warn "ledger: could not record $path"
  case "$path" in
    /etc/systemd/system/*.service|/etc/systemd/system/*.timer)
      ledger_unit "$(basename "$path")" || warn "ledger: could not record unit $(basename "$path")" ;;
  esac
}

aw_random_hex() {
  if have openssl; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
