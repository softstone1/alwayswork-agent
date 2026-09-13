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
    run openssl genpkey -algorithm ED25519 -out "$key"
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

# control_call METHOD PATH [BODY] — signed device request.
#
# The signature covers the request path only: a query string travels in the URL
# but never enters the canonical string, because the control plane verifies
# `new URL(req.url).pathname`. Letting "?since=N" leak into the canonical text
# made every signed GET fail verification (401), which the client then mistook
# for an empty delivery and re-applied defaults on every tick.
control_call() {
  local method="${1^^}" path="$2" body="${3:-}"
  local url ts nonce bodyhash canonical sig signed_path resp
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
  local -a args=(-sS -X "$method" "$url$path"
    -H "x-device-id: $(control_device_id)"
    -H "x-timestamp: $ts"
    -H "x-nonce: $nonce"
    -H "x-signature: $sig")
  [[ -n "$body" ]] && args+=(-H 'content-type: application/json' --data "$body")
  resp="$(curl "${args[@]}")" || die "control: $method $signed_path failed (network)"
  if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
    warn "control: $method $signed_path rejected -> $(jq -c '.error' <<<"$resp")"
  fi
  printf '%s' "$resp"
}
control_enroll() {
  local token="" url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token)         token="$2"; shift ;;
      --control|--url) url="$2"; shift ;;
      -h|--help)       info "usage: aw enroll --control URL [--token TOKEN]"; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  require_root enroll
  cfg_require
  cfg_need
  [[ -n "$url" ]] && cfg_set_str '.control.url' "$url"
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
  resp="$(curl -sS -X POST "$(control_url)/v1/enroll" -H 'content-type: application/json' --data "$payload")"
  id="$(jq -r '.deviceId // ""' <<<"$resp")"
  secret="$(jq -r '.pollSecret // ""' <<<"$resp")"
  if [[ -z "$id" ]]; then
    die "enrollment failed: $(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null || echo "$resp")"
  fi
  ensure_dir "$AW_ETC"
  jq -n --arg id "$id" --arg secret "$secret" --arg url "$(control_url)" \
    '{deviceId:$id, pollSecret:$secret, controlUrl:$url}' > "$(control_config_file)"
  run chmod 600 "$(control_config_file)"
  ok "announced as $id"

  control_wait_approval "$id" "$secret"
}
control_wait_approval() {
  local id="$1" secret="$2" resp state
  info "waiting for approval in the console (Ctrl-C to stop)"
  while :; do
    resp="$(curl -sS "$(control_url)/v1/enroll/$id" -H "x-poll-secret: $secret")"
    state="$(jq -r '.state // "unknown"' <<<"$resp")"
    case "$state" in
      approved) ok "approved"; control_apply_delivery "$resp"; return 0 ;;
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
  fi

  ver="$(jq -r '.config.configVersion // 0' <<<"$json")"
  log "control: applying desired state"
  run "$AW_ROOT/bin/alwayswork" apply
  # Record the applied version only after the reconcile succeeded, so a failed
  # apply stays unacked and is retried on the next tick.
  cfg_set_expr '.control.appliedVersion' "$ver"
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
    return 0
  fi
  log "control agent: reporting every ${interval}s"
  while :; do
    control_agent_tick || warn "control: tick failed"
    sleep "$interval"
  done
}

control_agent_tick() {
  local applied body resp desired delivery ver
  applied="$(cfg_get '.control.appliedVersion' 0)"
  body="$(jq -n --argjson v "$applied" '{appliedVersion:$v, health:{}}')"
  resp="$(control_call POST /v1/device/heartbeat "$body")"
  desired="$(jq -r '.configVersion // 0' <<<"$resp")"
  if [[ "$desired" != "$applied" ]]; then
    log "control: desired version $desired (applied $applied)"
    delivery="$(control_call GET "/v1/device/desired?since=$applied")"
    control_apply_delivery "$delivery"
    ver="$(jq -r '.config.configVersion // 0' <<<"$delivery")"
    control_call POST /v1/device/ack "$(jq -n --argjson v "$ver" '{configVersion:$v}')" >/dev/null
    cfg_set_expr '.control.appliedVersion' "$ver"
  fi
}
