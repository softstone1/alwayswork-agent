# shellcheck shell=bash
# alwayswork · Periderm workspaces (capability periderm.workspace).
#
# The control plane declares a node's Periderm change sessions in desired
# state as an optional top-level `periderm` object (PERIDERM_TECHNICAL_SPEC
# §9.1); there is no other channel. Each session is one workspace container
# on the workload contract (lib/workload.sh), built so the sandbox reaches
# nothing but its allowlisting proxy (§7.2):
#
#   periderm          an --internal podman network: no route out, no gateway
#                     to the world. Workspaces join this one only.
#   periderm-egress   a plain bridge, separate from the node's `alwayswork`
#                     network. Only the proxy (and preview forwarders) join it.
#   alwayswork-periderm-proxy      the egress proxy, on both networks; the
#                     workspace's HTTPS_PROXY. It refuses non-allowlisted hosts
#                     and every private, link-local and metadata address.
#   alwayswork-pdws-<hex>          one workspace per session: read-only root,
#                     tmpfs /tmp and /home/node, its own named volume at
#                     /workspace, the workspace token in a 0600 env file.
#   alwayswork-pdpv-<hex>          a TCP forwarder (the proxy image in
#                     FORWARD_TO mode) publishing the session's preview on
#                     127.0.0.1:<port>, reported as surface `pv-<hex>` so the
#                     tunnel names and routes it.
#
# <hex> is the 12 hex digits of the session's previewSurface (pv-<hex>): a
# stable, already-sanitised name for everything the session owns. Absent
# `periderm` = no workspaces here: everything above is removed (checkpoints
# live in the control plane, so a removed workspace volume loses nothing).

PD_CAP="periderm.workspace"
PD_NET="periderm"
PD_NET_EGRESS="periderm-egress"
PD_PROXY="periderm-proxy"              # WL_NAME → alwayswork-periderm-proxy
PD_PROXY_PORT=3128
PD_FWD_PORT=3129
PD_PREVIEW_BASE=21000                  # host ports 21000-24999, one per session
PD_PREVIEW_SPAN=4000
PD_METADATA_ADDR="169.254.169.254"

pd_env_dir()      { printf '%s/periderm' "$AW_ETC"; }
pd_env_file()     { printf '%s/pdws-%s.env' "$(pd_env_dir)" "$1"; }
pd_volume()       { printf 'alwayswork-pdws-%s' "$1"; }
pd_ws_name()      { printf 'pdws-%s' "$1"; }
pd_pv_name()      { printf 'pdpv-%s' "$1"; }
pd_enabled()      { cfg_list '.capabilities.enabled' 2>/dev/null | grep -qx -- "$PD_CAP"; }
pd_control_url()  { cfg_get '.control.url' "${ALWAYSWORK_CONTROL_URL:-}"; }

# pd_preview_port <hex>: the session's loopback port, deterministic in the
# reserved range: 21000 + (first four hex digits % 4000).
pd_preview_port() { printf '%d' "$(( PD_PREVIEW_BASE + (16#${1:0:4} % PD_PREVIEW_SPAN) ))"; }

# --- networks and firewall ---------------------------------------------------------
# Idempotent. An existing `periderm` network that is NOT internal is refused,
# never reused: a workspace on it would have a route out around the proxy.
pd_ensure_networks() {
  if [[ "$DRY_RUN" == "1" ]]; then
    info "periderm: dry-run — would create networks '$PD_NET' (--internal) and '$PD_NET_EGRESS'"
    return 0
  fi
  if ! podman network exists "$PD_NET" 2>/dev/null; then
    run podman network create --internal "$PD_NET" >/dev/null || { err "periderm: could not create network $PD_NET"; return 1; }
    ok "network '$PD_NET' created (internal)"
  fi
  if [[ "$(podman network inspect "$PD_NET" --format '{{.Internal}}' 2>/dev/null)" != "true" ]]; then
    err "periderm: network '$PD_NET' exists but is not --internal; refusing to place workspaces on it"
    return 1
  fi
  if ! podman network exists "$PD_NET_EGRESS" 2>/dev/null; then
    run podman network create "$PD_NET_EGRESS" >/dev/null || { err "periderm: could not create network $PD_NET_EGRESS"; return 1; }
    ok "network '$PD_NET_EGRESS' created"
  fi
}

pd_subnet() {
  local s; s="$(podman network inspect "$1" --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null)" || true
  [[ "$s" =~ ^[0-9./]+$ ]] && printf '%s' "$s"
}

# The way runtime.podman opens the workload subnet: DNS (aardvark-dns on each
# bridge gateway) from both subnets, forwarded egress from periderm-egress
# only, and the cloud metadata address dropped from it ahead of that allow.
# The internal network gets no forward rule — it has no route to forward.
pd_firewall_open() {
  local sub
  [[ "$DRY_RUN" == "1" ]] && { info "periderm: dry-run — would allow DNS and proxy egress for the periderm subnets"; return 0; }
  declare -F fw_active >/dev/null && fw_active || return 0
  if sub="$(pd_subnet "$PD_NET")"; then
    fw_allow_subnet_port "$PD_CAP" "$sub" 53 udp >/dev/null 2>&1 || true
    fw_allow_subnet_port "$PD_CAP" "$sub" 53 tcp >/dev/null 2>&1 || true
  else
    warn "periderm: could not read the $PD_NET subnet; workspaces may not resolve the proxy through a strict firewall"
  fi
  if sub="$(pd_subnet "$PD_NET_EGRESS")"; then
    fw_allow_subnet_port "$PD_CAP" "$sub" 53 udp >/dev/null 2>&1 || true
    fw_allow_subnet_port "$PD_CAP" "$sub" 53 tcp >/dev/null 2>&1 || true
    fw_allow_forward_from "$PD_CAP" "$sub" >/dev/null 2>&1 || true
    fw_deny_forward_to "$PD_CAP" "$sub" "$PD_METADATA_ADDR" >/dev/null 2>&1 \
      || warn "periderm: metadata drop not installed on this firewall; the proxy still refuses private and link-local addresses"
    ok "periderm egress allowed from $sub (metadata $PD_METADATA_ADDR dropped)"
  else
    warn "periderm: could not read the $PD_NET_EGRESS subnet; the proxy may have no egress through a strict firewall"
  fi
}

pd_firewall_close() {
  local sub
  declare -F fw_close_subnet_port >/dev/null || return 0
  for sub in "$(pd_subnet "$PD_NET" || true)" "$(pd_subnet "$PD_NET_EGRESS" || true)"; do
    [[ -n "$sub" ]] || continue
    fw_close_subnet_port "$PD_CAP" "$sub" 53 udp >/dev/null 2>&1 || true
    fw_close_subnet_port "$PD_CAP" "$sub" 53 tcp >/dev/null 2>&1 || true
  done
  if sub="$(pd_subnet "$PD_NET_EGRESS")"; then
    fw_close_forward_from "$PD_CAP" "$sub" >/dev/null 2>&1 || true
    fw_close_deny_forward_to "$PD_CAP" "$sub" "$PD_METADATA_ADDR" >/dev/null 2>&1 || true
  fi
}

# --- units -------------------------------------------------------------------------
# Every WL_* input set, so nothing leaks from the previous unit written here.
# shellcheck disable=SC2034  # WL_* are read by lib/workload.sh
pd_wl_reset() {
  WL_NAME="$1"; WL_IMAGE="$2"; WL_DESC="$3"
  WL_PUBLISH=(); WL_VOLUMES=(); WL_ENV_FILE=""; WL_LABELS=("dev.alwayswork.workload=$1")
  WL_READ_ONLY=1; WL_TMPFS=(); WL_HEALTH=""; WL_NETWORK="$PD_NET"; WL_ARGS=(); WL_EXTRA=()
  # The sandbox's confinement is not optional: when the node turned engine
  # hardening off (lib/engine.sh), these still apply here.
  engine_hardening_enabled || WL_EXTRA+=(--cap-drop ALL --security-opt no-new-privileges:true)
}

# pd_apply_proxy <image> <allow-csv>: the egress proxy, on both networks.
# shellcheck disable=SC2034
pd_apply_proxy() {
  local image="$1" allow="$2"
  pd_wl_reset "$PD_PROXY" "$image" "Periderm egress proxy (allowlist)"
  WL_EXTRA+=(--network "$PD_NET_EGRESS" --env "PROXY_PORT=$PD_PROXY_PORT" --env "PERIDERM_EGRESS_ALLOW=$allow"
             --cpus 1 --memory 256m --pids-limit 256)
  WL_PULL="" WL_BUILD="" wl_ensure_image "$image" || return 1
  wl_apply_unit
}

# pd_apply_workspace <hex> <workspace-json> <proxy-image>
# shellcheck disable=SC2034
pd_apply_workspace() {
  local hex="$1" ws="$2" sid app gen image cpu mem pids envf
  sid="$(jq -r '.sessionId // ""' <<<"$ws")"; app="$(jq -r '.appId // ""' <<<"$ws")"
  gen="$(jq -r '.generation // 0' <<<"$ws")"; image="$(jq -r '.image // ""' <<<"$ws")"
  cpu="$(jq -r '.limits.cpu // 2' <<<"$ws")"; mem="$(jq -r '.limits.memoryMb // 4096' <<<"$ws")"
  pids="$(jq -r '.limits.pids // 1024' <<<"$ws")"
  [[ "$sid" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || die "periderm: bad sessionId '$sid'"
  [[ "$app" =~ ^[A-Za-z0-9_-]{0,64}$ ]] || die "periderm: $sid: bad appId"
  [[ "$gen" =~ ^[0-9]{1,9}$ ]] || die "periderm: $sid: bad generation"
  [[ "$cpu" =~ ^[0-9]{1,2}(\.[0-9]{1,2})?$ && "$cpu" != 0 ]] || die "periderm: $sid: bad cpu limit '$cpu'"
  [[ "$mem" =~ ^[0-9]{3,6}$ ]] || die "periderm: $sid: bad memory limit '$mem'"
  [[ "$pids" =~ ^[0-9]{2,6}$ ]] || die "periderm: $sid: bad pids limit '$pids'"
  envf="$(pd_env_file "$hex")"
  pd_render_env "$envf" "$(jq -r '.sealedToken // ""' <<<"$ws")" || die "periderm: $sid: no usable workspace token"
  pd_wl_reset "$(pd_ws_name "$hex")" "$image" "Periderm workspace $sid"
  WL_LABELS+=("dev.alwayswork.periderm.session=$sid" "dev.alwayswork.periderm.app=$app" "dev.alwayswork.periderm.generation=$gen")
  WL_TMPFS=("/home/node:rw,nosuid,nodev,size=1g,mode=1777")
  WL_VOLUMES=("$(pd_volume "$hex"):/workspace:U")
  WL_ENV_FILE="$envf"
  # The last --cpus/--memory/--pids-limit wins over the engine defaults.
  WL_EXTRA+=(--cpus "$cpu" --memory "${mem}m" --pids-limit "$pids" --shm-size 256m)
  WL_PULL="" WL_BUILD="" wl_ensure_image "$image" || return 1
  wl_apply_unit
}

# pd_apply_preview <hex> <port> <proxy-image> <host-port>: the forwarder that
# publishes the workspace's preview server on loopback.
# shellcheck disable=SC2034
pd_apply_preview() {
  local hex="$1" port="$2" image="$3" hport="$4"
  pd_wl_reset "$(pd_pv_name "$hex")" "$image" "Periderm preview forwarder $hex"
  WL_PUBLISH=("$hport:$PD_FWD_PORT")
  WL_EXTRA+=(--network "$PD_NET_EGRESS" --env "FORWARD_TO=$(wl_container "$(pd_ws_name "$hex")"):$port"
             --env "PROXY_PORT=$PD_FWD_PORT" --cpus 0.5 --memory 128m --pids-limit 128)
  wl_apply_unit
}

# pd_render_env <path> <sealed>: decrypt the workspace token with the node's
# age identity (as control.sh opens sealedSecrets) and write the 0600 env
# file. The token goes from age's stdout to the file through builtins only:
# never an argv, never a log line. A token that does not look like one is
# refused and the previous file kept.
pd_render_env() {
  local dest="$1" sealed="$2" token url tmp
  if [[ "$DRY_RUN" == "1" ]]; then printf '    [dry-run] render %s\n' "$dest" >&2; return 0; fi
  [[ "$sealed" == -----BEGIN\ AGE\ ENCRYPTED\ FILE-----* ]] || { err "periderm: the workspace token is not an armored age file"; return 1; }
  have age || { err "periderm: age is not installed; cannot open the workspace token"; return 1; }
  [[ -r "$(sec_key_file)" ]] || { err "periderm: no age identity at $(sec_key_file)"; return 1; }
  token="$(printf '%s' "$sealed" | age -d -i "$(sec_key_file)" 2>/dev/null)" || { err "periderm: could not decrypt the workspace token"; return 1; }
  [[ "$token" =~ ^[A-Za-z0-9._~+/=-]{8,512}$ ]] || { err "periderm: the decrypted workspace token is malformed"; return 1; }
  url="$(pd_control_url)"
  [[ "$url" =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._~/-]*)?$ ]] || { err "periderm: no usable control URL (.control.url)"; return 1; }
  ensure_dir "$(dirname "$dest")"; chmod 700 "$(dirname "$dest")" 2>/dev/null || true
  tmp="$(umask 077; mktemp "${dest}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  printf 'PERIDERM_CONTROL=%s\nPERIDERM_WORKSPACE_TOKEN=%s\nHTTPS_PROXY=%s\nHTTP_PROXY=%s\nNO_PROXY=127.0.0.1,localhost\n' \
    "${url%/}" "$token" "http://$(wl_container "$PD_PROXY"):$PD_PROXY_PORT" "http://$(wl_container "$PD_PROXY"):$PD_PROXY_PORT" > "$tmp"
  mv -f "$tmp" "$dest"; chmod 600 "$dest"
}

# --- what is on the node ---------------------------------------------------------
# Every session suffix this node holds anything for: units, containers,
# volumes, env files. Removal must find a half-made workspace too.
pd_present() {
  local f n
  {
    for f in "$WL_UNIT_DIR"/alwayswork-pdws-*.service "$WL_UNIT_DIR"/alwayswork-pdpv-*.service "$(pd_env_dir)"/pdws-*.env; do
      [[ -e "$f" ]] && basename "$f"
    done
    if have podman; then
      podman ps -a --format '{{.Names}}' 2>/dev/null
      podman volume ls --format '{{.Name}}' 2>/dev/null
    fi
  } | while IFS= read -r n; do
    [[ "$n" =~ (^|alwayswork-)pd(ws|pv)-([0-9a-f]{12})(\.service|\.env)?$ ]] && printf '%s\n' "${BASH_REMATCH[3]}"
  done | sort -u
}

# wl_remove_unit, only when there is something to remove: a reconcile of an
# unchanged delivery must not daemon-reload once per absent forwarder.
pd_remove_unit() {
  local name="$1"
  if [[ -f "$WL_UNIT_DIR/$(wl_unit_name "$name")" ]] \
     || { have podman && [[ "$DRY_RUN" != "1" ]] && podman container exists "$(wl_container "$name")" 2>/dev/null; }; then
    wl_remove_unit "$name"
  fi
}

pd_remove_preview() {
  local hex="$1"
  pd_remove_unit "$(pd_pv_name "$hex")" || return 1
  [[ -f "$(wl_services_dir)/pv-$hex.json" ]] && wl_unreport_service "pv-$hex"
  return 0
}

# A session no longer delivered: forwarder, workspace, token and volume go.
pd_remove_session() {
  local hex="$1"
  log "periderm: removing workspace $hex"
  pd_remove_preview "$hex" || return 1
  pd_remove_unit "$(pd_ws_name "$hex")" || return 1
  run rm -f "$(pd_env_file "$hex")" || return 1
  if have podman && [[ "$DRY_RUN" != "1" ]] && podman volume exists "$(pd_volume "$hex")" 2>/dev/null; then
    run podman volume rm -f "$(pd_volume "$hex")" >/dev/null || return 1
  fi
}

pd_remove_proxy() { pd_remove_unit "$PD_PROXY"; }

# Everything Periderm placed on the node (capability removal, or a node that
# no longer has the capability while leftovers remain).
pd_remove_all() {
  local hex rc=0
  while IFS= read -r hex; do [[ -n "$hex" ]] && { pd_remove_session "$hex" || rc=1; }; done < <(pd_present)
  pd_remove_proxy || rc=1
  while IFS= read -r hex; do [[ -n "$hex" ]] && wl_unreport_service "pv-$hex"; done < <(pd_stale_surfaces)
  return "$rc"
}

# pd_stale_surfaces [hex...]: preview surfaces on file whose session is not
# among the given ones (all of them, given none).
pd_stale_surfaces() {
  local f id w
  for f in "$(wl_services_dir)"/pv-*.json; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .json)"; [[ "$id" =~ ^pv-([0-9a-f]{12})$ ]] || continue
    for w in "$@"; do [[ "$w" == "${BASH_REMATCH[1]}" ]] && continue 2; done
    printf '%s\n' "${BASH_REMATCH[1]}"
  done
}

# --- reconcile ---------------------------------------------------------------------
# periderm_apply_from_delivery <delivery-json>: converge this node's
# workspaces to the delivered set. Each workspace runs in a subshell, so a
# `die` (bad token, pull failure) fails that workspace, not the others and
# not the control agent; the caller isolates the whole step the same way.
periderm_apply_from_delivery() {
  local json="$1" pd n proxy allow i ws surface hex port hport paused rc=0
  local -a want=() used=()
  if ! pd_enabled; then
    if jq -e '(.periderm.workspaces // []) | length > 0' >/dev/null 2>&1 <<<"$json"; then
      warn "periderm: desired state carries workspaces but $PD_CAP is not enabled here; ignoring them"
    fi
    # Leftovers of a capability since removed: nothing Periderm runs without it.
    if [[ -n "$(pd_present)" || -f "$WL_UNIT_DIR/$(wl_unit_name "$PD_PROXY")" || -n "$(pd_stale_surfaces)" ]]; then
      pd_remove_all || return 1
    fi
    return 0
  fi
  # The label engine_build_args puts on every container (wl_workloads_json).
  # shellcheck disable=SC2034
  local CAP_ID="$PD_CAP"
  pd="$(jq -c '.periderm // null | if type == "object" then . else {} end' <<<"$json" 2>/dev/null)" || pd='{}'
  n="$(jq -r '(.workspaces // []) | if type == "array" then length else 0 end' <<<"$pd")"
  proxy="$(jq -r '.proxyImage // ""' <<<"$pd")"
  allow="$(jq -r '[(.egressAllow // [])[] | strings | select(test("^(\\*\\.)?[A-Za-z0-9.-]{1,253}$"))] | join(",")' <<<"$pd" 2>/dev/null)" || allow=""

  local active=0
  if (( n > 0 )); then
    have podman || [[ "$DRY_RUN" == "1" ]] || { err "periderm: podman not found; runtime.podman is a dependency"; return 1; }
    pd_ensure_networks || return 1
    active="$(jq -r '[.workspaces[] | select(.paused != true)] | length' <<<"$pd")"
  fi
  # The proxy runs while at least one workspace runs; it is the sandbox's only
  # way out, so a node that cannot run it runs no workspace either.
  if (( active > 0 )); then
    if [[ ! "$proxy" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
      err "periderm: no usable proxyImage in desired state; workspaces stay stopped"; active=0; rc=1
    elif ! ( pd_apply_proxy "$proxy" "$allow" ); then
      err "periderm: the egress proxy failed; workspaces stay stopped"; active=0; rc=1
    fi
  fi

  for (( i = 0; i < n; i++ )); do
    ws="$(jq -c ".workspaces[$i]" <<<"$pd")"
    surface="$(jq -r '.previewSurface // ""' <<<"$ws")"
    if [[ ! "$surface" =~ ^pv-([0-9a-f]{12})$ ]]; then
      warn "periderm: ignoring a workspace with bad previewSurface '$surface'"; rc=1; continue
    fi
    hex="${BASH_REMATCH[1]}"
    if [[ " ${want[*]:-} " == *" $hex "* ]]; then
      warn "periderm: two workspaces share previewSurface $surface; keeping the first"; rc=1; continue
    fi
    want+=("$hex")
    paused="$(jq -r '.paused == true' <<<"$ws")"
    if [[ "$paused" == true ]] || (( active == 0 )); then
      # Paused (or no proxy): stopped, volume kept for when it resumes.
      [[ "$paused" == true ]] && info "periderm: workspace $hex paused; stopped, volume kept"
      pd_remove_preview "$hex" || rc=1
      pd_remove_unit "$(pd_ws_name "$hex")" || rc=1
      run rm -f "$(pd_env_file "$hex")" || rc=1
      continue
    fi
    if ! ( pd_apply_workspace "$hex" "$ws" ); then
      err "periderm: workspace $hex failed"; rc=1; continue
    fi
    port="$(jq -r '.previewPort // "" | tostring' <<<"$ws")"
    if [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )); then
      # Deterministic per session; two sessions on one hashed port: the later
      # one in delivery order takes the next free port in the range.
      hport="$(pd_preview_port "$hex")"
      while [[ " ${used[*]:-} " == *" $hport "* ]]; do
        hport=$(( PD_PREVIEW_BASE + ((hport - PD_PREVIEW_BASE + 1) % PD_PREVIEW_SPAN) ))
      done
      used+=("$hport")
      if ( pd_apply_preview "$hex" "$port" "$proxy" "$hport" ); then
        wl_report_surface "$(pd_ws_name "$hex")" "$surface" http "$hport" "" "Periderm preview $(jq -r '.sessionId' <<<"$ws")"
      else
        err "periderm: preview forwarder for $hex failed"; rc=1
      fi
    else
      pd_remove_preview "$hex" || rc=1
    fi
  done

  # Present but not delivered: removed, volume included.
  local have_hex w keep
  while IFS= read -r have_hex; do
    [[ -n "$have_hex" ]] || continue
    keep=0; for w in "${want[@]:-}"; do [[ "$w" == "$have_hex" ]] && keep=1; done
    (( keep )) || pd_remove_session "$have_hex" || rc=1
  done < <(pd_present)
  while IFS= read -r have_hex; do [[ -n "$have_hex" ]] && wl_unreport_service "pv-$have_hex"; done < <(pd_stale_surfaces "${want[@]:-}")
  (( active > 0 )) || pd_remove_proxy || rc=1
  (( n > 0 )) && info "periderm: $n workspace(s) in desired state ($active running)"
  return "$rc"
}
