# shellcheck shell=bash
# alwayswork · control-plane client.

control_config_file() { echo "$AW_ETC/control.json"; }
control_key_file()    { echo "$AW_ETC/identity/device.key"; }
control_url()         { cfg_get '.control.url' "${ALWAYSWORK_CONTROL_URL:-}"; }
control_device_id()   { jq -r '.deviceId // ""' "$(control_config_file)" 2>/dev/null || true; }
control_poll_secret() { jq -r '.pollSecret // ""' "$(control_config_file)" 2>/dev/null || true; }
control_enrolled()    { [[ -n "$(control_device_id)" ]]; }
# Enrolled with a token but not yet approved by the operator: the device row
# exists (id + poll secret on disk) and the provision timer finishes the job.
control_pending()     { [[ "$(jq -r '.pending // false' "$(control_config_file)" 2>/dev/null)" == "true" ]]; }
control_set_pending() {
  local f; f="$(control_config_file)"
  [[ -f "$f" && "$DRY_RUN" != "1" ]] || return 0
  local tmp; tmp="$(mktemp "${f}.XXXXXX")" || return 1
  if jq --argjson p "$1" '.pending = $p' "$f" > "$tmp" 2>/dev/null; then chmod 600 "$tmp"; mv -f "$tmp" "$f"; else rm -f "$tmp"; fi
}

# The one place enrolment is finished: whatever path got the node approved
# (token, USB, claim, resumed pending), the agent starts here and the
# provisioning timer retires. Idempotent.
control_finish_enrolled() {
  control_set_pending false
  run rm -f "$(control_claim_file)" "$(decommission_marker)"
  run systemctl enable --now alwayswork-agent.service 2>/dev/null || true
  run systemctl disable --now alwayswork-provision.timer 2>/dev/null || true
}

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

# --- clock guard ---------------------------------------------------------------
# Every signed request carries a timestamp the control plane checks against a
# 300 s window, so a box whose clock is wrong after a power loss would sign
# requests that are rejected anyway — and a delivery expiry check against a
# bogus clock is meaningless. The clock is trusted when systemd-timesyncd (or
# any NTP client timedatectl knows about) reports it synced, OR when the wall
# clock is later than the floor below: this code did not exist before that
# date, so an earlier reading is provably wrong. The second rule covers boxes
# without timedatectl. AW_CLOCK_FLOOR overrides the floor (tests).
AW_CLOCK_FLOOR_DEFAULT=1789776000   # 2026-09-19T00:00:00Z, the date of this change

control_clock_trusted() {
  local synced floor now
  if have timedatectl; then
    synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [[ "$synced" == "yes" ]] && return 0
  fi
  floor="${AW_CLOCK_FLOOR:-$AW_CLOCK_FLOOR_DEFAULT}"
  now="$(date +%s 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ && "$floor" =~ ^[0-9]+$ ]] || return 1
  [[ "$now" -gt "$floor" ]]
}

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

# control_call METHOD PATH [BODY] [HEADER_FILE] — signed device request.
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
  local method="${1^^}" path="$2" body="${3:-}" header_file="${4:-}"
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
  # Optional 4th arg: capture the response headers (for delivery signature
  # verification) into a file instead of letting them mix into the body.
  [[ -n "$header_file" ]] && args+=(-D "$header_file")
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

# --- control-plane key pinning and delivery verification -----------------------
# Desired-state deliveries are signed by the control plane (Ed25519,
# x-aw-sig-* headers). The node pins the control-plane public key at
# enrollment — trust-on-first-use over TLS — and refuses any delivery that
# does not verify: wrong key, tampered body, expired signature, another
# device's delivery, or a sequence rollback. A rejected delivery is logged
# loudly and the last-known-good config is kept; nothing is applied.

control_pubkey_file() { echo "$AW_STATE/control-pubkey.json"; }

# _header_value <headerfile> <name> — first value of a response header,
# case-insensitive, CRLF-tolerant. Prints nothing when absent.
_header_value() {
  awk -v name="$2" 'BEGIN{IGNORECASE=1} {line=$0; sub(/\r$/,"",line)}
    tolower(line) ~ ("^" name ":") {sub(/^[^:]*:[ \t]*/,"",line); print line; exit}' "$1"
}

# control_pin_pubkey <kid> <pubkey_b64> <source> — pin the control-plane
# signing key (TOFU). A later mismatch is refused outright: it means MITM or
# key rotation, and rotation is deliberately explicit (re-enroll the node).
control_pin_pubkey() {
  local kid="$1" b64="$2" source="$3" f cur_kid cur_key
  f="$(control_pubkey_file)"
  [[ -n "$kid" && -n "$b64" ]] || die "control: refusing to pin an empty control-plane key"
  if [[ -f "$f" ]]; then
    cur_kid="$(jq -r '.kid // ""' "$f" 2>/dev/null)"
    cur_key="$(jq -r '.publicKey // ""' "$f" 2>/dev/null)"
    [[ "$cur_kid" == "$kid" && "$cur_key" == "$b64" ]] && return 0
    die "control: CONTROL-PLANE KEY MISMATCH (pinned=$cur_kid offered=$kid source=$source): refusing — possible MITM or key rotation; re-enroll this node to rotate trust"
  fi
  ensure_dir "$AW_STATE"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] pin control key %s\n' "$kid" >&2
  else
    # umask 077: the pinned key is node identity material, never world-readable.
    ( umask 077
      jq -n --arg kid "$kid" --arg key "$b64" --arg src "$source" --argjson t "$(date +%s)" \
        '{kid:$kid, publicKey:$key, pinned_at:$t, source:$src}' > "$f" )
    chmod 600 "$f"
  fi
  log "control: pinned control-plane signing key $kid (TOFU over TLS, source: $source)"
}

# control_ensure_pubkey — pin the key when this node enrolled before pinning
# existed. Still TOFU over TLS: one GET to the public /v1/control-key.
control_ensure_pubkey() {
  [[ -f "$(control_pubkey_file)" ]] && return 0
  control_require
  local resp kid b64
  if ! resp="$(curl -sS --connect-timeout 5 --max-time 30 "$(control_url)/v1/control-key" 2>/dev/null)"; then
    warn "control: cannot fetch control-plane signing key (network)"
    return 1
  fi
  kid="$(jq -r '.kid // ""' <<<"$resp" 2>/dev/null)"
  b64="$(jq -r '.publicKey // ""' <<<"$resp" 2>/dev/null)"
  if [[ -z "$kid" || -z "$b64" ]]; then
    warn "control: control plane sent no signing key; deliveries will be refused until it does"
    return 1
  fi
  control_pin_pubkey "$kid" "$b64" "control-key (TOFU)"
}

# control_verify_delivery <bodyfile> <headerfile> — 0 when the delivery is
# authentically from the pinned control-plane key, 1 otherwise (loud).
# Checks, in order: headers present, kid matches the pin, sequence is numeric,
# expiry is live (60s clock-skew allowance), Ed25519 signature over the
# canonical string. The device id in the canonical string is this node's own,
# so a delivery signed for another node fails verification here.
control_verify_delivery() {
  local bodyfile="$1" headerfile="$2"
  local kid seq exp sig
  kid="$(_header_value "$headerfile" "x-aw-sig-kid")"
  seq="$(_header_value "$headerfile" "x-aw-sig-seq")"
  exp="$(_header_value "$headerfile" "x-aw-sig-exp")"
  sig="$(_header_value "$headerfile" "x-aw-sig")"
  if [[ -z "$kid" || -z "$seq" || -z "$exp" || -z "$sig" ]]; then
    err "control: delivery is not signed (missing x-aw-sig-* headers); refusing"
    return 1
  fi
  local f pinned_kid pinned_key
  f="$(control_pubkey_file)"
  pinned_kid="$(jq -r '.kid // ""' "$f" 2>/dev/null)"
  pinned_key="$(jq -r '.publicKey // ""' "$f" 2>/dev/null)"
  if [[ -z "$pinned_kid" ]]; then
    err "control: no pinned control-plane key; refusing delivery"
    return 1
  fi
  if [[ "$kid" != "$pinned_kid" ]]; then
    err "control: delivery key id $kid does not match pinned $pinned_kid; refusing (possible rotation or MITM)"
    return 1
  fi
  [[ "$seq" =~ ^[0-9]+$ ]] || { err "control: delivery has a malformed sequence; refusing"; return 1; }
  [[ "$exp" =~ ^[0-9]+$ ]] || { err "control: delivery has a malformed signature expiry; refusing"; return 1; }
  local now_ms
  now_ms="$(date +%s%3N)"
  if (( exp + 60000 < now_ms )); then
    err "control: delivery signature expired; refusing"
    return 1
  fi
  local hash tmp
  hash="$(sha256sum "$bodyfile" | cut -d' ' -f1)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aw-verify.XXXXXX")" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  printf 'AW-DESIRED-V1\n%s\n%s\n%s\n%s' "$(control_device_id)" "$seq" "$exp" "$hash" > "$tmp/canonical"
  if ! printf '%s' "$sig" | base64 -d > "$tmp/sig" 2>/dev/null; then
    err "control: delivery signature is not valid base64; refusing"
    rm -rf "$tmp"; trap - EXIT; return 1
  fi
  if ! printf '%s' "$pinned_key" | base64 -d > "$tmp/pub.der" 2>/dev/null || \
     ! openssl pkey -pubin -inform DER -in "$tmp/pub.der" -outform PEM -out "$tmp/pub.pem" 2>/dev/null; then
    err "control: pinned control-plane key is corrupt; refusing"
    rm -rf "$tmp"; trap - EXIT; return 1
  fi
  if openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin \
       -in "$tmp/canonical" -sigfile "$tmp/sig" >/dev/null 2>&1; then
    log "control: delivery signature verified (kid $kid, sequence $seq)"
    rm -rf "$tmp"; trap - EXIT
    return 0
  fi
  err "control: DELIVERY SIGNATURE INVALID (kid $kid); refusing — keeping last-known-good config"
  rm -rf "$tmp"; trap - EXIT
  return 1
}

# control_verified_delivery <path> — GET a delivery, verify its signature,
# and print the body on stdout. Returns:
#   0  verified and newer than the applied version -> body on stdout
#   1  transient failure or verification failure -> caller backs off / logs
#   2  revoked (control_call's signal) -> caller handles revocation
#   3  verified but not newer -> nothing to do
control_verified_delivery() {
  local path="$1" hdr body out rc seq applied
  hdr="$(mktemp "${TMPDIR:-/tmp}/aw-hdr.XXXXXX")" || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$hdr'" EXIT
  if ! out="$(control_call GET "$path" "" "$hdr")"; then
    rc=$?
    rm -f "$hdr"; trap - EXIT
    return "$rc"
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/aw-body.XXXXXX")" || { rm -f "$hdr"; trap - EXIT; return 1; }
  # shellcheck disable=SC2064
  trap "rm -f '$hdr' '$body'" EXIT
  printf '%s' "$out" > "$body"
  if ! control_verify_delivery "$body" "$hdr"; then
    err "control: REJECTED delivery from $path; keeping last-known-good config"
    rm -f "$hdr" "$body"; trap - EXIT
    return 1
  fi
  # Monotonic sequence: never apply a delivery at or below the applied
  # version. A long-poll that wakes on timeout (not on change) returns the
  # current version; re-applying it would be noisy, and a replayed older
  # delivery must never move the node backwards.
  seq="$(_header_value "$hdr" "x-aw-sig-seq")"
  applied="$(cfg_get '.control.appliedVersion' 0)"
  [[ "$applied" =~ ^[0-9]+$ ]] || applied=0
  if (( seq < applied )); then
    err "control: delivery sequence $seq is older than applied $applied; refusing (replay/rollback)"
    rm -f "$hdr" "$body"; trap - EXIT
    return 1
  fi
  if (( seq == applied )); then
    log "control: delivery sequence $seq is already applied; keeping current config"
    rm -f "$hdr" "$body"; trap - EXIT
    return 3
  fi
  rm -f "$hdr" "$body"; trap - EXIT
  printf '%s' "$out"
  return 0
}

# control_maybe_drain — the heartbeat reported this identity retired
# (401 device_tombstoned). A decommissioned node must wipe itself, but ONLY
# on a verified signed drain order; a revoked node just stops. The drain
# order is the one read a tombstoned identity may still make. Never exits
# except to stop the agent; returns 1 when the drain order could not be
# fetched or verified (transient) so the tick retries instead of wiping or
# stopping on a network blip.
control_maybe_drain() {
  local hdr body out rc seq applied state mode
  hdr="$(mktemp "${TMPDIR:-/tmp}/aw-hdr.XXXXXX")" || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/aw-body.XXXXXX")" || { rm -f "$hdr"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -f '$hdr' '$body'" EXIT
  # since=0: the drain order is returned immediately, not long-polled.
  if ! out="$(control_call GET "/v1/device/desired?since=0" "" "$hdr")"; then
    rc=$?
    rm -f "$hdr" "$body"; trap - EXIT
    if (( rc == 2 )); then
      # Still tombstoned and not draining: a real revocation. Stop cleanly.
      control_handle_revoked
    fi
    warn "control: could not fetch the drain order (transient); will retry"
    return 1
  fi
  printf '%s' "$out" > "$body"
  if ! control_verify_delivery "$body" "$hdr"; then
    err "control: REJECTED drain order; keeping last-known-good config"
    rm -f "$hdr" "$body"; trap - EXIT
    return 1
  fi
  seq="$(_header_value "$hdr" "x-aw-sig-seq")"
  applied="$(cfg_get '.control.appliedVersion' 0)"
  [[ "$applied" =~ ^[0-9]+$ ]] || applied=0
  if (( seq < applied )); then
    err "control: drain order sequence $seq is older than applied $applied; refusing"
    rm -f "$hdr" "$body"; trap - EXIT
    return 1
  fi
  state="$(jq -r '.state // ""' "$body" 2>/dev/null)"
  if [[ "$state" != "draining" ]]; then
    # Tombstoned but not draining: revocation, not decommission. Stop.
    rm -f "$hdr" "$body"; trap - EXIT
    control_handle_revoked
  fi
  # "restore": false keeps alwayswork installed (--keep-agent); the default
  # is the full restore (docs/DECOMMISSION.md).
  mode="$(jq -r 'if .restore == false then "keep-agent" else "full" end' "$body" 2>/dev/null || echo full)"
  rm -f "$hdr" "$body"; trap - EXIT
  log "control: verified signed drain order (sequence $seq); decommissioning ($mode)"
  if decommission_run 0 "$mode"; then
    ok "control: decommission complete"
  else
    warn "control: decommission incomplete; will retry on the next tick"
    return 1
  fi
  run systemctl disable --now alwayswork-agent.service 2>/dev/null || true
  exit 0
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
                       info "  --usb:      provision from a USB stick carrying alwayswork/provision.toml"
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
  # Enrollment mints and pins keys and starts signing timestamped requests: a
  # box with a wrong clock would fail every one of them. Refuse until NTP
  # syncs (or the clock is at least plausible) rather than enroll into a loop.
  control_clock_trusted \
    || die "clock not trusted (NTP not synced and the wall clock reads $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)); set the time or wait for time-sync before enrolling"
  [[ -n "$url" ]] && cfg_set_str '.control.url' "$url"
  # Record the account agent work runs as while we still know who invoked us;
  # capabilities like agents.dsh need it to serve that account's sessions.
  if [[ -z "$(cfg_get '.agent.user' '')" ]]; then
    cfg_set_str '.agent.user' "${SUDO_USER:-$(id -un)}"
  fi
  if (( usb )); then
    local toml
    toml="$(control_usb_find_provision)" || die "no alwayswork/provision.toml (or alwayswork.toml) found on any USB device"
    control_usb_apply "$toml" || die "USB provisioning failed"
    control_usb_consume "$toml"
    return 0
  fi
  # A pending enrolment being resumed by hand (`aw enroll` again after the
  # console click, or before the timer gets to it) needs no new token.
  if [[ -z "$token" ]] && control_enrolled && control_pending; then
    info "resuming pending enrolment as $(control_device_id)"
    control_wait_approval "$(control_device_id)" "$(control_poll_secret)"
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
        '{deviceId:$id, pollSecret:$secret, controlUrl:$url, pending:true}' > "$(control_config_file)" )
    chmod 600 "$(control_config_file)"
  fi
  ok "announced as $id"

  # Pin the control-plane signing key now: trust-on-first-use over TLS. Every
  # later delivery must verify against this pin or be refused outright.
  local ck_kid ck_pub
  ck_kid="$(jq -r '.controlKey.kid // ""' <<<"$resp")"
  ck_pub="$(jq -r '.controlKey.publicKey // ""' <<<"$resp")"
  if [[ -n "$ck_kid" && -n "$ck_pub" ]]; then
    control_pin_pubkey "$ck_kid" "$ck_pub" "enroll"
  else
    warn "control: enroll response carried no signing key; will pin from /v1/control-key before the first delivery"
  fi

  control_wait_approval "$id" "$secret"
}
# control_wait_approval <id> <poll-secret>
#
# Long-polls the enrolment until the operator approves, then verifies and
# applies the first delivery and starts the agent. AW_ENROLL_WAIT=<seconds>
# bounds the wait (zero-touch installs use it so cloud-init and the USB
# provision service never hang): on timeout the node stays "pending" on disk
# and `aw provision` (the timer) resumes it after the console click.
control_wait_approval() {
  local id="$1" secret="$2" resp state hdr bodyf cfgf
  local max="${AW_ENROLL_WAIT:-0}" started; started="$(date +%s)"
  # The poll secret travels in a curl config file, never on the command line:
  # command lines are visible to every local user via /proc.
  cfgf="$(mktemp "${TMPDIR:-/tmp}/aw-cfg.XXXXXX")" || die "control: cannot stage approval poll"
  chmod 600 "$cfgf"
  printf 'header = "x-poll-secret: %s"\n' "$secret" > "$cfgf"
  hdr="$(mktemp "${TMPDIR:-/tmp}/aw-hdr.XXXXXX")" || die "control: cannot stage approval poll"
  bodyf="$(mktemp "${TMPDIR:-/tmp}/aw-body.XXXXXX")" || die "control: cannot stage approval poll"
  # shellcheck disable=SC2064
  trap "rm -f '$cfgf' '$hdr' '$bodyf'" EXIT
  if (( max > 0 )); then info "waiting up to ${max}s for approval in the console"
  else info "waiting for approval in the console (Ctrl-C to stop)"; fi
  while :; do
    if (( max > 0 )) && (( $(date +%s) - started >= max )); then
      rm -f "$cfgf" "$hdr" "$bodyf"; trap - EXIT
      control_set_pending true
      run systemctl enable --now alwayswork-provision.timer 2>/dev/null || true
      ok "enrolled as $id, pending approval"
      info "approve it in the console; this node completes enrolment on its own within a few minutes"
      return 0
    fi
    if ! curl -sS --connect-timeout 5 --max-time 30 -D "$hdr" -o "$bodyf" \
         --config "$cfgf" "$(control_url)/v1/enroll/$id" 2>/dev/null; then
      warn "control: approval poll failed (network); retrying"
      sleep 3
      continue
    fi
    resp="$(cat "$bodyf")"
    state="$(jq -r '.state // "unknown"' <<<"$resp")"
    case "$state" in
      approved)
        ok "approved"
        # The approval is the first signed delivery this node applies: make
        # sure the control-plane key is pinned (enrollment usually did this
        # already), then verify the delivery before applying anything it says.
        control_ensure_pubkey || { warn "control: cannot pin the control-plane key; retrying"; sleep 3; continue; }
        if ! control_verify_delivery "$bodyf" "$hdr"; then
          err "control: REJECTED approval delivery; keeping last-known-good config"
          sleep 3
          continue
        fi
        rm -f "$cfgf" "$hdr" "$bodyf"; trap - EXIT
        control_apply_delivery "$resp" || die "control: initial apply failed"
        control_finish_enrolled
        return 0 ;;
      pending)  sleep 3 ;;
      *)        rm -f "$cfgf" "$hdr" "$bodyf"; trap - EXIT
                control_set_pending false
                die "enrollment was $state" ;;
    esac
  done
}

# Single non-blocking check of a pending token enrolment, for the provision
# timer: approved -> verify, apply, start the agent; pending -> say so;
# anything else -> loud warning, state kept for the operator to inspect.
control_enroll_resume_once() {
  local id secret
  id="$(control_device_id)"; secret="$(control_poll_secret)"
  [[ -n "$id" && -n "$secret" ]] || { warn "provision: pending enrolment has no id/secret on disk"; return 1; }
  # One bounded poll: the server long-polls up to ~25s, which is fine for a
  # oneshot unit but must never turn into an open-ended wait.
  AW_ENROLL_WAIT=40 control_wait_approval "$id" "$secret"
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
  # The signed sequence and the config version must agree: a delivery whose
  # config claims a different version than the signature covered is either
  # corrupt or forged, and is refused before anything is applied.
  local seq
  seq="$(jq -r '.sequence // ""' <<<"$json" 2>/dev/null)"
  if [[ -n "$seq" && "$seq" != "$ver" ]]; then
    die "control: refusing delivery: config version ($ver) does not match the signed sequence ($seq)"
  fi
  log "control: applying desired state (version $ver)"
  # The tunnel token arrives ONLY over this verified channel, as a top-level
  # "tunnel" object ({token, hostname}). No tunnel section: existing tunnel
  # state is left alone. A failure keeps the version unacked so the next
  # tick retries the delivery.
  if tunnel_section_present "$json"; then
    tunnel_apply_from_delivery "$json" || { err "control: tunnel apply of version $ver failed"; return 1; }
  fi
  # The SSH access CA (policy `tunnel`) arrives the same way, as a top-level
  # "access" object. Absent or null: the CA file is left alone.
  control_apply_access "$json"
  # A failed apply must never be recorded or acked as successful: the version
  # stays unacked so the next tick retries the delivery instead of the node
  # drifting from the control plane in silence.
  if ! run "$AW_ROOT/bin/alwayswork" apply; then
    err "control: apply of version $ver failed"
    return 1
  fi
  # Deferred lockdown: public SSH goes off only once the node is active AND
  # reachable through its tunnel — never at install time, where it would cut
  # off access before the tunnel is verified. A deferred lockdown keeps the
  # version unacked so the next tick retries it.
  control_apply_lockdown "$json" || { err "control: lockdown of version $ver deferred"; return 1; }
  # Record the applied version only after the reconcile succeeded, so a failed
  # apply stays unacked and is retried on the next tick.
  cfg_set_expr '.control.appliedVersion' "$ver"
}

# control_apply_lockdown <delivery-json> — the zero-touch finale.
#
# The SSH lockdown never runs at install time. It runs here, automatically,
# once a verified delivery marks the node active — but only on
# tunnel-managed nodes, and only once cloudflared is actually up: the tunnel
# is the only way back in after sshd goes down, so cutting SSH first would
# strand the node. The policy is the delivered .config.hardening.ssh when
# present, else the node's own .hardening.ssh (default: disabled).
#
# Returns 1 when the lockdown cannot run yet (tunnel not up, or the policy
# could not be applied); the delivery stays unacked and the next tick
# retries. Returns 0 when there is nothing to do (no tunnel on this node, or
# an unknown policy — both logged loudly, never fatal).
control_apply_lockdown() {
  local json="$1" policy delivered
  if ! tunnel_managed; then
    info "control: no tunnel on this node; SSH stays operator-managed (bootstrap-time concern)"
    return 0
  fi
  delivered="$(jq -r '.config.hardening.ssh // ""' <<<"$json" 2>/dev/null)"
  if [[ -n "$delivered" ]]; then
    policy="$delivered"
    cfg_set_str '.hardening.ssh' "$policy"
  else
    policy="$(cfg_get '.hardening.ssh' 'disabled')"
  fi
  case "$policy" in
    disabled|tailscale|lan|tunnel) ;;
    *) warn "control: unknown SSH lockdown policy '$policy'; skipping lockdown"; return 0 ;;
  esac
  if ! systemctl is-active --quiet cloudflared 2>/dev/null; then
    warn "control: lockdown deferred — cloudflared is not up yet (SSH goes off only once the tunnel is reachable); will retry"
    return 1
  fi
  log "control: applying lockdown (hardening.ssh=$policy)"
  if cfg_bool '.hardening.firewall' true; then
    fw_ensure || warn "control: firewall lockdown failed; continuing with the SSH policy"
  fi
  # apply_ssh_policy dies on an unusable policy (tailscale without the
  # capability, lan without a detectable LAN address). In the agent that must
  # be a loud warning + retry, never a crash — so it runs in a subshell.
  ( apply_ssh_policy "$policy" ) || { warn "control: SSH lockdown failed; will retry"; return 1; }
  ok "control: lockdown applied (SSH policy: $policy)"
}

# control_apply_access <delivery-json> — the SSH access CA from desired state.
#
# SSH policy `tunnel` trusts short-lived certificates signed by the Cloudflare
# Access SSH CA (docs/SYSTEM_SPEC.md §5.4). The CA public key travels in the
# verified delivery as `access.sshCa` and is written to
# /etc/ssh/alwayswork_access_ca.pub; no authorized_keys are ever written. An
# absent or null `access` leaves the file alone, and a value that is not an
# OpenSSH public key line is refused loudly. Never fails the delivery: a bad
# CA is a warning, the rest of the desired state still applies.
control_access_ca_file() { printf '%s\n' "/etc/ssh/alwayswork_access_ca.pub"; }

control_apply_access() {
  local json="$1" ca f policy
  jq -e '.access | type == "object"' >/dev/null 2>&1 <<<"$json" || return 0
  jq -e '.access.sshCa | type == "string"' >/dev/null 2>&1 <<<"$json" || return 0
  ca="$(jq -r '.access.sshCa' <<<"$json" 2>/dev/null)"
  ca="${ca//$'\r'/}"
  # Trailing newlines are noise; an embedded one means more than one key line.
  while [[ "$ca" == *$'\n' ]]; do ca="${ca%$'\n'}"; done
  case "$ca" in
    "ssh-ed25519 "*|"ecdsa-"*|"ssh-rsa "*) ;;
    *) warn "control: access.sshCa is not an OpenSSH public key (expected ssh-ed25519 / ecdsa-* / ssh-rsa); leaving the CA untouched"; return 0 ;;
  esac
  if [[ "$ca" == *$'\n'* ]]; then
    warn "control: access.sshCa must be a single key line; leaving the CA untouched"
    return 0
  fi
  f="$(control_access_ca_file)"
  if [[ "$DRY_RUN" != "1" && -f "$f" && "$(cat "$f" 2>/dev/null)" == "$ca" ]]; then
    info "control: SSH access CA already current"
    return 0
  fi
  log "control: writing the SSH access CA ($f)"
  printf '%s\n' "$ca" | aw_write "$f" || { warn "control: could not write $f"; return 0; }
  run chmod 0644 "$f" || true
  # Only policy `tunnel` references the CA; sshd re-reads TrustedUserCAKeys on
  # reload. Other policies pick it up if and when they switch to tunnel.
  policy="$(jq -r '.config.hardening.ssh // ""' <<<"$json" 2>/dev/null)"
  [[ -n "$policy" ]] || policy="$(cfg_get '.hardening.ssh' disabled)"
  if [[ "$policy" == "tunnel" ]] && systemctl is-active --quiet sshd 2>/dev/null; then
    run systemctl reload sshd 2>/dev/null || warn "control: sshd reload failed; the CA applies on the next restart"
  fi
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
  # Enrolled but not yet approved: nothing to heartbeat with. The provision
  # timer completes enrolment; a clean exit keeps the unit from crash-looping.
  if control_pending; then
    warn "this worker is still pending approval; the provision timer completes enrolment"
    return 0
  fi
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
  local applied body resp desired delivery ver rc webui health
  # Nothing is signed against an untrusted clock: the control plane would
  # reject the timestamp anyway, and a delivery expiry check would be
  # meaningless. The tick backs off and retries once NTP has synced.
  if ! control_clock_trusted; then
    warn "control: clock not trusted; skipping signed calls until NTP syncs"
    return 1
  fi
  # The pinned key must exist before any delivery is trusted. Nodes that
  # enrolled before pinning existed fetch it once here (TOFU over TLS).
  control_ensure_pubkey || return 1
  applied="$(cfg_get '.control.appliedVersion' 0)"
  webui="$(control_webui_json)"
  # Typed health (docs/SYSTEM_SPEC.md §6); the doctor score inside it is
  # refreshed at most hourly.
  health_doctor_refresh
  health="$(control_health_json)"
  body="$(jq -n --argjson v "$applied" --argjson ui "$webui" --argjson h "$health" \
    '{appliedVersion:$v, health:$h} + (if $ui == null then {} else {webUi:$ui} end)')"
  resp=""; rc=1
  if resp="$(control_call POST /v1/device/heartbeat "$body")"; then
    rc=0
  else
    rc=$?
  fi
  # A retired identity (401 device_tombstoned) is either decommissioned — in
  # which case the node must wipe itself, but ONLY on a verified signed drain
  # order — or revoked, in which case it stops without wiping. A bare 401
  # never triggers a wipe on its own.
  (( rc == 2 )) && control_maybe_drain
  (( rc == 0 )) || return 1
  desired="0"
  if ! desired="$(jq -r '.configVersion // 0' <<<"$resp")"; then
    warn "control: heartbeat response was not JSON; skipping delivery check"
    return 1
  fi
  if [[ "$desired" != "$applied" ]]; then
    log "control: desired version $desired (applied $applied)"
    delivery=""; rc=1
    if delivery="$(control_verified_delivery "/v1/device/desired?since=$applied")"; then
      rc=0
    else
      rc=$?
    fi
    (( rc == 2 )) && control_handle_revoked
    # Verified but already applied (a race between heartbeat and fetch): rest
    # easy, the next tick will see the versions agree.
    (( rc == 3 )) && return 0
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
  local payload resp claim_id expires
  payload="$(jq -n \
    --arg pk "$(control_pubkey_b64)" \
    --arg host "$(hostname)" \
    --arg mid "$(control_machine_id_hash)" \
    '{device_pubkey:$pk, hostname:$host, machine_id_hash:$mid}')"
  resp="$(curl -sS --connect-timeout 5 --max-time 30 -X POST "$(control_url)/v1/claims" \
    -H 'content-type: application/json' --data "$payload")" \
    || die "control: POST /v1/claims failed (network)"
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
  control_finish_enrolled
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
# A FAT stick carrying `alwayswork/provision.toml` (what the console's Add-node
# flow downloads; the legacy top-level `alwayswork.toml` still works)
# provisions the node with zero typing:
#
#   control_url = "https://alwayswork.space"
#   join_token  = "aj_..."        # from the console; single-use or a fleet token
#   hostname    = "node-01"       # optional
#   profile     = "worker"        # optional
#
# The provision timer looks on every boot; the udev rule installed by
# control.join also fires it when a stick is plugged into a running box.

usb_toml_get() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n1
}

# The candidate file names inside a mounted volume, in order of preference.
USB_TOML_NAMES=(alwayswork/provision.toml alwayswork.toml)

_usb_toml_in() {
  local root="$1" n
  for n in "${USB_TOML_NAMES[@]}"; do
    [[ -f "$root/$n" ]] && { printf '%s\n' "$root/$n"; return 0; }
  done
  return 1
}

control_usb_find_provision() {
  local d f
  for d in /run/media/*/* /media/* /mnt/*; do
    [[ -d "$d" ]] || continue
    if f="$(_usb_toml_in "$d")"; then printf '%s\n' "$f"; return 0; fi
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
      if f="$(_usb_toml_in "$mnt")"; then
        tmp="$(mktemp)"
        cp "$f" "$tmp"
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
  [[ -n "$host" ]] && { ledger_hostname_before || warn "ledger: could not record the hostname"; }
  [[ -n "$host" ]] && run hostnamectl set-hostname "$host"
  [[ -n "$prof" ]] && cfg_set_str '.profile' "$prof"
  if [[ -z "$(cfg_get '.agent.user' '')" ]]; then
    cfg_set_str '.agent.user' "${SUDO_USER:-$(id -un)}"
  fi
  log "provision: enrolling from USB provisioning file"
  # Bounded: a stick for a group that needs a human approval must not hold
  # the provision service open; the timer resumes the pending enrolment.
  AW_ENROLL_WAIT="${AW_ENROLL_WAIT:-90}" control_enroll_with_token "$token"
  run rm -f "$(decommission_marker)"
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

# The restore choice (full | keep-foundation | keep-agent) is pinned in the
# marker when a run starts, so a resumed run (next boot, next tick) keeps
# the choice the operator or the drain order made.
decommission_set_mode() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local m; m="$(decommission_marker)"
  [[ -f "$m" ]] || return 0
  jq -e '.mode // "" | length > 0' "$m" >/dev/null 2>&1 && return 0
  jq --arg v "$1" '.mode = $v' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
}

decommission_mode() {
  local m v=""
  m="$(decommission_marker)"
  if [[ "$DRY_RUN" != "1" && -f "$m" ]]; then
    v="$(jq -r '.mode // ""' "$m" 2>/dev/null || true)"
  fi
  printf '%s\n' "${v:-${_DECOM_MODE:-full}}"
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

# decommission_run <local_only> [mode] — all phases, non-interactive. Safe
# to call from `aw decommission`, the agent tick, or first-boot provisioning.
# mode: full (default; the machine is restored from the ledger and aw removes
# itself), keep-foundation (firewall, ssh, the core capability and aw stay)
# or keep-agent (no restore at all: unenrolled, ready to re-join). A marker
# from an earlier, interrupted run wins over the argument.
decommission_run() {
  local local_only="${1:-0}"
  _DECOM_MODE="${2:-full}"
  case "$_DECOM_MODE" in
    full|keep-foundation|keep-agent) : ;;
    *) err "decommission: unknown mode '$_DECOM_MODE'"; return 1 ;;
  esac
  _DECOM_DEVICE_ID="$(control_device_id)"
  _DECOM_HOSTNAME="$(hostname)"
  decommission_phase_drain || return 1
  decommission_set_mode "$_DECOM_MODE"
  _DECOM_MODE="$(decommission_mode)"
  decommission_phase_revoke "$local_only" || return 1
  decommission_phase_wipe || return 1
  if ! decommission_phase_restore; then
    decommission_phase_report partial
    return 1
  fi
  decommission_phase_report
  if [[ "$_DECOM_MODE" == "full" ]]; then
    # Self last: everything else is undone and reported; this process keeps
    # running from the code it already loaded while its files disappear.
    ledger_self_remove || warn "decommission: alwayswork was not removed; delete $AW_ROOT by hand"
  fi
  return 0
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

# Restore: hand the machine back (docs/DECOMMISSION.md). The capabilities
# drain kept (core, control.join, access.*) come down first, then the ledger
# is replayed in reverse. control.join is never hook-uninstalled here: its
# uninstall stops the agent service, which may be the very process running
# this; its units are in the ledger, which knows how to stop itself safely.
decommission_phase_restore() {
  local mode; mode="$(decommission_mode)"
  decommission_phase_done restore && { info "decommission: restore already done"; return 0; }
  if [[ "$mode" == "keep-agent" ]]; then
    info "decommission: keeping alwayswork installed (keep-agent); nothing restored"
    decommission_mark_phase restore
    return 0
  fi
  log "decommission: restoring the machine ($mode)"
  local -a keep=(control.join) targets=() known=() ordered=()
  [[ "$mode" == "keep-foundation" ]] && keep+=(core)
  local c k skip
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    skip=0
    for k in "${keep[@]}"; do [[ "$c" == "$k" ]] && { skip=1; break; }; done
    (( skip )) && continue
    targets+=("$c")
  done < <(cfg_list '.capabilities.enabled')
  if (( "${#targets[@]}" > 0 )); then
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
  fi
  local -a opts=()
  [[ "$mode" == "keep-foundation" ]] && opts+=(--keep-foundation)
  _LEDGER_RESTORE_FAILED=0
  if ! ledger_restore "${opts[@]}"; then
    err "decommission: ${_LEDGER_RESTORE_FAILED:-some} ledger entr(ies) could not be restored; re-run 'aw decommission' to retry them"
    if [[ "$DRY_RUN" != "1" ]]; then
      local m; m="$(decommission_marker)"
      [[ -f "$m" ]] && jq --argjson n "${_LEDGER_RESTORE_FAILED:-0}" '.restore_failed = $n' "$m" > "$m.tmp" \
        && mv "$m.tmp" "$m"
    fi
    return 1
  fi
  decommission_mark_phase restore
}

# decommission_phase_report [partial] — print the outcome. Without
# `partial` the marker is sealed (complete = true).
decommission_phase_report() {
  local partial="${1:-}" m plane="unknown" mode failed=0
  m="$(decommission_marker)"
  mode="$(decommission_mode)"
  [[ -f "$m" ]] && plane="$(jq -r '.plane // "unknown"' "$m" 2>/dev/null)"
  [[ -f "$m" ]] && failed="$(jq -r '.restore_failed // 0' "$m" 2>/dev/null)"
  if [[ "$DRY_RUN" != "1" && -z "$partial" && -f "$m" ]]; then
    local t; t="$(date +%s)"
    jq --argjson t "$t" '.complete = true | .completed_at = $t | del(.restore_failed)' "$m" > "$m.tmp" \
      && mv "$m.tmp" "$m"
  fi
  if [[ -n "$partial" ]]; then section "node decommissioned (restore incomplete)"
  else section "node decommissioned"; fi
  kv "node" "${_DECOM_HOSTNAME:-$(hostname)}"
  kv "device" "${_DECOM_DEVICE_ID:-never enrolled}"
  case "$plane" in
    confirmed) kv "control plane" "tombstoned" ;;
    queued)    kv "control plane" "NOT notified (--local); remove the node in the web console too" ;;
    none)      kv "control plane" "was never enrolled; nothing revoked" ;;
    *)         kv "control plane" "$plane" ;;
  esac
  kv "wiped" "device key, age key, secret store, tunnel token, control.json"
  case "$mode" in
    full)
      if [[ -n "$partial" ]]; then
        kv "restore" "INCOMPLETE: ${failed:-0} entr(ies) failed; alwayswork kept for a retry"
        info "retry with: aw decommission (only the failed entries are attempted)"
      else
        kv "restore" "full: firewall, ssh, packages, units and files as before; alwayswork removed"
        info "this machine is no longer managed; reinstall to rejoin"
      fi ;;
    keep-foundation)
      if [[ -n "$partial" ]]; then
        kv "restore" "INCOMPLETE: ${failed:-0} entr(ies) failed; re-run 'aw decommission' to retry"
      else
        kv "restore" "kept the hardened base (firewall, ssh, core) and alwayswork"
      fi
      info "rejoin with: aw enroll --control <url> [--token TOKEN] [--usb]" ;;
    *)
      kv "restore" "none (keep-agent): alwayswork stays installed, unenrolled"
      info "rejoin with: aw enroll --control <url> [--token TOKEN] [--usb]" ;;
  esac
}

# --- enrollment status -----------------------------------------------------------

control_enroll_status() {
  section "node enrollment"
  if control_enrolled && control_pending; then
    kv "state" "pending approval"
    kv "device id" "$(control_device_id)"
    kv "control plane" "$(control_url)"
    info "approve it in the web console; the provision timer (or 'aw enroll') completes enrolment"
  elif control_enrolled; then
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
