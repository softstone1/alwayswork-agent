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
DSH_CONTAINER="alwayswork-dsh"
DSH_UNIT="alwayswork-dsh.service"
DSH_LEGACY_UNIT="alwayswork-webui.service"
# Test seam: the harness suite renders units into a scratch directory.
DSH_UNIT_DIR="${AW_SYSTEMD_DIR:-/etc/systemd/system}"

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
  local ws; ws="$(dsc_workspace)"
  ensure_dir "$(dirname "$ws")"
  ensure_dir "$(dsc_home)"
  if [[ -d "$ws" ]]; then return 0; fi
  if hw_is_btrfs && have btrfs && [[ "$(findmnt -no FSTYPE --target "$(dirname "$ws")" 2>/dev/null)" == "btrfs" ]]; then
    log "agents.dsh: creating btrfs subvolume $ws"
    run btrfs subvolume create "$ws" >/dev/null || run mkdir -p "$ws"
  else
    run mkdir -p "$ws"
  fi
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
  local img; img="$(dsc_image)"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "agents.dsh: dry-run — would pull $img (or build ${CAP_DIR}/Containerfile)"
    return 0
  fi
  if podman image exists "$img" 2>/dev/null && [[ "$(cap_config pull)" != "always" ]]; then
    ok "image present: $img"
    return 0
  fi
  if [[ "$(cap_config build)" != "true" ]]; then
    log "agents.dsh: pulling $img"
    if run podman pull "$img" >/dev/null; then ok "pulled $img"; return 0; fi
    warn "agents.dsh: pull failed; building the same image locally"
  fi
  local version pin
  version="$(ds_want_version)"
  pin=""; [[ "$version" == "$DSH_NPM_VERSION_DEFAULT" ]] && pin="$DSH_NPM_SHA512_DEFAULT"
  log "agents.dsh: building $img from ${CAP_DIR}/Containerfile (dsh $version)"
  run podman build --pull=newer -t "$img" \
    --build-arg "DSH_VERSION=$version" --build-arg "DSH_SHA512=$pin" \
    -f "${CAP_DIR}/Containerfile" "${CAP_DIR}" >/dev/null \
    || die "agents.dsh: image build failed"
  ok "built $img"
}

# Extra podman flags beyond engine_build_args: the isolation contract.
dsc_isolation_args() {
  # shellcheck disable=SC2054  # the commas are podman's tmpfs option syntax
  DSC_ISO_ARGS=(--userns=auto --read-only --tmpfs "/tmp:rw,nosuid,size=512m")
  if [[ "$(cap_config network)" == "none" ]]; then DSC_ISO_ARGS+=(--network none); fi
}

# The system unit. podman runs in the foreground with sdnotify so systemd
# knows when the UI is really up; --replace makes restarts idempotent.
dsc_write_unit() {
  local img port host ws home envf podman_bin
  img="$(dsc_image)"; port="$(dsc_port)"; host="$(dsc_host)"
  ws="$(dsc_workspace)"; home="$(dsc_home)"; envf="$(dsc_env_file)"
  podman_bin="$(command -v podman || echo /usr/bin/podman)"
  engine_build_args
  dsc_isolation_args
  local flags pubkey_mount=""
  flags="$(printf '%q ' "${AW_ENGINE_ARGS[@]}" "${DSC_ISO_ARGS[@]}")"
  # The pinned control key is public material (0644); mounted read-only so
  # the gate can verify control-plane tenant sessions.
  if [[ -f "$(dsc_control_pubkey)" ]]; then
    pubkey_mount="--volume $(dsc_control_pubkey):/run/alwayswork/control-pubkey.json:ro "
  fi
  aw_write "$DSH_UNIT_DIR/$DSH_UNIT" <<UNIT
[Unit]
Description=AlwaysWork workload: DeepSeek Harness web UI (container)
Documentation=https://github.com/softstone1/alwayswork-agent
After=network-online.target
Wants=network-online.target
# Managed by alwayswork (capabilities/agents.dsh). Image: $img

[Service]
Type=notify
NotifyAccess=all
Restart=always
RestartSec=5
TimeoutStartSec=300
TimeoutStopSec=30
ExecStartPre=-$podman_bin rm -f $DSH_CONTAINER
ExecStart=$podman_bin run --rm --replace --sdnotify=conmon --name $DSH_CONTAINER \\
  ${flags}\\
  --publish 127.0.0.1:$port:$port \\
  --env-file $envf \\
  --volume $ws:/workspace:U \\
  --volume $home:/home/dsh:U \\
  ${pubkey_mount}\\
  --label dev.alwayswork.workload=dsh --label dev.alwayswork.host=$host \\
  $img
ExecStop=$podman_bin stop -t 10 $DSH_CONTAINER

[Install]
WantedBy=multi-user.target
UNIT
}

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
