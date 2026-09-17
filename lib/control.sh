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
  [[ "$state" == "decommissioned" ]] && return 0
  [[ "${code,,}" == *revok* ]] && return 0
  [[ "${msg,,}" == *revok* ]] && return 0
  # A tombstoned device is rejected the same way: its identity is dead and the
  # agent must stop cleanly, never crash-loop.
  [[ "${code,,}" == *tombstone* ]] && return 0
  [[ "${msg,,}" == *tombstone* ]] && return 0
  return 1
}

# --- secret hygiene for curl -----------------------------------------------------
# Request bodies and secret headers must never appear on a process argument
# vector: any local user can read argv via ps(1). _secret_file writes its first
# argument to a 0600 temp file and stores the path in the variable named by
# its second argument; callers then pass the path to curl as --data @file
# (bodies) or --config file (secret headers). The file is removed explicitly
# on the normal path; the EXIT trap covers abnormal exits (die).
# Callers must clear the trap (trap - EXIT) after removing the file, matching
# the existing mktemp/trap idiom used in control_apply_delivery.
# _secret_file <content> <varname> — write $1 to a 0600 temp file and store the
# path in $2. Call it directly, never in a command substitution: a trap set
# inside $(...) fires when the substitution ends, deleting the file before the
# caller can use it.
_secret_file() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/aw-secret.XXXXXX")" || return 1
  chmod 600 "$f"
  printf '%s' "$1" > "$f"
  # Expanded now, not when the trap fires: the path comes from our own mktemp
  # template (no quotes or spaces possible), so baking it in is safe and the
  # cleanup works no matter when the shell exits.
  # shellcheck disable=SC2064
  trap "rm -f '$f'" EXIT
  printf -v "$2" '%s' "$f"
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
  # The body travels via a 0600 temp file, never on curl's argv: a future
  # caller must be able to put secret material here without a ps(1) leak.
  local bodyfile=""
  if [[ -n "$body" ]]; then
    _secret_file "$body" bodyfile || { warn "control: cannot stage request body"; return 1; }
    args+=(-H 'content-type: application/json' --data @"$bodyfile")
  fi
  if ! resp="$(curl "${args[@]}" 2>/dev/null)"; then
    if [[ -n "$bodyfile" ]]; then rm -f "$bodyfile"; trap - EXIT; fi
    warn "control: $method $signed_path failed (network)"
    return 1
  fi
  if [[ -n "$bodyfile" ]]; then rm -f "$bodyfile"; trap - EXIT; fi
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
  local token="" url="" usb=0 status_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token)         [[ -n "${2-}" ]] || die "missing value for --token (usage: aw enroll --control URL [--token TOKEN])"
                       token="$2"; shift ;;
      --control|--url) [[ -n "${2-}" ]] || die "missing value for $1 (usage: aw enroll --control URL [--token TOKEN])"
                       url="$2"; shift ;;
      --usb)           usb=1 ;;
      --status)        status_only=1 ;;
      -h|--help)       info "usage: aw enroll --control URL [--token TOKEN] [--usb] [--status]"
                       info "  no --token: register a pending claim and wait for console approval (headless-friendly)"
                       info "  --usb:      provision from a USB stick carrying alwayswork.toml"
                       info "  --status:   show enrollment / claim / decommission state"
                       return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  if (( status_only )); then control_enroll_status; return 0; fi
  require_root enroll
  cfg_require
  cfg_need
  [[ -n "$url" ]] && cfg_set_str '.control.url' "$url"
  # Record the account agent work runs as while we still know who invoked us;
  # capabilities like agents.dsh need it to serve that account's sessions.
  if [[ -z "$(cfg_get '.agent.user' '')" ]]; then
    cfg_set_str '.agent.user' "${SUDO_USER:-$(id -un)}"
  fi
  if (( usb )); then
    local toml
    toml="$(control_usb_find_provision)" || die "no alwayswork.toml found on any USB device"
    control_usb_apply "$toml" || die "USB provisioning failed"
    control_usb_consume "$toml"
    return 0
  fi
  control_require
  if [[ -z "$token" ]]; then
    # Headless-friendly default: the node registers a pending claim and the
    # operator approves it once in the web console. No monitor needed.
    control_claim_flow
    return 0
  fi
  control_enroll_with_token "$token"
  rm -f "$(decommission_marker)"
}

# control_enroll_with_token <token> — the join-token enrollment path, shared by
# `aw enroll --token`, USB provisioning, and approved pending claims.
control_enroll_with_token() {
  local token="$1"
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
  local resp id secret bodyfile
  # The payload carries the join token: it must never appear on curl's argv
  # (visible via ps), so it travels through a 0600 temp file instead. On the
  # die path the EXIT trap installed by _secret_file removes the file.
  _secret_file "$payload" bodyfile || die "control: cannot stage enrollment request"
  resp="$(curl -sS --connect-timeout 5 --max-time 60 -X POST "$(control_url)/v1/enroll" -H 'content-type: application/json' --data @"$bodyfile")" \
    || die "control: POST /v1/enroll failed (network)"
  rm -f "$bodyfile"; trap - EXIT
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
  local id="$1" secret="$2" resp state cfg esc_secret
  # The poll secret is a credential: curl has no -H @file, so it travels in a
  # 0600 --config file instead of on the argv header (visible via ps). Escape
  # for curl's config parser, where only \" and \\ are special inside quotes.
  esc_secret="${secret//\\/\\\\}"
  esc_secret="${esc_secret//\"/\\\"}"
  _secret_file "header = \"x-poll-secret: $esc_secret\"" cfg \
    || die "control: cannot stage approval poll"
  info "waiting for approval in the console (Ctrl-C to stop)"
  while :; do
    if ! resp="$(curl -sS --connect-timeout 5 --max-time 30 --config "$cfg" "$(control_url)/v1/enroll/$id")"; then
      warn "control: approval poll failed (network); retrying"
      sleep 3
      continue
    fi
    state="$(jq -r '.state // "unknown"' <<<"$resp")"
    case "$state" in
      approved) ok "approved"
               rm -f "$cfg"; trap - EXIT
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
  # A draining device decommissions itself: the operator removed this node in
  # the web console (or ran aw decommission elsewhere). Decommission is never
  # automatic — draining is always the result of an explicit operator decision.
  local device_state
  device_state="$(jq -r '.device_state // "active"' <<<"$resp" 2>/dev/null || printf 'active')"
  if [[ "$device_state" == "draining" ]]; then
    log "control: this node is draining; decommissioning"
    if decommission_run 0; then
      ok "control: decommission complete"
    else
      warn "control: decommission incomplete; will retry on the next tick"
      return 1
    fi
    run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
    exit 0
  fi
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

# --- pending claims (headless enrollment) -------------------------------------
# A node with no join token registers a pending claim: it posts its public key
# and a machine fingerprint, then waits for one console approval. The claim id
# and fingerprint are what the operator sees in the web console. No monitor on
# the node is ever needed.

control_claim_file() { echo "$AW_STATE/claim.json"; }

# Hex sha256 of the machine id: a stable fingerprint that never exposes the
# raw machine id on the wire.
control_machine_id_hash() {
  printf '%s' "$(control_machine_id)" | sha256sum | cut -d' ' -f1
}

control_claim_create() {
  control_ensure_key
  local payload resp claim_id expires bodyfile
  payload="$(jq -n \
    --arg pk "$(control_pubkey_b64)" \
    --arg host "$(hostname)" \
    --arg mid "$(control_machine_id_hash)" \
    '{device_pubkey:$pk, hostname:$host, machine_id_hash:$mid}')"
  # Device identity travels via a 0600 temp file, never on curl's argv. On the
  # die path the EXIT trap installed by _secret_file removes the file.
  _secret_file "$payload" bodyfile || die "control: cannot stage claim request"
  resp="$(curl -sS --connect-timeout 5 --max-time 30 -X POST "$(control_url)/v1/claims" \
    -H 'content-type: application/json' --data @"$bodyfile")" \
    || die "control: POST /v1/claims failed (network)"
  rm -f "$bodyfile"; trap - EXIT
  claim_id="$(jq -r '.claim_id // ""' <<<"$resp")"
  expires="$(jq -r '.expires_at // ""' <<<"$resp")"
  if [[ -z "$claim_id" ]]; then
    die "claim failed: $(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null | head -c 200)"
  fi
  ensure_dir "$AW_STATE"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] write %s\n' "$(control_claim_file)" >&2
  else
    # umask 077: claim state is node identity material, never world-readable.
    ( umask 077
      jq -n --arg id "$claim_id" --arg exp "$expires" \
        '{claim_id:$id, expires_at:$exp}' > "$(control_claim_file)" )
    chmod 600 "$(control_claim_file)"
  fi
  printf '%s' "$claim_id"
}

control_claim_resume_id() {
  local f id
  f="$(control_claim_file)"
  [[ -f "$f" ]] || return 1
  id="$(jq -r '.claim_id // ""' "$f" 2>/dev/null)"
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

control_claim_status() {
  curl -sS --connect-timeout 5 --max-time 30 "$(control_url)/v1/claims/$1/status"
}

# Interactive poll until the claim is approved or expires (for `aw enroll`).
control_claim_poll_wait() {
  local claim_id="$1" resp status api_token
  while :; do
    if ! resp="$(control_claim_status "$claim_id")"; then
      warn "control: claim poll failed (network); retrying"
      sleep 5
      continue
    fi
    status="$(jq -r '.status // "unknown"' <<<"$resp")"
    case "$status" in
      approved)
        api_token="$(jq -r '.api_token // ""' <<<"$resp")"
        [[ -n "$api_token" ]] || die "claim approved but the server sent no api_token"
        control_claim_complete "$api_token"
        return 0 ;;
      expired) die "claim expired; run 'aw enroll' again for a fresh one" ;;
      pending) sleep 5 ;;
      *) die "claim was $status" ;;
    esac
  done
}

# Single status check, for the first-boot provision timer: never blocks.
control_claim_poll_once() {
  local claim_id resp status api_token
  if ! claim_id="$(control_claim_resume_id)"; then
    [[ -n "$(control_url)" ]] || { warn "provision: no control URL; set it with: aw enroll --control URL"; return 1; }
    require_cmd curl jq openssl
    claim_id="$(control_claim_create)" || return 1
    info "provision: pending claim $claim_id registered; approve it in the web console"
    return 0
  fi
  resp="$(control_claim_status "$claim_id")" || { warn "provision: claim check failed (network); will retry"; return 1; }
  status="$(jq -r '.status // "unknown"' <<<"$resp")"
  case "$status" in
    approved)
      api_token="$(jq -r '.api_token // ""' <<<"$resp")"
      [[ -n "$api_token" ]] || { warn "provision: claim approved but no api_token came back"; return 1; }
      control_claim_complete "$api_token" ;;
    expired)
      warn "provision: claim expired; a fresh one will be registered next run"
      run rm -f "$(control_claim_file)" ;;
    pending) info "provision: claim $claim_id still pending approval" ;;
    *) warn "provision: unexpected claim status: $status" ;;
  esac
}

# Finish a claim the operator approved: exchange the single-use api_token
# through the normal join-token enrollment, then start the agent.
control_claim_complete() {
  local api_token="$1"
  log "control: claim approved; completing enrollment"
  control_enroll_with_token "$api_token"
  run rm -f "$(control_claim_file)" "$(decommission_marker)"
  run systemctl enable --now alwayswork-agent.service 2>/dev/null || true
  run systemctl disable --now alwayswork-provision.timer 2>/dev/null || true
  ok "enrolled via approved claim"
}

control_claim_flow() {
  control_require
  local claim_id
  if claim_id="$(control_claim_resume_id)"; then
    info "resuming pending claim $claim_id"
  else
    log "control: registering a pending claim for this node"
    claim_id="$(control_claim_create)"
  fi
  section "Approve this node in the web console"
  kv "claim id" "$claim_id"
  kv "hostname" "$(hostname)"
  kv "machine fingerprint" "$(control_machine_id_hash)"
  info "waiting for approval (Ctrl-C to stop)"
  control_claim_poll_wait "$claim_id"
}

# --- USB provisioning ----------------------------------------------------------
# A stick carrying alwayswork.toml provisions the node with zero typing:
#
#   hostname    = "node-01"
#   profile     = "worker"
#   control_url = "https://control.example.com"
#   join_token  = "aj_..."        # single-use, created in the web console

usb_toml_get() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n1
}

# Echo the path of a provisioning file, or return 1. Checks already-mounted
# media first, then read-only mounts removable partitions that aren't mounted.
control_usb_find_provision() {
  local d
  for d in /run/media/*/*/alwayswork.toml /media/*/alwayswork.toml; do
    [[ -f "$d" ]] && { printf '%s\n' "$d"; return 0; }
  done
  # The block-device scan mounts things: never do that in a dry run.
  [[ "$DRY_RUN" == "1" ]] && return 1
  have lsblk || return 1
  local dev mnt tmp
  while read -r dev; do
    [[ -b "$dev" ]] || continue
    findmnt -n "$dev" >/dev/null 2>&1 && continue
    mnt="$(mktemp -d)" || continue
    if mount -o ro "$dev" "$mnt" 2>/dev/null; then
      if [[ -f "$mnt/alwayswork.toml" ]]; then
        tmp="$(mktemp)"
        cp "$mnt/alwayswork.toml" "$tmp"
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
        printf '%s\n' "$tmp"
        return 0
      fi
      umount "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
  done < <(lsblk -rno NAME,RM,TYPE 2>/dev/null | awk '$2==1 && $3=="part" {print "/dev/"$1}')
  return 1
}

control_usb_apply() {
  local toml="$1" token url host prof
  token="$(usb_toml_get "$toml" join_token)"
  [[ -n "$token" ]] || { warn "provision: no join_token in $toml"; return 1; }
  cfg_require
  cfg_need
  url="$(usb_toml_get "$toml" control_url)"
  host="$(usb_toml_get "$toml" hostname)"
  prof="$(usb_toml_get "$toml" profile)"
  [[ -n "$url" ]] && cfg_set_str '.control.url' "$url"
  [[ -n "$host" ]] && run hostnamectl set-hostname "$host"
  [[ -n "$prof" ]] && cfg_set_str '.profile' "$prof"
  if [[ -z "$(cfg_get '.agent.user' '')" ]]; then
    cfg_set_str '.agent.user' "${SUDO_USER:-$(id -un)}"
  fi
  log "provision: enrolling from USB provisioning file"
  control_enroll_with_token "$token"
  run rm -f "$(decommission_marker)"
  run systemctl enable --now alwayswork-agent.service 2>/dev/null || true
  run systemctl disable --now alwayswork-provision.timer 2>/dev/null || true
  ok "provisioned from USB as $(control_device_id)"
}

# A consumed provisioning file must not linger: the token in it is single-use
# and now burned. Temp copies are shredded; the operator's stick just gets the
# file renamed so the next boot does not retry a dead token.
control_usb_consume() {
  local toml="$1"
  if [[ "$toml" == /tmp/* ]]; then
    if have shred; then run shred -u "$toml" 2>/dev/null || run rm -f "$toml"
    else run rm -f "$toml"; fi
  else
    run mv "$toml" "$toml.consumed" 2>/dev/null || true
  fi
}

# --- decommission ----------------------------------------------------------------
# Node lifecycle, Kubernetes-style: draining -> tombstoned -> wiped. Every
# phase is idempotent and recorded in $AW_STATE/decommission.json, so a reboot
# or a failed run resumes instead of redoing or skipping work. Nothing here is
# ever automatic: it always starts from an explicit operator decision, either
# `aw decommission` on the box or Decommission in the web console (which the
# agent observes as device_state=draining on its next tick).

decommission_marker() { echo "$AW_STATE/decommission.json"; }

decommission_phase_done() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  jq -e --arg p "$1" '.phases // [] | index($p) != null' "$(decommission_marker)" >/dev/null 2>&1
}

decommission_mark_phase() {
  local phase="$1" m t
  [[ "$DRY_RUN" == "1" ]] && return 0
  m="$(decommission_marker)"
  ensure_dir "$AW_STATE"
  if [[ -f "$m" ]]; then
    jq --arg p "$phase" '.phases += [$p] | .phases |= unique' "$m" > "$m.tmp" \
      && mv "$m.tmp" "$m"
  else
    t="$(date +%s)"
    jq -n --arg p "$phase" --argjson t "$t" \
      '{started_at:$t, phases:[$p], plane:"unknown", complete:false}' > "$m"
  fi
  chmod 600 "$m" 2>/dev/null || true
}

decommission_set_plane() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local m; m="$(decommission_marker)"
  [[ -f "$m" ]] || return 0
  jq --arg v "$1" '.plane = $v' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
}

decommission_in_progress() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  [[ -f "$(decommission_marker)" ]] || return 1
  ! decommission_completed
}

decommission_completed() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  jq -e '.complete == true' "$(decommission_marker)" >/dev/null 2>&1
}

# decommission_run <local_only> — all phases, non-interactive. Safe to call
# from `aw decommission`, the agent tick, or first-boot provisioning.
decommission_run() {
  local local_only="${1:-0}"
  _DECOM_DEVICE_ID="$(control_device_id)"
  _DECOM_HOSTNAME="$(hostname)"
  decommission_phase_drain || return 1
  decommission_phase_revoke "$local_only" || return 1
  decommission_phase_wipe || return 1
  decommission_phase_report
}

decommission_phase_drain() {
  decommission_phase_done drain && { info "decommission: drain already done"; return 0; }
  log "decommission: draining workloads (keeping core, network and the agent)"
  local -a keep=(core control.join access.tunnel access.tailscale)
  local -a targets=() known=() ordered=()
  local c k skip
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    skip=0
    for k in "${keep[@]}"; do [[ "$c" == "$k" ]] && { skip=1; break; }; done
    (( skip )) && continue
    targets+=("$c")
  done < <(cfg_list '.capabilities.enabled')
  if (( "${#targets[@]}" > 0 )); then
    # Reverse dependency order: dependents come down before their deps.
    for c in "${targets[@]}"; do
      cap_valid_id "$c" && cap_exists "$c" 2>/dev/null && known+=("$c")
    done
    if (( "${#known[@]}" > 0 )); then
      mapfile -t ordered < <(cap_resolve "${known[@]}" 2>/dev/null) || ordered=("${targets[@]}")
    else
      ordered=("${targets[@]}")
    fi
    local i cap
    for (( i = "${#ordered[@]}" - 1; i >= 0; i-- )); do
      cap="${ordered[i]}"
      cap_is_enabled "$cap" || continue
      log "decommission: removing $cap"
      cap_uninstall "$cap" || warn "decommission: uninstall of $cap reported an error; continuing"
      cfg_list_remove '.capabilities.enabled' "$cap"
    done
    # Anything resolve didn't know about still gets uninstalled.
    for c in "${targets[@]}"; do
      cap_is_enabled "$c" || continue
      log "decommission: removing $c"
      cap_uninstall "$c" || warn "decommission: uninstall of $c reported an error; continuing"
      cfg_list_remove '.capabilities.enabled' "$c"
    done
  fi
  decommission_mark_phase drain
}

decommission_phase_revoke() {
  local local_only="${1:-0}"
  decommission_phase_done revoke && { info "decommission: revoke already done"; return 0; }
  if ! control_enrolled; then
    info "decommission: node was never enrolled; nothing to revoke"
    decommission_set_plane "none"
    decommission_mark_phase revoke
    return 0
  fi
  local id; id="$(control_device_id)"
  log "decommission: asking the control plane to tombstone $id"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] POST /v1/device/$id/decommission"
    decommission_mark_phase revoke
    return 0
  fi
  local resp rc=1 attempt=0 delay=5
  while (( attempt < 5 )); do
    if resp="$(control_call POST "/v1/device/$id/decommission")"; then rc=0; break; fi
    rc=$?
    if (( rc == 2 )); then
      info "decommission: control plane already considers this node gone"
      rc=0; break
    fi
    attempt=$(( attempt + 1 ))
    warn "decommission: plane revocation failed (attempt $attempt/5); retrying in ${delay}s"
    sleep "$delay"; delay=$(( delay * 2 ))
  done
  if (( rc != 0 )); then
    if (( local_only )); then
      warn "decommission: plane unreachable; continuing locally (--local). Remove the node in the web console too."
      decommission_set_plane "queued"
      decommission_mark_phase revoke
      return 0
    fi
    err "decommission: control plane unreachable after 5 attempts; re-run with --local to wipe anyway"
    return 1
  fi
  decommission_set_plane "confirmed"
  decommission_mark_phase revoke
  return 0
}

decommission_phase_wipe() {
  decommission_phase_done wipe && { info "decommission: wipe already done"; return 0; }
  log "decommission: wiping device identity and secrets"
  local f
  # Key material: best-effort shred, then delete. (SSD wear-levelling means
  # shred is not a guarantee; the tombstone is the real revocation.)
  for f in "$(control_key_file)" "$(sec_key_file)"; do
    if [[ -f "$f" ]]; then
      if have shred; then run shred -u "$f" 2>/dev/null || run rm -f "$f"
      else run rm -f "$f"; fi
    fi
  done
  run rm -f "$(sec_file)"                 # sops-encrypted secret store
  run rm -f /etc/cloudflared/token        # tunnel token (0600)
  run rm -f "$(control_config_file)"      # control.json: deviceId + pollSecret
  run rm -f "$(control_claim_file)"       # pending claim, if any
  run rm -f "$AW_STATE/webui.json"
  # The restic password lives in the secret store (wiped above) and only ever
  # hits disk as a trapped temp file during a backup run: nothing persists.
  decommission_mark_phase wipe
}

decommission_phase_report() {
  local m plane="unknown"
  m="$(decommission_marker)"
  [[ -f "$m" ]] && plane="$(jq -r '.plane // "unknown"' "$m" 2>/dev/null)"
  if [[ "$DRY_RUN" != "1" ]]; then
    local t; t="$(date +%s)"
    jq --argjson t "$t" '.complete = true | .completed_at = $t' "$m" > "$m.tmp" \
      && mv "$m.tmp" "$m"
  fi
  section "node decommissioned"
  kv "node" "${_DECOM_HOSTNAME:-$(hostname)}"
  kv "device" "${_DECOM_DEVICE_ID:-never enrolled}"
  case "$plane" in
    confirmed) kv "control plane" "tombstoned" ;;
    queued)    kv "control plane" "NOT notified (--local); remove the node in the web console too" ;;
    none)      kv "control plane" "was never enrolled; nothing revoked" ;;
    *)         kv "control plane" "$plane" ;;
  esac
  kv "wiped" "device key, age key, secret store, tunnel token, control.json"
  info "rejoin with: aw enroll --control <url> [--token TOKEN] [--usb]"
}

# --- enrollment status -----------------------------------------------------------

control_enroll_status() {
  section "node enrollment"
  if control_enrolled; then
    kv "state" "active"
    kv "device id" "$(control_device_id)"
    kv "control plane" "$(control_url)"
  elif [[ -f "$(control_claim_file)" ]]; then
    kv "state" "pending approval"
    kv "claim id" "$(jq -r '.claim_id // "?"' "$(control_claim_file)" 2>/dev/null)"
    info "approve it in the web console; 'aw enroll' resumes the wait"
  else
    kv "state" "not enrolled"
    info "join with: aw enroll --control URL [--token TOKEN] [--usb]"
  fi
  if [[ -f "$(decommission_marker)" ]]; then
    if decommission_completed; then kv "decommission" "complete"
    else kv "decommission" "in progress (resumes automatically)"; fi
  fi
  if [[ -z "${AW_TEST:-}" ]] && systemctl list-unit-files alwayswork-agent.service >/dev/null 2>&1; then
    kv "agent" "$(systemctl is-active alwayswork-agent.service 2>/dev/null || echo unknown)"
  fi
}
