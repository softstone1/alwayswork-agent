# shellcheck shell=bash
# alwayswork capability: tools.browser — the agent's browser on the node
# (SYSTEM_SPEC §12.5), on the workload contract (lib/workload.sh).
#
# Config: image (override), port (noVNC on loopback, default 6080),
# memory_mb (default 2048), start_url.

BR_ID="browser"
BR_IMAGE_REPO_DEFAULT="ghcr.io/softstone1/alwayswork-browser"
BR_IMAGE_TAG_DEFAULT="latest"

br_image()   { local i; i="$(cap_config image)"; [[ -n "$i" ]] || i="${BR_IMAGE_REPO_DEFAULT}:${BR_IMAGE_TAG_DEFAULT}"; printf '%s' "$i"; }
br_port()    { local p; p="$(cap_config port)"; [[ -n "$p" ]] || p=6080; [[ "$p" =~ ^[0-9]{2,5}$ ]] || die "tools.browser: bad port '$p'"; printf '%s' "$p"; }
br_root()    { printf '%s' "$AW_STATE/browser"; }
br_profile() { printf '%s' "$(br_root)/profile"; }
br_env_file(){ printf '%s' "$AW_ETC/browser.env"; }

br_render_env() {
  local dest tmp url
  dest="$(br_env_file)"; url="$(cap_config start_url)"
  if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] render %s\n' "$dest" >&2; return 0; fi
  tmp="$(mktemp "${dest}.XXXXXX")" || die "tools.browser: cannot stage env file"
  chmod 600 "$tmp"
  local re='^https?://[A-Za-z0-9./_:%?=&-]+$'
  {
    printf 'NOVNC_PORT=6080\nCDP_PORT=9222\n'
    if [[ -n "$url" && "$url" =~ $re ]]; then printf 'BROWSER_START_URL=%s\n' "$url"; fi
  } > "$tmp"
  mv -f "$tmp" "$dest"; chmod 600 "$dest"
}

# shellcheck disable=SC2034  # WL_* are read by lib/workload.sh
br_workload_vars() {
  local mem; mem="$(cap_config memory_mb)"; [[ "$mem" =~ ^[0-9]{3,6}$ ]] || mem=2048
  WL_NAME="$BR_ID"
  WL_IMAGE="$(br_image)"
  WL_DESC="agent browser (Chromium + noVNC)"
  WL_PUBLISH=("$(br_port):6080")
  WL_VOLUMES=("$(br_profile):/profile:U")
  WL_ENV_FILE="$(br_env_file)"
  WL_LABELS=("dev.alwayswork.workload=$BR_ID")
  WL_READ_ONLY=0
  WL_TMPFS=()
  WL_HEALTH="curl -sf -o /dev/null http://127.0.0.1:6080/vnc.html"
  # Chromium wants shared memory; the container is its sandbox (userns=auto).
  WL_EXTRA=(--shm-size 1g --memory "${mem}m")
  WL_NETWORK="$(cap_config network)"
  WL_ARGS=()
}
br_write_unit() { br_workload_vars; wl_write_unit; }
br_apply_unit() { br_workload_vars; wl_apply_unit; }

br_status() {
  section "browser"
  kv "image" "$(br_image)"
  kv "unit" "$(systemctl is-active "$(wl_unit_name "$BR_ID")" 2>/dev/null || echo unknown)"
  have podman && kv "health" "$(podman inspect --format '{{.State.Health.Status}}' "$(wl_container "$BR_ID")" 2>/dev/null || echo unknown)"
  kv "watch" "127.0.0.1:$(br_port)/vnc.html  (and $(hostname)-browser.<base> through the tunnel)"
  kv "cdp for the harness" "http://alwayswork-browser:9222 (BROWSER_CDP_URL)"
  kv "profile" "$(br_profile)"
}
br_logs() { podman logs --tail "${1:-100}" "$(wl_container "$BR_ID")"; }
