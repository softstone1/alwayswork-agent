# shellcheck shell=bash
# alwayswork · control-plane client.

control_config_file() { echo "$AW_ETC/control.json"; }
control_key_file()    { echo "$AW_ETC/identity/device.key"; }
control_url()         { cfg_get '.control.url' "${ALWAYSWORK_CONTROL_URL:-}"; }
control_device_id()   { jq -r '.deviceId // ""' "$(control_config_file)" 2>/dev/null || true; }
control_poll_secret() { jq -r '.pollSecret // ""' "$(control_config_file)" 2>/dev/null || true; }
control_enrolled()    { [[ -n "$(control_device_id)" ]]; }

control_require() {
  require_cmd curl jq openssl
  [[ -n "$(control_url)" ]] || die "no control URL; run: aw enroll --control https://control.example.com --token aj_..."
}

control_ensure_key() {
  local key; key="$(control_key_file)"
  if [[ ! -f "$key" ]]; then
    log "control: generating device identity"
    ensure_dir "$AW_ETC/identity"
    # umask 077: openssl inherits the umask, so without this the fresh private
    # key would be briefly world-readable before the chmod below.
    ( umask 077; run openssl genpkey -algorithm ED25519 -out "$key" )
    run chmod 600 "$key"
  fi
}

control_pubkey_b64() {
  openssl pkey -in "$(control_key_file)" -pubout -outform DER 2>/dev/null | base64 -w0
}

control_machine_id() { cat /etc/machine-id 2>/dev/null || hostname; }

control_macs_json() {
  local f mac; local -a macs=()
  for f in /sys/class/net/*/address; do
    [[ -r "$f" ]] || continue
    mac="$(cat "$f" 2>/dev/null || true)"
    [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] && macs+=("$mac")
  done
  if (( "${#macs[@]}" > 0 )); then printf '%s\n' "${macs[@]}" | jq -R . | jq -s .; else echo '[]'; fi
}

control_dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || true; }
control_sign() {
  local msg sig
  msg="$(mktemp)"
  printf '%s' "$1" > "$msg"
  sig="$(openssl pkeyutl -sign -inkey "$(control_key_file)" -rawin -in "$msg" 2>/dev/null | base64 -w0)"
  rm -f "$msg"
  [[ -n "$sig" ]] || die "control: could not sign request (openssl)"
  printf '%s' "$sig"
}

# True when a response body carries an explicit revocation signal.
_control_is_revoked() {
  local json="$1" code msg state
  code="$(jq -r '.error.code // ""' <<<"$json" 2>/dev/null)"
  msg="$(jq -r '.error.message // ""' <<<"$json" 2>/dev/null)"
  state="$(jq -r '.state // ""' <<<"$json" 2>/dev/null)"
  [[ "$state" == "revoked" ]] && return 0
  [[ "${code,,}" == *revok* ]] && return 0
  [[ "${msg,,}" == *revok* ]] && return 0
  return 1
}

# control_call METHOD PATH [BODY] — signed device request.
#
# Prints the response body on stdout. Returns 0 on success, 1 on transient
# failure (network error, 5xx, empty body), 2 when the control plane reports
# this device revoked. It never dies: the polling daemon must survive
# transient outages, and revocation is handled by the caller, not by a crash.
#
# The signature covers the request path only: a query string travels in the URL
# but never enters the canonical string, because the control plane verifies
# `new URL(req.url).pathname`. Letting "?since=N" leak into the canonical text
# made every signed GET fail verification (401), which the client then mistook
# for an empty delivery and re-applied defaults on every tick.
control_call() {
  local method="${1^^}" path="$2" body="${3:-}"
  local url ts nonce bodyhash canonical sig signed_path resp http
  url="$(control_url)"
  signed_path="${path%%\?*}"
  ts="$(date +%s)"
  nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d '[:space:]')"
  bodyhash="$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)"
  canonical="$method
$signed_path
$ts
$nonce
$bodyhash"
  sig="$(control_sign "$canonical")"
  # Bounded: an agent tick must never hang forever on one stalled connection.
  # -w appends the HTTP status on its own last line so we can tell a refused
  # credential (revocation) apart from a transient failure.
  local -a args=(-sS --connect-timeout 5 --max-time 30 -X "$method" "$url$path"
    -H "x-device-id: $(control_device_id)"
    -H "x-timestamp: $ts"
    -H "x-nonce: $nonce"
    -H "x-signature: $sig"
    -w '\n%{http_code}')
  [[ -n "$body" ]] && args+=(-H 'content-type: application/json' --data "$body")
  if ! resp="$(curl "${args[@]}" 2>/dev/null)"; then
    warn "control: $method $signed_path failed (network)"
    return 1
  fi
  http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  if _control_is_revoked "$resp"; then
    printf '%s' "$resp"
    return 2
  fi
  if [[ -z "$resp" ]]; then
    warn "control: $method $signed_path -> empty response (transient)"
    return 1
  fi
  # Numeric guard first: a non-numeric status in [[ ... -ge ... ]] is a fatal
  # arithmetic error that aborts the whole shell, not just a false test.
  if [[ "$http" =~ ^[0-9]+$ ]] && (( http >= 500 )); then
    warn "control: $method $signed_path -> HTTP $http (transient)"
    return 1
  fi
  if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
    warn "control: $method $signed_path rejected -> $(jq -c '.error' <<<"$resp")"
  fi
  printf '%s' "$resp"
}
control_enroll() {
  local token="" url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token)         [[ -n "${2-}" ]] || die "missing value for --token (usage: aw enroll --control URL [--token TOKEN])"
                       token="$2"; shift ;;
      --control|--url) [[ -n "${2-}" ]] || die "missing value for $1 (usage: aw enroll --control URL [--token TOKEN])"
                       url="$2"; shift ;;
      -h|--help)       info "usage: aw enroll --control URL [--token TOKEN]"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  require_root enroll
  cfg_require
  cfg_need
  [[ -n "$url" ]] && cfg_set_str '.control.url' "$url"
  # Record the account agent work runs as while we still know who invoked us;
  # capabilities like agents.dsh need it to serve that account's sessions.
  if [[ -z "$(cfg_get '.agent.user' '')" ]]; then
    cfg_set_str '.agent.user' "${SUDO_USER:-$(id -un)}"
  fi
  control_require
  control_ensure_key
  if [[ "$(sec_backend)" == "sops" ]]; then sec_init; fi
  local recipient; recipient="$(sec_public_key)"
  [[ -n "$recipient" ]] || die "no age recipient; run: aw secrets init first"

  local payload
  payload="$(jq -n \
    --arg token "$token" \
    --arg pk "$(control_pubkey_b64)" \
    --arg age "$recipient" \
    --arg host "$(hostname)" \
    --arg mid "$(control_machine_id)" \
    --argjson macs "$(control_macs_json)" \
    --arg serial "$(control_dmi board_serial)" \
    --arg board "$(control_dmi board_name)" \
    --arg arch "$(uname -m)" \
    --arg os "$(hw_os_pretty)" \
    --arg ver "$AW_VERSION" \
    '{publicKey:$pk, ageRecipient:$age, hostname:$host, machineId:$mid, macs:$macs,
      serial:$serial, board:$board, arch:$arch, os:$os, agentVersion:$ver}
     + (if $token == "" then {} else {joinToken:$token} end)')"

  log "control: announcing this worker"
  local resp id secret
  resp="$(curl -sS --connect-timeout 5 --max-time 60 -X POST "$(control_url)/v1/enroll" -H 'content-type: application/json' --data "$payload")" \
    || die "control: POST /v1/enroll failed (network)"
  id="$(jq -r '.deviceId // ""' <<<"$resp")"
  secret="$(jq -r '.pollSecret // ""' <<<"$resp")"
  if [[ -z "$id" ]]; then
    die "enrollment failed: $(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null || echo "$resp")"
  fi
  ensure_dir "$AW_ETC"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] write %s\n' "$(control_config_file)" >&2
  else
    # umask 077: the poll secret must never be world-readable, even briefly.
    ( umask 077
      jq -n --arg id "$id" --arg secret "$secret" --arg url "$(control_url)" \
        '{deviceId:$id, pollSecret:$secret, controlUrl:$url}' > "$(control_config_file)" )
    chmod 600 "$(control_config_file)"
  fi
  ok "announced as $id"

  control_wait_approval "$id" "$secret"
}
control_wait_approval() {
  local id="$1" secret="$2" resp state
  info "waiting for approval in the console (Ctrl-C to stop)"
  while :; do
    if ! resp="$(curl -sS --connect-timeout 5 --max-time 30 "$(control_url)/v1/enroll/$id" -H "x-poll-secret: $secret")"; then
      warn "control: approval poll failed (network); retrying"
      sleep 3
      continue
    fi
    state="$(jq -r '.state // "unknown"' <<<"$resp")"
    case "$state" in
      approved) ok "approved"
               control_apply_delivery "$resp" || die "control: initial apply failed"
               return 0 ;;
      pending)  sleep 3 ;;
      *)        die "enrollment was $state" ;;
    esac
  done
}

# Apply a delivered { state, config, sealedSecrets } document to this box.
# A delivery that is not an approved config (an error body, a truncated
# response, a 401) is refused: falling back to defaults here would silently
# strip capabilities from the node and re-apply them on every tick.
control_apply_delivery() {
  local json="$1" profile sealed ver
  if [[ "$(jq -r '.state // ""' <<<"$json" 2>/dev/null)" != "approved" ]] ||
     [[ "$(jq -r '.config // empty' <<<"$json" 2>/dev/null)" == "" ]]; then
    die "control: refusing a malformed delivery: $(printf '%s' "$json" | head -c 200)"
  fi
  profile="$(jq -r '.config.profile // "foundation"' <<<"$json")"
  cfg_set_str '.profile' "$profile"
  cfg_set_expr '.capabilities.enabled' "$(jq -c '.config.capabilities // ["core"]' <<<"$json")"
  cfg_set_expr '.capabilities.apps' "$(jq -c '.config.apps // []' <<<"$json")" 2>/dev/null || true

  sealed="$(jq -r '.sealedSecrets // empty' <<<"$json")"
  if [[ -n "$sealed" && "$(sec_backend)" == "sops" ]]; then
    local enc dec
    enc="$(mktemp)"; dec="$(mktemp)"
    # mktemp files are 0600, but without this trap a dying step below would
    # leave the decrypted secrets file lingering in /tmp forever.
    trap 'rm -f "$enc" "$dec"' EXIT
    chmod 600 "$enc" "$dec"
    printf '%s' "$sealed" > "$enc"
    if age -d -i "$(sec_key_file)" "$enc" > "$dec" 2>/dev/null; then
      while IFS='=' read -r k v; do
        [[ -n "$k" ]] || continue
        sec_set "$k" "$(printf '%s' "$v" | jq -r . 2>/dev/null || printf '%s' "$v")"
      done < "$dec"
      ok "imported secret(s)"
    else
      warn "could not decrypt sealed secrets"
    fi
    rm -f "$enc" "$dec"
    trap - EXIT
  fi

  ver="$(jq -r '.config.configVersion // 0' <<<"$json")"
  log "control: applying desired state (version $ver)"
  # A failed apply must never be recorded or acked as successful: the version
  # stays unacked so the next tick retries the delivery instead of the node
  # drifting from the control plane in silence.
  if ! run "$AW_ROOT/bin/alwayswork" apply; then
    err "control: apply of version $ver failed"
    return 1
  fi
  # Record the applied version only after the reconcile succeeded, so a failed
  # apply stays unacked and is retried on the next tick.
  cfg_set_expr '.control.appliedVersion' "$ver"
}
# The node's own web UI, as the agent should report it: host + port only.
# The console needs a link target, not a credential - Access gates the hostname
# and the edge Worker injects the session.
control_webui_json() {
  local f="$AW_STATE/webui.json"
  [[ -s "$f" ]] || { printf 'null'; return 0; }
  jq -c 'if type == "object" and (.host | type == "string") and (.port | type == "number")
         then {host: .host, port: .port} else null end' "$f" 2>/dev/null || printf 'null'
}

# A revoked device must stop cleanly — not crash-loop behind Restart=always.
# The unit is disabled so systemd does not restart the agent into a revoke
# loop; re-enrolling mints a new keypair and re-enables it.
control_handle_revoked() {
  err "control: this worker was revoked by the operator; stopping the control agent"
  run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  exit 0
}

control_agent() {
  local interval="30" once=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once)    once=1 ;;
      -h|--help) info "usage: aw agent [interval] [--once]"; return 0 ;;
      *)         interval="$1" ;;
    esac
    shift
  done
  require_root agent
  cfg_require
  cfg_need
  control_require
  control_enrolled || die "this worker is not enrolled; run: aw enroll"
  if (( once )); then
    control_agent_tick
    return $?
  fi
  log "control agent: reporting every ${interval}s"
  local fails=0 pause i
  while :; do
    if control_agent_tick; then
      fails=0
    else
      fails=$(( fails + 1 ))
      warn "control: tick failed (${fails} consecutive); backing off"
    fi
    # Exponential backoff on consecutive failures, capped at 10 minutes, so a
    # transient outage neither kills the daemon nor hammers the server.
    pause="$interval"; i=1
    while (( i < fails && pause < 600 )); do pause=$(( pause * 2 )); i=$(( i + 1 )); done
    sleep "$pause"
  done
}

control_agent_tick() {
  local applied body resp desired delivery ver rc webui
  applied="$(cfg_get '.control.appliedVersion' 0)"
  webui="$(control_webui_json)"
  body="$(jq -n --argjson v "$applied" --argjson ui "$webui" \
    '{appliedVersion:$v, health:{}} + (if $ui == null then {} else {webUi:$ui} end)')"
  resp=""; rc=1
  if resp="$(control_call POST /v1/device/heartbeat "$body")"; then
    rc=0
  else
    rc=$?
  fi
  (( rc == 2 )) && control_handle_revoked
  (( rc == 0 )) || return 1
  desired="0"
  if ! desired="$(jq -r '.configVersion // 0' <<<"$resp")"; then
    warn "control: heartbeat response was not JSON; skipping delivery check"
    return 1
  fi
  if [[ "$desired" != "$applied" ]]; then
    log "control: desired version $desired (applied $applied)"
    delivery=""; rc=1
    if delivery="$(control_call GET "/v1/device/desired?since=$applied")"; then
      rc=0
    else
      rc=$?
    fi
    (( rc == 2 )) && control_handle_revoked
    (( rc == 0 )) || return 1
    if ! control_apply_delivery "$delivery"; then
      warn "control: apply of version $desired failed; it stays unacked and will be retried"
      return 1
    fi
    ver="$(jq -r '.config.configVersion // 0' <<<"$delivery")"
    # Ack only after a verified successful apply. appliedVersion is already
    # recorded above, so even if this ack is lost the next heartbeat reports it.
    control_call POST /v1/device/ack "$(jq -n --argjson v "$ver" '{configVersion:$v}')" >/dev/null \
      || warn "control: ack of version $ver failed (transient); the heartbeat will report it"
  fi
  return 0
}
