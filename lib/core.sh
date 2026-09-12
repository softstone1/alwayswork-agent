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
  [[ "$(id -u)" == "0" ]] || die "this command needs root: sudo aw $*"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
    return 0
  fi
  "$@"
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
aw_write() {
  local path="$1"
  ensure_dir "$(dirname "$path")"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] write %s\n' "$path" >&2
    cat >/dev/null
    return 0
  fi
  cat > "$path"
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
