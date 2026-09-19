# shellcheck shell=bash
# alwayswork capability: agents.dsh — the containerised harness (SYSTEM_SPEC §12).
#
# Sourced by install.sh / healthcheck.sh / uninstall.sh. Needs the lib
# helpers (die, warn, ok, log, info, have, run, cfg_get, cfg_bool,
# cap_config, aw_write, ensure_dir, hw_is_btrfs, sec_*, engine_build_args)
# and CAP_ID/CAP_DIR from the capability runner.
#
# The harness runs as ONE rootful Podman container under a system unit:
#   - userns=auto: container root is an unused, unprivileged host uid range
#   - cap-drop ALL, no-new-privileges, pids/cpu/memory budget from .limits
#   - read-only rootfs; /workspace and /home/dsh are the only writable mounts
#   - published to 127.0.0.1:<port> only; the tunnel remains the public path
#   - provider keys arrive via an env file rendered from the sealed store
# The standard image is pulled by pinned tag; if that is impossible the same
# Containerfile is built locally, so the image is identical either way.

DSH_IMAGE_REPO_DEFAULT="ghcr.io/softstone1/alwayswork-dsh"
# shellcheck disable=SC2034  # read by the hooks that source this file
DSH_CONTAINER="alwayswork-dsh"
# shellcheck disable=SC2034
DSH_UNIT="alwayswork-dsh.service"
DSH_LEGACY_UNIT="alwayswork-webui.service"
DSH_UNIT_DIR="$WL_UNIT_DIR"

dsc_mode() {
  local m; m="$(cap_config mode)"
  [[ -n "$m" ]] || m="$(cfg_get '.agents.dsh.mode' container)"
  case "$m" in container|host) printf '%s' "$m" ;; *) die "agents.dsh: unknown mode '$m' (container|host)" ;; esac
}

dsc_port() {
  local p; p="$(cap_config port)"
  [[ -n "$p" ]] || p="$(cfg_get '.expose.webUi.port' 3080)"
  [[ "$p" =~ ^[0-9]{2,5}$ ]] || die "agents.dsh: bad port '$p'"
  printf '%s' "$p"
}

# The public name: explicit wins, otherwise <hostname>.<base domain>. The
# control plane can pin it later via .expose.webUi.host.
dsc_host() {
  local h; h="$(cap_config host)"
  [[ -n "$h" ]] || h="$(cfg_get '.expose.webUi.host' '')"
  if [[ -z "$h" ]]; then
    h="$(hostname).$(cfg_get '.expose.webUi.baseDomain' 'alwayswork.space')"
  fi
  [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || die "agents.dsh: refusing suspicious host '$h'"
  printf '%s' "$h"
}

# Pinned image: <repo>:<dsh version>. `image` overrides everything (a
# digest reference is fine); `dsh_version` picks the tag on the default repo.
dsc_image() {
  local img; img="$(cap_config image)"
  if [[ -z "$img" ]]; then
    local repo; repo="$(cfg_get '.agents.dsh.image_repo' "$DSH_IMAGE_REPO_DEFAULT")"
    img="${repo}:$(ds_want_version)"
  fi
  [[ "$img" =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "agents.dsh: refusing suspicious image '$img'"
  printf '%s' "$img"
}

dsc_workspace() { printf '%s' "$AW_STATE/workspaces/dsh"; }
dsc_home()      { printf '%s' "$AW_STATE/dsh/home"; }
dsc_env_file()  { printf '%s' "$AW_ETC/dsh.env"; }
# The control-plane signing key the agent pinned at enrolment (lib/control.sh
# control_pubkey_file); named here too so this file stands alone in tests.
dsc_control_pubkey() { printf '%s' "$AW_STATE/control-pubkey.json"; }

# A workspace is a btrfs subvolume where the host has btrfs (snapshot per
# task later), a plain directory otherwise. Idempotent.
dsc_ensure_workspace() {
  ensure_dir "$(dsc_home)"
  wl_subvolume "$(dsc_workspace)"
}

# Provider keys and gateway tokens for the harness, from the sealed store:
# every secret named DSH_* (the prefix is stripped) plus a fixed allowlist of
# well-known provider variables. Rendered 0600, root-only; podman passes it
# to the container with --env-file, so it is never on a command line.
DSC_ENV_ALLOW=(DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY AI_GATEWAY_TOKEN AI_GATEWAY_URL OPENAI_BASE_URL ANTHROPIC_BASE_URL)

dsc_render_env() {
  local dest tmp k v host port
  dest="$(dsc_env_file)"; host="$(dsc_host)"; port="$(dsc_port)"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] render %s\n' "$dest" >&2
    return 0
  fi
  tmp="$(mktemp "${dest}.XXXXXX")" || die "agents.dsh: cannot stage env file"
  chmod 600 "$tmp"
  local team aud
  team="$(cap_config access_team_domain)"; [[ -n "$team" ]] || team="$(cfg_get '.access.teamDomain' '')"
  aud="$(cap_config access_aud)";          [[ -n "$aud" ]]  || aud="$(cfg_get '.access.uiAud' '')"
  {
    printf 'DSH_TRUSTED_HOST=%s\n' "$host"
    printf 'DSH_PORT=%s\n' "$port"
    # The node-side UI gate (gate.mjs): Access JWT verification needs both;
    # without them the gate fails closed and says so.
    [[ -n "$team" ]] && printf 'AW_ACCESS_TEAM_DOMAIN=%s\n' "$team"
    [[ -n "$aud" ]]  && printf 'AW_ACCESS_AUD=%s\n' "$aud"
    # The agent's browser (tools.browser), by container name on the node network.
    if cap_is_enabled tools.browser 2>/dev/null; then
      printf 'BROWSER_CDP_URL=http://alwayswork-browser:9222\nPLAYWRIGHT_CDP_URL=http://alwayswork-browser:9222\n'
    fi
    # Control-plane tenant sessions verify against the pinned control key.
    [[ -f "$(dsc_control_pubkey)" ]] && printf 'AW_CONTROL_PUBKEY_FILE=/run/alwayswork/control-pubkey.json\n'
    if [[ "$(sec_backend)" == "sops" ]] && sec_exists; then
      while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        case "$k" in
          DSH_*) v="$(sec_get "$k")"; [[ -n "$v" ]] && printf '%s=%s\n' "${k#DSH_}" "$v" ;;
          *)
            local a
            for a in "${DSC_ENV_ALLOW[@]}"; do
              if [[ "$k" == "$a" ]]; then v="$(sec_get "$k")"; [[ -n "$v" ]] && printf '%s=%s\n' "$k" "$v"; fi
            done ;;
        esac
      done < <(sec_list)
    fi
  } > "$tmp"
  mv -f "$tmp" "$dest"
  chmod 600 "$dest"
}

# Pull the pinned image; fall back to building the identical Containerfile.
dsc_ensure_image() {
  local version pin
  version="$(ds_want_version)"
  pin=""; [[ "$version" == "$DSH_NPM_VERSION_DEFAULT" ]] && pin="$DSH_NPM_SHA512_DEFAULT"
  WL_PULL="$(cap_config pull)" WL_BUILD="$(cap_config build)" \
    wl_ensure_image "$(dsc_image)" "$CAP_DIR" --build-arg "DSH_VERSION=$version" --build-arg "DSH_SHA512=$pin"
}

# The system unit, on the shared workload contract (lib/workload.sh): the
# harness gets a read-only rootfs, its two volumes, loopback publish, the
# env file, and the pinned control key for tenant sessions.
# shellcheck disable=SC2034  # WL_* are read by lib/workload.sh
dsc_workload_vars() {
  WL_NAME="dsh"
  WL_IMAGE="$(dsc_image)"
  WL_DESC="DeepSeek Harness web UI (container)"
  WL_PUBLISH=("$(dsc_port):$(dsc_port)")
  WL_VOLUMES=("$(dsc_workspace):/workspace:U" "$(dsc_home):/home/dsh:U")
  # The pinned control key is public material (0644); mounted read-only so
  # the gate can verify control-plane tenant sessions.
  [[ -f "$(dsc_control_pubkey)" ]] && WL_VOLUMES+=("$(dsc_control_pubkey):/run/alwayswork/control-pubkey.json:ro")
  WL_ENV_FILE="$(dsc_env_file)"
  WL_LABELS=("dev.alwayswork.workload=dsh" "dev.alwayswork.host=$(dsc_host)")
  WL_READ_ONLY=1
  WL_TMPFS=()
  WL_HEALTH=""
  WL_EXTRA=()
  WL_NETWORK="$(cap_config network)"
  WL_ARGS=()
}
dsc_write_unit() { dsc_workload_vars; wl_write_unit; }
dsc_apply_unit() { dsc_workload_vars; wl_apply_unit; }

# The pre-container unit ran the harness straight on the host. Retire it
# once the container is in place; the operator's old sessions stay in that
# account's home (nothing is deleted).
dsc_retire_legacy_unit() {
  if [[ -f "$DSH_UNIT_DIR/$DSH_LEGACY_UNIT" ]]; then
    log "agents.dsh: retiring the host-mode unit ($DSH_LEGACY_UNIT)"
    run systemctl disable --now "$DSH_LEGACY_UNIT" 2>/dev/null || true
    run rm -f "$DSH_UNIT_DIR/$DSH_LEGACY_UNIT"
  fi
}

dsc_report_webui() {
  local host="$1" port="$2"
  aw_write "$AW_STATE/webui.json" <<JSON
{"host":"$host","port":$port}
JSON
  chmod 644 "$AW_STATE/webui.json" 2>/dev/null || true
}
