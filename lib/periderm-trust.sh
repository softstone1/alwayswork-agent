# shellcheck shell=bash
# alwayswork · Periderm trust loop on the node (PERIDERM_TECHNICAL_SPEC §8.5,
# §9.1-§9.4): the builder, verifier and runtime roles.
#
# The delivery's `periderm` block carries, next to the workspaces
# (lib/periderm.sh), signed `work` items and `activations`:
#
#   work         {id, kind: build|verify|backup, attempt, expiresAt, request,
#                 bodySha256, signature: {domain, kid, value}}
#                Each item is checked before anything runs: bodySha256 is
#                recomputed over the canonical JSON of {id, kind, attempt,
#                expiresAt, request}; the pinned control-plane key must have
#                signed  <domain>\n<this device id>\n<id>\n<attempt>\n
#                <expiresAt>\n<bodySha256>  in the kind's own domain
#                (AW-BUILD-V1 / AW-VERIFY-V1 / AW-BACKUP-V1); it must not have
#                expired; and its kind's role must be enabled here:
#                  build  -> periderm.builder    verify -> periderm.verifier
#                  backup -> periderm.runtime
#   activations  production releases for apps whose production runs here
#                (periderm.runtime): a listener per app, one instance per
#                release, and a local watchdog that switches traffic and
#                reverts on its own (§9.4).
#
# Work runs detached (a transient systemd unit, `aw periderm job`), at most
# once per (workId, attempt): a claim directory under
# $AW_STATE/periderm/work/<id>.<attempt>/ is made before the job starts and
# is never made twice. Results and activation reports go through an outbox
# ($AW_STATE/periderm/outbox) that is flushed in order on every tick, so a
# report made while the control plane is unreachable arrives later.
#
# The verifier role is the only one with the host podman socket (it drives
# candidates through it), so it never shares a node with another Periderm
# role: such a node runs no Periderm work at all.

PD_ROLE_WORKSPACE="periderm.workspace"
PD_ROLE_BUILDER="periderm.builder"
PD_ROLE_VERIFIER="periderm.verifier"
PD_ROLE_RUNTIME="periderm.runtime"
PD_VERIFY_NET="periderm-verify"
PD_PODMAN_SOCK="${PD_PODMAN_SOCK:-/run/podman/podman.sock}"
PD_APP_BASE=25000                      # app listeners 25000-28999 (previews: 21000-24999)
PD_APP_SPAN=4000
PD_PART_BYTES="${PD_PART_BYTES:-33554432}"      # 32 MiB upload parts
PD_BUILD_TIMEOUT="${PD_BUILD_TIMEOUT:-2700}"    # s; build work lives 60 min
PD_VERIFY_TIMEOUT="${PD_VERIFY_TIMEOUT:-5400}"  # s; verify work lives 2 h
PD_RETRY_SLEEP="${PD_RETRY_SLEEP:-5}"
PD_REVERT_FAILS=3

# Canonical JSON exactly as the control plane's canonicalJson (JSON.stringify
# of recursively key-sorted objects). `jq -S -c` alone is not that: JS puts
# integer-like keys first in numeric order, writes exponents as `e`, and does
# not escape U+007F. Numbers are kept as written — the input is JS output.
# tests/periderm-trust.sh checks this against node.
# shellcheck disable=SC2016
PD_JQ_CANON='def canon:
  if type == "object" then
    (keys_unsorted as $k
     | ($k | map(select(test("^(0|[1-9][0-9]{0,9})$")) | select(tonumber < 4294967295)) | sort_by(tonumber)) as $i
     | ($i + (($k - $i) | sort))) as $o
    | "{" + ([$o[] as $key | ($key | canon) + ":" + (.[$key] | canon)] | join(",")) + "}"
  elif type == "array" then "[" + (map(canon) | join(",")) + "]"
  elif type == "string" and test("\u007f") then "\"" + (split("\u007f") | map(tojson | .[1:-1]) | join("\u007f")) + "\""
  elif type == "number" then tojson | ascii_downcase
  else tojson end;'

pd_role_enabled() { cfg_list '.capabilities.enabled' 2>/dev/null | grep -qx -- "$1"; }
pd_trust_roles()  { cfg_list '.capabilities.enabled' 2>/dev/null | grep -xE 'periderm\.(builder|verifier|runtime)' || true; }
pd_role_of_kind() { case "$1" in build) echo "$PD_ROLE_BUILDER" ;; verify) echo "$PD_ROLE_VERIFIER" ;; backup) echo "$PD_ROLE_RUNTIME" ;; *) return 1 ;; esac; }
pd_domain_of_kind() { case "$1" in build) echo AW-BUILD-V1 ;; verify) echo AW-VERIFY-V1 ;; backup) echo AW-BACKUP-V1 ;; *) return 1 ;; esac; }
# A node with the verifier role and any other Periderm role.
pd_verifier_conflict() {
  pd_role_enabled "$PD_ROLE_VERIFIER" || return 1
  pd_role_enabled "$PD_ROLE_WORKSPACE" || pd_role_enabled "$PD_ROLE_BUILDER" || pd_role_enabled "$PD_ROLE_RUNTIME"
}

pd_trust_dir()  { printf '%s/periderm' "$AW_STATE"; }
pd_work_dir()   { printf '%s/work/%s.%s' "$(pd_trust_dir)" "$1" "$2"; }
pd_act_dir()    { printf '%s/activations/%s' "$(pd_trust_dir)" "$1"; }
pd_app_dir()    { printf '%s/apps/%s' "$(pd_trust_dir)" "$1"; }
pd_verify_dir() { printf '%s/verify/%s' "$(pd_trust_dir)" "$1"; }
pd_outbox_dir() { printf '%s/outbox' "$(pd_trust_dir)"; }
pd_now_ms()     { date +%s%3N; }
pd_short()      { printf '%s' "$1" | sha256sum | cut -c1-12; }
pd_canon_sha()  { jq -j "$PD_JQ_CANON canon" | sha256sum | cut -d' ' -f1; }   # JSON on stdin
pd_sleep_ms()   { sleep "$(( $1 / 1000 )).$(printf '%03d' $(( $1 % 1000 )))"; }

# Names of a production app (hex = the 12 digits of appSurface pa-<hex>).
pd_app_lb()      { printf 'pdapp-%s-lb' "$1"; }
pd_app_inst()    { printf 'pdapp-%s-%s' "$1" "${2:0:12}"; }      # <hex> <image-hex64>
pd_app_volume()  { printf 'pdapp-%s-data' "$1"; }
pd_app_envfile() { printf '%s/pdapp-%s.env' "$(pd_env_dir)" "$1"; } # <inst-suffix> = <hex>-<img12>
# The control plane's appSurfaceId: "pa-" + sha256(appId)[0:12].
pd_app_hex_of()  { printf '%s' "$1" | sha256sum | cut -c1-12; }

pd_mkdir_private() { mkdir -p "$1" && chmod 700 "$1"; }

# --- the outbox -----------------------------------------------------------------------
# pd_outbox_put <method> <path> <json-body>: queue one signed call. Files are
# named by time, so a flush sends them in the order they were made.
pd_outbox_put() {
  local d f
  d="$(pd_outbox_dir)"; pd_mkdir_private "$d" || return 1
  f="$d/$(date +%s%N)-$$-$RANDOM.json"
  jq -nc --arg m "$1" --arg p "$2" --argjson b "$3" '{method:$m, path:$p, body:$b}' > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# Send what is queued, oldest first; stop at the first transient failure so
# the order holds. A call the control plane answers (even with a refusal) is
# done. 0 when the outbox is empty afterwards.
pd_outbox_flush() {
  local d; d="$(pd_outbox_dir)"
  [[ -d "$d" ]] || return 0
  (
    if have flock; then exec 9>"$d/.lock"; flock -w 60 9 || exit 1; fi
    local f m p b
    for f in "$d"/*.json; do
      [[ -f "$f" ]] || continue
      m="$(jq -r '.method' "$f" 2>/dev/null)"; p="$(jq -r '.path' "$f" 2>/dev/null)"; b="$(jq -c '.body' "$f" 2>/dev/null)"
      if [[ ! "$m" =~ ^(POST|PUT)$ || ! "$p" =~ ^/v1/device/periderm/[A-Za-z0-9_./-]+$ ]]; then
        warn "periderm: dropping a malformed outbox entry $(basename "$f")"; rm -f "$f"; continue
      fi
      if control_call "$m" "$p" "$b" >/dev/null; then rm -f "$f"; else exit 1; fi
    done
  )
}

pd_post_result() { # <workId> <attempt> <result-json>
  pd_outbox_put POST "/v1/device/periderm/work/$1/result" "$(jq -nc --argjson a "$2" --argjson r "$3" '{attempt:$a, result:$r}')" || return 1
  # Queued for the control plane: this attempt has said its result.
  [[ -d "$(pd_work_dir "$1" "$2")" ]] && touch "$(pd_work_dir "$1" "$2")/reported"
  pd_outbox_flush || warn "periderm: result of $1 queued; it is sent when the control plane answers"
}

pd_act_report() { # <activationId> <state> [detail-json]
  local body
  body="$(jq -nc --arg s "$2" --argjson d "${3:-null}" '{state:$s} + (if $d == null then {} else {detail:$d} end)')"
  pd_outbox_put POST "/v1/device/periderm/activations/$1/report" "$body" || return 1
  pd_outbox_flush || warn "periderm: activation $1 report '$2' queued (control plane unreachable)"
}

# --- blobs ------------------------------------------------------------------------------
# pd_blob_get <key> <dest> [sha256]: download a blob the node's work names;
# with a digest, anything else is refused.
pd_blob_get() {
  local key="$1" dest="$2" want="${3:-}" enc i got
  enc="$(jq -rn --arg k "$key" '$k | @uri')"
  for i in 1 2 3; do
    if control_call_raw GET "/v1/device/periderm/blobs?key=$enc" "" "$dest.part" 1800; then
      if [[ -n "$want" ]]; then
        got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
        if [[ "$got" != "$want" ]]; then
          err "periderm: $key digest $got is not the expected $want; refusing it"
          rm -f "$dest.part"; return 1
        fi
      fi
      mv -f "$dest.part" "$dest"; return 0
    fi
    rm -f "$dest.part"
    (( i < 3 )) && sleep "$PD_RETRY_SLEEP"
  done
  err "periderm: could not download $key"
  return 1
}

# pd_blob_put <workId> <file> <key>: upload a work's output to the key the
# control plane chose. One request up to a part's size, multipart above it.
pd_blob_put() {
  local id="$1" file="$2" key="$3" size out resp uid n parts i ok
  size="$(stat -c %s "$file")" || return 1
  out="$(mktemp)"
  if (( size <= PD_PART_BYTES )); then
    for i in 1 2 3; do
      if control_call_raw POST "/v1/device/periderm/work/$id/upload" "$file" "$out" 1800; then rm -f "$out"; return 0; fi
      (( i < 3 )) && sleep "$PD_RETRY_SLEEP"
    done
    rm -f "$out"; err "periderm: upload for $id failed"; return 1
  fi
  if ! resp="$(control_call POST "/v1/device/periderm/work/$id/uploads" "")"; then rm -f "$out"; err "periderm: could not start the upload for $id"; return 1; fi
  uid="$(jq -r '.uploadId // ""' <<<"$resp" 2>/dev/null)"
  if [[ ! "$uid" =~ ^[A-Za-z0-9_-]{1,64}$ || "$(jq -r '.key // ""' <<<"$resp" 2>/dev/null)" != "$key" ]]; then
    rm -f "$out"; err "periderm: the upload for $id was not opened for $key"; return 1
  fi
  parts=$(( (size + PD_PART_BYTES - 1) / PD_PART_BYTES ))
  for (( n = 1; n <= parts; n++ )); do
    dd if="$file" of="$out.part" bs="$PD_PART_BYTES" skip=$(( n - 1 )) count=1 status=none || { rm -f "$out" "$out.part"; return 1; }
    ok=0
    for i in 1 2 3; do
      if control_call_raw PUT "/v1/device/periderm/uploads/$uid/parts/$n" "$out.part" "$out" 1800; then ok=1; break; fi
      (( i < 3 )) && sleep "$PD_RETRY_SLEEP"
    done
    (( ok )) || { rm -f "$out" "$out.part"; err "periderm: part $n of $parts for $id failed"; return 1; }
  done
  rm -f "$out" "$out.part"
  if ! resp="$(control_call POST "/v1/device/periderm/uploads/$uid/complete" "")" || [[ "$(jq -r '.key // ""' <<<"$resp" 2>/dev/null)" != "$key" ]]; then
    err "periderm: the upload for $id did not complete"; return 1
  fi
  ok "periderm: uploaded $parts part(s) to $key"
}

# --- work items ---------------------------------------------------------------------------
# pd_work_check <item-json>: 0 when this node may act on the item; 1 when it
# never may (malformed, expired, digest or signature wrong); 2 when not now
# (its role is not enabled here, no pinned key yet). Every refusal is
# logged; nothing is posted for a refused item.
pd_work_check() {
  local item="$1" id kind attempt exp sha want role domain kid sig pinned msg now vrc=0
  id="$(jq -r '.id // ""' <<<"$item")"; kind="$(jq -r '.kind // ""' <<<"$item")"
  attempt="$(jq -r '.attempt // "" | tostring' <<<"$item")"; exp="$(jq -r '.expiresAt // "" | tostring' <<<"$item")"
  sha="$(jq -r '.bodySha256 // ""' <<<"$item")"; domain="$(jq -r '.signature.domain // ""' <<<"$item")"
  kid="$(jq -r '.signature.kid // ""' <<<"$item")"; sig="$(jq -r '.signature.value // ""' <<<"$item")"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { warn "periderm: refusing work with a bad id"; return 1; }
  [[ "$attempt" =~ ^[1-9][0-9]{0,3}$ && "$exp" =~ ^[0-9]{1,15}$ ]] || { warn "periderm: refusing work $id: bad attempt or expiry"; return 1; }
  role="$(pd_role_of_kind "$kind")" || { warn "periderm: refusing work $id: unknown kind '$kind'"; return 1; }
  if ! pd_role_enabled "$role"; then warn "periderm: refusing work $id ($kind): $role is not enabled on this node"; return 2; fi
  now="$(pd_now_ms)"
  if (( exp < now )); then warn "periderm: refusing work $id: expired"; return 1; fi
  want="$(jq -c '{id, kind, attempt, expiresAt, request}' <<<"$item" | pd_canon_sha)"
  if [[ "$sha" != "$want" ]]; then warn "periderm: refusing work $id: body digest does not match bodySha256"; return 1; fi
  if [[ "$domain" != "$(pd_domain_of_kind "$kind")" ]]; then warn "periderm: refusing work $id: signature domain '$domain' is not $kind's"; return 1; fi
  pinned="$(jq -r '.kid // ""' "$(control_pubkey_file)" 2>/dev/null)"
  [[ -n "$pinned" ]] || { warn "periderm: refusing work $id: no pinned control key yet"; return 2; }
  if [[ "$kid" != "$pinned" ]]; then warn "periderm: refusing work $id: key id '$kid' is not the pinned control key"; return 1; fi
  msg="$(mktemp)" || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s' "$domain" "$(control_device_id)" "$id" "$attempt" "$exp" "$want" > "$msg"
  control_verify_pinned "$msg" "$sig" || vrc=$?
  rm -f "$msg"
  (( vrc == 3 )) && { warn "periderm: refusing work $id: the pinned control key is unusable"; return 2; }
  if (( vrc != 0 )); then err "periderm: refusing work $id: SIGNATURE INVALID"; return 1; fi
  return 0
}

# pd_launch <stem> <max-seconds> <command...>: run detached, outside the
# apply. A transient systemd unit where systemd runs, else a session leader.
pd_launch() {
  local stem="$1" max="$2"; shift 2
  if have systemd-run; then
    local -a env=()
    local v; for v in AW_ROOT AW_ETC AW_STATE AW_CONFIG AW_LOG_DIR AW_SYSTEMD_DIR; do
      [[ -n "${!v:-}" ]] && env+=("--setenv=$v=${!v}")
    done
    run systemd-run "--unit=alwayswork-$stem" --collect --quiet "--property=RuntimeMaxSec=$max" \
      --property=KillMode=mixed "${env[@]}" "$@"
  else
    ( setsid "$@" </dev/null >>"$(pd_trust_dir)/jobs.log" 2>&1 & )
  fi
}

# pd_work_take <item-json> <periderm-block>: claim and start one work item.
pd_work_take() {
  local item="$1" pd="$2" id attempt wd max
  id="$(jq -r '.id // ""' <<<"$item")"; attempt="$(jq -r '.attempt // "" | tostring' <<<"$item")"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ && "$attempt" =~ ^[1-9][0-9]{0,3}$ ]] || { warn "periderm: refusing malformed work"; return 1; }
  wd="$(pd_work_dir "$id" "$attempt")"
  if [[ -d "$wd/claimed" ]]; then             # taken before: at most once per attempt
    # …unless its job ended without a result (it died, or failed on a path that
    # did not report): that is said once, and the control plane retries.
    if [[ ! -e "$wd/reported" && ! -e "$wd/orphaned" ]] && have systemctl \
       && ! systemctl is-active --quiet "alwayswork-pdjob-$id-$attempt.service" 2>/dev/null \
       && [[ "$(jq -r '.kind' <<<"$item")" == verify ]]; then
      touch "$wd/orphaned"
      pd_verify_fail "$id" "$attempt" "the job ended without a result" || true
    fi
    return 0
  fi
  [[ -e "$wd/refused" ]] && return 1          # refused for good before: not logged again
  local crc=0; pd_work_check "$item" || crc=$?
  if (( crc != 0 )); then
    (( crc == 1 )) && pd_mkdir_private "$wd" && touch "$wd/refused"
    return 1
  fi
  pd_mkdir_private "$wd" || return 1
  mkdir "$wd/claimed" 2>/dev/null || return 0
  ( umask 077; jq -c --argjson pd "$pd" '{item: ., proxyImage: ($pd.proxyImage // ""), verifierImage: ($pd.verifierImage // ""), egressAllow: ($pd.egressAllow // [])}' <<<"$item" > "$wd/work.json" )
  case "$(jq -r '.kind' <<<"$item")" in
    build) max=$(( PD_BUILD_TIMEOUT + 900 )) ;; verify) max=$(( PD_VERIFY_TIMEOUT + 900 )) ;; *) max=1800 ;;
  esac
  log "periderm: starting $(jq -r '.kind' <<<"$item") work $id (attempt $attempt)"
  if ! pd_launch "pdjob-$id-$attempt" "$max" "$AW_ROOT/bin/alwayswork" periderm job "$id" "$attempt"; then
    rm -rf "$wd/claimed"; err "periderm: could not start work $id"; return 1
  fi
}

# aw periderm job <id> <attempt>: what the transient unit runs.
pd_job_run() {
  local id="$1" attempt="$2" wd item kind rc=0
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ && "$attempt" =~ ^[1-9][0-9]{0,3}$ ]] || die "periderm: bad work reference"
  wd="$(pd_work_dir "$id" "$attempt")"
  [[ -f "$wd/work.json" ]] || die "periderm: no work $id.$attempt on this node"
  [[ -e "$wd/done" ]] && { info "periderm: work $id.$attempt already done"; return 0; }
  mkdir "$wd/running" 2>/dev/null || { warn "periderm: work $id.$attempt is already running"; return 0; }
  item="$(jq -c '.item' "$wd/work.json")"
  # The state file is checked like the delivery was: same signature, same expiry.
  pd_work_check "$item" || { touch "$wd/done"; return 1; }
  kind="$(jq -r '.kind' <<<"$item")"
  case "$kind" in
    build)  pd_build_run "$wd" || rc=$? ;;
    verify) pd_verify_run "$wd" || rc=$? ;;
    backup) pd_backup_run "$wd" || rc=$? ;;
  esac
  touch "$wd/done"
  return "$rc"
}

pd_work_req() { jq -r ".item.request$2 // \"\"" "$1/work.json"; }   # <workdir> <jq-path>

# --- build (periderm.builder) ---------------------------------------------------------------
pd_build_fail() { # <wd> <id> <attempt> <error>
  warn "periderm: build $2 failed: $4"
  pd_post_result "$2" "$3" "$(jq -nc --arg e "$4" '{ok:false, error:$e}')"
  return 1
}

pd_build_run() {
  local wd="$1" id attempt commit bkey bsha akey proxy allow start file f tag iid dur head proxy_url short
  id="$(jq -r '.item.id' "$wd/work.json")"; attempt="$(jq -r '.item.attempt' "$wd/work.json")"
  commit="$(pd_work_req "$wd" .commitId)"; bkey="$(pd_work_req "$wd" .bundleKey)"
  bsha="$(pd_work_req "$wd" .bundleSha256)"; akey="$(pd_work_req "$wd" .archiveKey)"
  proxy="$(jq -r '.proxyImage' "$wd/work.json")"
  allow="$(jq -r '[(.egressAllow // [])[] | strings | select(test("^(\\*\\.)?[A-Za-z0-9.-]{1,253}$"))] | join(",")' "$wd/work.json")"
  start="$(pd_now_ms)"
  [[ "$commit" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || { pd_build_fail "$wd" "$id" "$attempt" "bad commitId"; return 1; }
  [[ -n "$bkey" && -n "$akey" ]] || { pd_build_fail "$wd" "$id" "$attempt" "the request names no bundle or archive key"; return 1; }
  [[ "$bsha" =~ ^[0-9a-f]{64}$ ]] || bsha=""
  [[ "$proxy" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { pd_build_fail "$wd" "$id" "$attempt" "no usable proxyImage; builds go out through the proxy only"; return 1; }
  pd_blob_get "$bkey" "$wd/source.bundle" "$bsha" || { pd_build_fail "$wd" "$id" "$attempt" "could not download the source bundle"; return 1; }
  rm -rf "$wd/src"
  if ! git clone --quiet --no-checkout "$wd/source.bundle" "$wd/src" >"$wd/git.log" 2>&1 \
     || ! git -C "$wd/src" -c advice.detachedHead=false checkout --quiet --detach "$commit" >>"$wd/git.log" 2>&1; then
    pd_build_fail "$wd" "$id" "$attempt" "the bundle does not hold commit $commit"; return 1
  fi
  head="$(git -C "$wd/src" rev-parse HEAD 2>/dev/null)"
  [[ "$head" == "$commit" ]] || { pd_build_fail "$wd" "$id" "$attempt" "checked out $head, not $commit"; return 1; }
  file=""
  for f in Containerfile Dockerfile; do [[ -f "$wd/src/$f" && ! -L "$wd/src/$f" ]] && { file="$f"; break; }; done
  [[ -n "$file" ]] || { pd_build_fail "$wd" "$id" "$attempt" "the repository has no Containerfile or Dockerfile"; return 1; }
  # The build's only way out is the egress proxy on the internal network.
  # shellcheck disable=SC2034  # CAP_ID labels the proxy unit (engine_build_args)
  if ! { pd_ensure_networks && ( CAP_ID="$PD_ROLE_BUILDER"; pd_apply_proxy "$proxy" "$allow" ); } >>"$wd/git.log" 2>&1; then
    pd_build_fail "$wd" "$id" "$attempt" "the egress proxy is not running"; return 1
  fi
  short="$(pd_short "$id.$attempt")"; tag="localhost/periderm-build:$short"
  proxy_url="http://$(wl_container "$PD_PROXY"):$PD_PROXY_PORT"
  log "periderm: building $commit ($file) for $id"
  # Never --network=host (§7.3): the internal `periderm` network, the proxy
  # as HTTP(S)_PROXY, no capabilities beyond what package installs need,
  # bounded memory, CPU and time.
  local -a flags=(build --network "$PD_NET" --pull=missing --http-proxy=false
    --build-arg "HTTPS_PROXY=$proxy_url" --build-arg "HTTP_PROXY=$proxy_url"
    --build-arg "https_proxy=$proxy_url" --build-arg "http_proxy=$proxy_url"
    --build-arg "NO_PROXY=localhost,127.0.0.1" --build-arg "no_proxy=localhost,127.0.0.1"
    --cap-drop ALL --cap-add "CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,SETGID,SETUID"
    --security-opt no-new-privileges --memory 4096m --cpu-period 100000 --cpu-quota 200000
    --label "dev.alwayswork.periderm.work=$id" --label "dev.alwayswork.periderm.commit=$commit"
    -t "$tag" -f "$wd/src/$file" "$wd/src")
  if ! run timeout "$PD_BUILD_TIMEOUT" podman "${flags[@]}" >"$wd/build.log" 2>&1; then
    pd_build_fail "$wd" "$id" "$attempt" "podman build failed: $(tail -c 300 "$wd/build.log" | tr -d '\r')"; return 1
  fi
  iid="$(podman image inspect --format '{{.Id}}' "$tag" 2>/dev/null)"; iid="${iid#sha256:}"
  [[ "$iid" =~ ^[0-9a-f]{64}$ ]] || { pd_build_fail "$wd" "$id" "$attempt" "the built image has no id"; return 1; }
  rm -f "$wd/image.oci.tar"
  if ! run podman save --format oci-archive -o "$wd/image.oci.tar" "$tag" >/dev/null 2>>"$wd/build.log"; then
    pd_build_fail "$wd" "$id" "$attempt" "podman save failed"; return 1
  fi
  pd_blob_put "$id" "$wd/image.oci.tar" "$akey" || { pd_build_fail "$wd" "$id" "$attempt" "the image archive could not be uploaded"; return 1; }
  dur=$(( $(pd_now_ms) - start ))
  tail -c 4000 "$wd/build.log" > "$wd/build.tail"
  pd_post_result "$id" "$attempt" "$(jq -nc --arg i "sha256:$iid" --argjson d "$dur" --rawfile l "$wd/build.tail" '{ok:true, imageId:$i, durationMs:$d, logTail:$l}')"
  run podman rmi "$tag" >/dev/null 2>&1 || true
  rm -rf "$wd/src" "$wd/source.bundle" "$wd/image.oci.tar"
  ok "periderm: built sha256:${iid:0:12} for $id"
}

# --- verify (periderm.verifier) ---------------------------------------------------------------
pd_ensure_verify_network() {
  if ! podman network exists "$PD_VERIFY_NET" 2>/dev/null; then
    run podman network create --internal "$PD_VERIFY_NET" >/dev/null || { err "periderm: could not create network $PD_VERIFY_NET"; return 1; }
  fi
  if [[ "$(podman network inspect "$PD_VERIFY_NET" --format '{{.Internal}}' 2>/dev/null)" != "true" ]]; then
    err "periderm: network '$PD_VERIFY_NET' exists but is not --internal; refusing to verify on it"; return 1
  fi
  # The verifier reaches each candidate by its container name: name lookups go
  # to the network's DNS on the host, which a strict host firewall drops (live:
  # every candidate "did not answer /healthz" on periderm-verify-1). Only DNS is
  # opened; the network stays internal, with no route out.
  local sub
  if declare -F fw_active >/dev/null && fw_active && sub="$(pd_subnet "$PD_VERIFY_NET")"; then
    fw_allow_subnet_port periderm.verifier "$sub" 53 udp >/dev/null 2>&1 || true
    fw_allow_subnet_port periderm.verifier "$sub" 53 tcp >/dev/null 2>&1 || true
  fi
}

# pd_verify_fail <id> <attempt> <error>: the verifier could not run. Said to
# the control plane, which retries it, instead of a silence until the lease ends.
pd_verify_fail() {
  err "periderm: verify $1 could not run: $3"
  pd_post_result "$1" "$2" "$(jq -nc --arg e "$3" '{ok:false, error:$e}')"
  return 1
}

pd_verify_run() {
  local wd="$1" id attempt mode scratch img name req want sig sha
  id="$(jq -r '.item.id' "$wd/work.json")"; attempt="$(jq -r '.item.attempt' "$wd/work.json")"
  req="$(jq -c '.item.request' "$wd/work.json")"; mode="$(jq -r '.mode // "candidate"' <<<"$req")"
  img="$(jq -r '.verifierImage' "$wd/work.json")"
  [[ "$img" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { pd_verify_fail "$id" "$attempt" "no usable verifierImage"; return 1; }
  scratch="$(pd_verify_dir "$id")"
  rm -rf "$scratch"; mkdir -p "$scratch" || { pd_verify_fail "$id" "$attempt" "could not make its scratch directory"; return 1; }
  # Traversable, not listable: the candidates the verifier starts (userns=auto)
  # read the files it bind-mounts from here.
  chmod 711 "$(dirname "$scratch")" "$scratch"
  local -a gets=()
  case "$mode" in
    candidate)
      gets+=("$(jq -r '.candidate.archiveKey // ""' <<<"$req")|candidate.tar|$(jq -r '.candidate.archiveSha256 // ""' <<<"$req")")
      [[ "$(jq -r '.revertTo.archiveKey // ""' <<<"$req")" != "" ]] \
        && gets+=("$(jq -r '.revertTo.archiveKey' <<<"$req")|revert.tar|$(jq -r '.revertTo.archiveSha256 // ""' <<<"$req")")
      gets+=("$(jq -r '.bundleKey // ""' <<<"$req")|source.bundle|")
      # The latest verified production backup, for the migration preview.
      [[ "$(jq -r '.backup.blobKey // ""' <<<"$req")" != "" ]] \
        && gets+=("$(jq -r '.backup.blobKey' <<<"$req")|backup.tar|$(jq -r '.backup.sha256 // ""' <<<"$req")") ;;
    backup)
      gets+=("$(jq -r '.release.archiveKey // ""' <<<"$req")|release.tar|$(jq -r '.release.archiveSha256 // ""' <<<"$req")")
      gets+=("$(jq -r '.blobKey // ""' <<<"$req")|backup.tar|$(jq -r '.sha256 // ""' <<<"$req")") ;;
    *) pd_verify_fail "$id" "$attempt" "unknown mode '$mode'"; return 1 ;;
  esac
  local g key file dig
  for g in "${gets[@]}"; do
    IFS='|' read -r key file dig <<<"$g"
    [[ -n "$key" ]] || { pd_verify_fail "$id" "$attempt" "the request does not name $file"; return 1; }
    [[ "$dig" =~ ^[0-9a-f]{64}$ ]] || dig=""
    pd_blob_get "$key" "$scratch/$file" "$dig" || { pd_verify_fail "$id" "$attempt" "could not fetch $file"; return 1; }
    chmod 644 "$scratch/$file"
  done
  ( umask 077; jq -c --arg w "$id" --argjson a "$attempt" '. + {workId:$w, attempt:$a}' <<<"$req" > "$scratch/request.json" )
  pd_ensure_verify_network || { pd_verify_fail "$id" "$attempt" "could not create the verify network"; return 1; }
  ( WL_PULL="" WL_BUILD="" wl_ensure_image "$img" ) >/dev/null || { pd_verify_fail "$id" "$attempt" "could not pull the verifier image"; return 1; }
  name="periderm-verifier-$(pd_short "$id.$attempt")"
  log "periderm: verifying $id ($mode) in $name"
  # The verifier drives candidates through the host podman socket: it is the
  # one privileged Periderm container, which is why this role runs alone.
  local -a flags=(run --rm --replace --name "$name" --network "$PD_VERIFY_NET" --security-opt label=disable
    -v "$PD_PODMAN_SOCK:$PD_PODMAN_SOCK" -v "$scratch:$scratch"
    -e "CONTAINER_HOST=unix://$PD_PODMAN_SOCK" -e "PERIDERM_VERIFY_NETWORK=$PD_VERIFY_NET"
    -e "PERIDERM_VERIFIER_HOST=$name" -e "PERIDERM_VERIFIER_IMAGE=$img"
    --label "dev.alwayswork.periderm.work=$id" "$img" "$scratch/request.json")
  if ! run timeout "$PD_VERIFY_TIMEOUT" podman "${flags[@]}" >"$wd/verify.log" 2>&1; then
    run podman rm -f "$name" >/dev/null 2>&1 || true
    pd_verify_fail "$id" "$attempt" "the verifier failed: $(tail -c 300 "$wd/verify.log" | tr -cd '[:print:]\n')"; return 1
  fi
  if ! jq -e 'type == "object"' "$scratch/receipt.json" >/dev/null 2>&1 || [[ ! -s "$scratch/receipt.sign" ]]; then
    pd_verify_fail "$id" "$attempt" "verifier wrote no receipt"; return 1
  fi
  # The node signs only a receipt statement for this work, over this receipt:
  # never arbitrary bytes the container wrote.
  sha="$(pd_canon_sha < "$scratch/receipt.json")"
  want="$(printf 'AW-VERIFY-RECEIPT-V1\n%s\n%s\n%s' "$id" "$attempt" "$sha")"
  if [[ "$(cat "$scratch/receipt.sign")" != "$want" || "$(wc -c < "$scratch/receipt.sign")" != "${#want}" ]]; then
    pd_verify_fail "$id" "$attempt" "receipt.sign for $id is not the receipt statement for this work; refusing to sign"; return 1
  fi
  sig="$(control_sign_file "$scratch/receipt.sign")" || { pd_verify_fail "$id" "$attempt" "could not sign the receipt"; return 1; }
  pd_post_result "$id" "$attempt" "$(jq -nc --slurpfile r "$scratch/receipt.json" --arg s "$sig" '{receipt:$r[0], signature:$s}')"
  rm -f "$scratch"/*.tar "$scratch/source.bundle"
  ok "periderm: receipt for $id signed and sent"
}

# --- production apps (periderm.runtime) -------------------------------------------------------
# pd_act_valid <activation-json>: prints the app hex when the block is usable.
pd_act_valid() {
  local a="$1" id surface
  id="$(jq -r '.activationId // ""' <<<"$a")"; surface="$(jq -r '.appSurface // ""' <<<"$a")"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { warn "periderm: ignoring an activation with a bad id"; return 1; }
  [[ "$surface" =~ ^pa-([0-9a-f]{12})$ ]] || { warn "periderm: activation $id: bad appSurface '$surface'"; return 1; }
  jq -e '
    (.appId | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))
    and (.appPort | type == "number" and . >= 1 and . <= 65535 and floor == .)
    and (.target.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$"))
    and (.target.archiveKey | type == "string" and length > 0)
    and (.revertTo == null or ((.revertTo.imageId | type == "string" and test("^sha256:[0-9a-f]{64}$")) and (.revertTo.archiveKey | type == "string")))
    and ((.probe.path // "/healthz") | test("^/[A-Za-z0-9._~/?=&%-]{0,200}$"))
    and ((.probe.expect // 200) | type == "number" and . >= 100 and . <= 599)
    and ((.probe.intervalMs // 2000) | type == "number" and . >= 10 and . <= 60000)
    and ((.readyWithinMs // 60000) | type == "number" and . >= 100 and . <= 3600000)
    and ((.revertWindowMs // 600000) | type == "number" and . >= 0 and . <= 86400000)
    and ((.env // {}) | type == "object" and all(to_entries[]; (.key | test("^[A-Z_][A-Z0-9_]{0,63}$")) and (.value | type == "string" and (test("[\r\n]") | not) and length <= 4096)))
  ' >/dev/null 2>&1 <<<"$a" || { warn "periderm: activation $id is malformed; ignoring it"; return 1; }
  printf '%s' "${BASH_REMATCH[1]}"
}

pd_act_phase() { cat "$(pd_act_dir "$1")/phase" 2>/dev/null || true; }
pd_act_set_phase() { printf '%s\n' "$2" > "$(pd_act_dir "$1")/phase"; }
pd_phase_terminal() { [[ "$1" == "done" || "$1" == reverted || "$1" == failed ]]; }
# A watchdog (or reconcile job) holds its activation's lock while it runs.
pd_act_alive() {
  local l; l="$(pd_act_dir "$1")/.lock"
  [[ -f "$l" ]] && have flock || return 1
  ! flock -n "$l" true 2>/dev/null
}

# Some watchdog or reconcile job of this app is running.
pd_app_hex_alive() {
  local f
  for f in "$(pd_trust_dir)"/activations/*/hex; do
    [[ -f "$f" && "$(cat "$f")" == "$1" ]] || continue
    pd_act_alive "$(basename "$(dirname "$f")")" && return 0
  done
  return 1
}

# The listener's loopback port: deterministic, recorded once so it never moves.
pd_app_hport() {
  local hex="$1" f p
  f="$(pd_app_dir "$hex")/port"
  p="$(cat "$f" 2>/dev/null || true)"
  if [[ ! "$p" =~ ^[0-9]{4,5}$ ]]; then
    p=$(( PD_APP_BASE + (16#${hex:0:4} % PD_APP_SPAN) ))
    local used; used=" $(cat "$(pd_trust_dir)"/apps/*/port 2>/dev/null | tr '\n' ' ') "
    while [[ "$used" == *" $p "* ]]; do p=$(( PD_APP_BASE + ((p - PD_APP_BASE + 1) % PD_APP_SPAN) )); done
    mkdir -p "$(dirname "$f")"; printf '%s\n' "$p" > "$f"
  fi
  printf '%s' "$p"
}

# pd_app_image_ready <activation-json> <target|revertTo>: the release's image
# is in local storage with exactly the id the activation names. A missing one
# is downloaded and loaded; one whose loaded id differs is removed and refused.
pd_app_image_ready() {
  local a="$1" which="$2" want key dig tar out ref got
  want="$(jq -r ".$which.imageId" <<<"$a")"; want="${want#sha256:}"
  podman image exists "$want" 2>/dev/null && return 0
  key="$(jq -r ".$which.archiveKey" <<<"$a")"; dig="$(jq -r ".$which.archiveSha256 // \"\"" <<<"$a")"
  [[ "$dig" =~ ^[0-9a-f]{64}$ ]] || dig=""
  pd_mkdir_private "$(pd_trust_dir)/images" || return 1
  tar="$(pd_trust_dir)/images/$want.tar"
  pd_blob_get "$key" "$tar" "$dig" || return 1
  out="$(podman load -i "$tar" 2>&1)" || { rm -f "$tar"; err "periderm: podman load failed: ${out: -200}"; return 1; }
  rm -f "$tar"
  ref="$(sed -n 's/^Loaded image[^:]*: *//p' <<<"$out" | tail -n1 | awk '{print $1}')"
  got="$(podman image inspect --format '{{.Id}}' "$ref" 2>/dev/null)"; got="${got#sha256:}"
  if [[ "$got" != "$want" ]]; then
    err "periderm: the archive for sha256:${want:0:12} loaded image ${got:-<none>}; refusing it"
    [[ "$got" =~ ^[0-9a-f]{64}$ ]] && run podman rmi -f "$got" >/dev/null 2>&1
    return 1
  fi
  ok "periderm: loaded sha256:${want:0:12}"
}

# pd_app_instance <activation-json> <target|revertTo>: the release's instance
# on the workload network, hardened like every workload, its data volume at /data.
# shellcheck disable=SC2034
pd_app_instance() {
  local a="$1" which="$2" hex img app port envf name
  hex="$(jq -r '.appSurface | ltrimstr("pa-")' <<<"$a")"; img="$(jq -r ".$which.imageId | ltrimstr(\"sha256:\")" <<<"$a")"
  app="$(jq -r '.appId' <<<"$a")"; port="$(jq -r '.appPort' <<<"$a")"
  name="$(pd_app_inst "$hex" "$img")"; envf="$(pd_app_envfile "$hex-${img:0:12}")"
  ensure_dir "$(pd_env_dir)"; chmod 700 "$(pd_env_dir)" 2>/dev/null || true
  ( umask 077
    jq -r --argjson p "$port" '(.env // {}) + {PORT: ($p | tostring), DATA_DIR: "/data"} | to_entries[] | "\(.key)=\(.value)"' <<<"$a" > "$envf.tmp" ) || return 1
  mv -f "$envf.tmp" "$envf"; chmod 600 "$envf"
  pd_wl_reset "$name" "$img" "Periderm app $app release ${img:0:12}"
  WL_NETWORK=""
  WL_VOLUMES=("$(pd_app_volume "$hex"):/data:U")
  WL_ENV_FILE="$envf"
  WL_LABELS+=("dev.alwayswork.periderm.app=$app" "dev.alwayswork.periderm.release=sha256:$img")
  mkdir -p "$(pd_app_dir "$hex")"; printf '%s\n' "$app" > "$(pd_app_dir "$hex")/app"
  CAP_ID="$PD_ROLE_RUNTIME" wl_apply_unit
}

# pd_app_listener <activation-json> <proxy-image>: the per-app forwarder that
# reads its target from a file (FORWARD_TO_FILE), so traffic moves between
# releases by rewriting one line — no restart, no Cloudflare call (§9.4).
# shellcheck disable=SC2034
pd_app_listener() {
  local a="$1" proxy="$2" hex app hport
  hex="$(jq -r '.appSurface | ltrimstr("pa-")' <<<"$a")"; app="$(jq -r '.appId' <<<"$a")"
  [[ "$proxy" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { err "periderm: no usable proxyImage for the app listener"; return 1; }
  mkdir -p "$(pd_app_dir "$hex")"; chmod 755 "$(pd_app_dir "$hex")"
  [[ -f "$(pd_app_dir "$hex")/target" ]] || { : > "$(pd_app_dir "$hex")/target"; chmod 644 "$(pd_app_dir "$hex")/target"; }
  hport="$(pd_app_hport "$hex")"
  pd_wl_reset "$(pd_app_lb "$hex")" "$proxy" "Periderm app listener $app"
  WL_NETWORK=""
  WL_PUBLISH=("$hport:$PD_FWD_PORT")
  WL_VOLUMES=("$(pd_app_dir "$hex"):/run/periderm:ro")
  WL_EXTRA+=(--env "FORWARD_TO_FILE=/run/periderm/target" --env "PROXY_PORT=$PD_FWD_PORT" --cpus 0.5 --memory 128m --pids-limit 128)
  WL_PULL="" WL_BUILD="" wl_ensure_image "$proxy" >/dev/null || return 1
  CAP_ID="$PD_ROLE_RUNTIME" wl_apply_unit || return 1
  wl_report_surface "$(pd_app_lb "$hex")" "pa-$hex" http "$hport" "" "Periderm app $app"
}

# pd_app_point <hex> <instance-name> <port>: traffic to that instance (atomic).
pd_app_point() {
  local f; f="$(pd_app_dir "$1")/target"
  printf '%s:%s\n' "$(wl_container "$2")" "$3" > "$f.tmp" && chmod 644 "$f.tmp" && mv -f "$f.tmp" "$f"
}
pd_app_pointed() { cat "$(pd_app_dir "$1")/target" 2>/dev/null || true; }

pd_app_stop() { # <hex> <img-hex>
  local name; name="$(pd_app_inst "$1" "$2")"
  pd_remove_unit "$name" || return 1
  rm -f "$(pd_app_envfile "$1-${2:0:12}")"
}

# pd_probe <instance-name> <port> <path> <expect>: one HTTP probe from the
# host to the instance's address on the workload network. PD_PROBE_LAST says
# what it saw.
PD_PROBE_LAST=""
pd_probe() {
  local c ip code
  c="$(wl_container "$1")"
  ip="$(podman inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c" 2>/dev/null | awk '{print $1}')"
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then PD_PROBE_LAST="GET $3 -> no address"; return 1; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' --resolve "$c:$2:$ip" "http://$c:$2$3" 2>/dev/null || true)"
  PD_PROBE_LAST="GET $3 -> ${code:-000}"
  [[ "$code" == "$4" ]]
}

# aw periderm watchdog <activationId>: start the target next to the current
# release, probe, switch, and revert locally — the control plane need not be
# reachable for any of it (§9.4). Reports go through the outbox.
pd_watchdog_run() {
  local id="$1" ad a proxy hex port timg rimg tname rname path expect every ready window phase deadline fails now
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "periderm: bad activation id"
  ad="$(pd_act_dir "$id")"; [[ -f "$ad/activation.json" ]] || die "periderm: no activation $id here"
  if have flock; then exec 8>"$ad/.lock"; flock -n 8 || { info "periderm: watchdog $id already running"; return 0; }; fi
  phase="$(pd_act_phase "$id")"
  pd_phase_terminal "$phase" && return 0
  a="$(jq -c '.activation' "$ad/activation.json")"; proxy="$(jq -r '.proxyImage' "$ad/activation.json")"
  hex="$(jq -r '.appSurface | ltrimstr("pa-")' <<<"$a")"; port="$(jq -r '.appPort' <<<"$a")"
  timg="$(jq -r '.target.imageId | ltrimstr("sha256:")' <<<"$a")"; rimg="$(jq -r '.revertTo.imageId // "" | ltrimstr("sha256:")' <<<"$a")"
  path="$(jq -r '.probe.path // "/healthz"' <<<"$a")"; expect="$(jq -r '.probe.expect // 200' <<<"$a")"
  every="$(jq -r '.probe.intervalMs // 2000' <<<"$a")"; ready="$(jq -r '.readyWithinMs // 60000' <<<"$a")"
  window="$(jq -r '.revertWindowMs // 600000' <<<"$a")"
  tname="$(pd_app_inst "$hex" "$timg")"; rname=""; [[ -n "$rimg" ]] && rname="$(pd_app_inst "$hex" "$rimg")"

  if [[ -z "$phase" ]]; then pd_act_report "$id" staging; pd_act_set_phase "$id" staging; fi
  if [[ "$phase" != active ]]; then
    ( pd_app_listener "$a" "$proxy" ) || warn "periderm: activation $id: the listener did not start"
    if [[ -n "$rimg" ]] && ! podman container exists "$(wl_container "$rname")" 2>/dev/null; then
      # Something to go back to before anything moves.
      ( pd_app_image_ready "$a" revertTo && pd_app_instance "$a" revertTo ) || warn "periderm: activation $id: the revert release is not running"
    fi
    if ! pd_app_image_ready "$a" target; then
      pd_act_set_phase "$id" failed
      pd_act_report "$id" failed '{"image":"the target image could not be loaded with the expected id"}'
      return 1
    fi
    ( pd_app_instance "$a" target ) || { pd_act_set_phase "$id" failed; pd_act_report "$id" failed '{"start":"the target instance did not start"}'; return 1; }
    deadline=$(( $(pd_now_ms) + ready ))
    until pd_probe "$tname" "$port" "$path" "$expect"; do
      if (( $(pd_now_ms) >= deadline )); then
        [[ "$timg" != "$rimg" ]] && pd_app_stop "$hex" "$timg"
        pd_act_set_phase "$id" failed
        pd_act_report "$id" failed "$(jq -nc --arg p "$PD_PROBE_LAST" --argjson w "$ready" '{probe:$p, readyWithinMs:$w}')"
        warn "periderm: activation $id: target not ready within ${ready}ms; traffic left alone"
        return 1
      fi
      pd_sleep_ms "$every"
    done
    pd_app_point "$hex" "$tname" "$port"
    pd_act_set_phase "$id" active
    pd_act_report "$id" active
    ok "periderm: activation $id: traffic on sha256:${timg:0:12}"
  fi

  deadline=$(( $(pd_now_ms) + window )); fails=0
  while now="$(pd_now_ms)"; (( now < deadline )); do
    pd_sleep_ms "$every"
    if pd_probe "$tname" "$port" "$path" "$expect"; then fails=0; else fails=$(( fails + 1 )); fi
    if (( fails >= PD_REVERT_FAILS )); then
      local detail; detail="$(jq -nc --arg p "$PD_PROBE_LAST ($fails consecutive)" '{probe:$p}')"
      if [[ -n "$rname" && "$rname" != "$tname" ]]; then
        pd_app_point "$hex" "$rname" "$port"
        pd_app_stop "$hex" "$timg"
        pd_act_set_phase "$id" reverted
        pd_act_report "$id" reverted "$detail"
        warn "periderm: activation $id: reverted to sha256:${rimg:0:12} ($PD_PROBE_LAST)"
      else
        # A first release has nothing to switch back to.
        : > "$(pd_app_dir "$hex")/target"
        pd_app_stop "$hex" "$timg"
        pd_act_set_phase "$id" failed
        pd_act_report "$id" failed "$detail"
        warn "periderm: activation $id: failed in its window and stopped ($PD_PROBE_LAST)"
      fi
      return 1
    fi
    ( pd_outbox_flush ) >/dev/null 2>&1 || true
  done
  # Past the window: the previous release is no longer kept.
  [[ -n "$rimg" && "$rimg" != "$timg" ]] && pd_app_stop "$hex" "$rimg"
  pd_act_set_phase "$id" "done"
  ok "periderm: activation $id: window passed; previous release stopped"
}

# pd_app_reconcile_active <activation-json> <proxy>: an active release (e.g.
# after a reboot): its instance and listener run, traffic points at it, and
# no other release of the app runs. 2 when the image must be loaded first.
pd_app_reconcile_active() {
  local a="$1" proxy="$2" hex timg port tname f n
  hex="$(jq -r '.appSurface | ltrimstr("pa-")' <<<"$a")"; port="$(jq -r '.appPort' <<<"$a")"
  timg="$(jq -r '.target.imageId | ltrimstr("sha256:")' <<<"$a")"; tname="$(pd_app_inst "$hex" "$timg")"
  podman image exists "$timg" 2>/dev/null || return 2
  ( pd_app_listener "$a" "$proxy" ) || return 1
  ( pd_app_instance "$a" target ) || return 1
  [[ "$(pd_app_pointed "$hex")" == "$(wl_container "$tname"):$port" ]] || pd_app_point "$hex" "$tname" "$port"
  for f in "$WL_UNIT_DIR"/alwayswork-pdapp-"$hex"-*.service; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .service)"; n="${n#alwayswork-}"
    [[ "$n" == "$(pd_app_lb "$hex")" || "$n" == "$tname" ]] && continue
    [[ "$n" =~ ^pdapp-[0-9a-f]{12}-([0-9a-f]{12})$ ]] && { pd_remove_unit "$n"; rm -f "$(pd_app_envfile "$hex-${BASH_REMATCH[1]}")"; }
  done
  return 0
}

# aw periderm reconcile <activationId>: the same, with the image loaded first.
pd_reconcile_run() {
  local id="$1" ad a
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "periderm: bad activation id"
  ad="$(pd_act_dir "$id")"; [[ -f "$ad/activation.json" ]] || die "periderm: no activation $id here"
  if have flock; then exec 8>"$ad/.lock"; flock -n 8 || return 0; fi
  a="$(jq -c '.activation' "$ad/activation.json")"
  pd_app_image_ready "$a" target || return 1
  pd_app_reconcile_active "$a" "$(jq -r '.proxyImage' "$ad/activation.json")"
}

# Every app hex this node holds units or state for.
pd_apps_present() {
  local f
  {
    for f in "$WL_UNIT_DIR"/alwayswork-pdapp-*.service; do [[ -e "$f" ]] && basename "$f"; done
    for f in "$(pd_trust_dir)"/apps/*; do [[ -d "$f" ]] && printf 'alwayswork-pdapp-%s-lb\n' "$(basename "$f")"; done
  } | sed -n 's/^alwayswork-pdapp-\([0-9a-f]\{12\}\)-.*/\1/p' | sort -u
}

# An app no longer delivered here: listener, instances, surface and state go.
# Its data volume stays (it is the app's data) unless AW_PURGE=1.
pd_app_remove() {
  local hex="$1" f n rc=0
  log "periderm: removing production app $hex"
  for f in "$WL_UNIT_DIR"/alwayswork-pdapp-"$hex"-*.service; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .service)"; pd_remove_unit "${n#alwayswork-}" || rc=1
  done
  rm -f "$(pd_env_dir)"/pdapp-"$hex"-*.env
  wl_unreport_service "pa-$hex"
  rm -rf "$(pd_app_dir "$hex")"
  if [[ "${AW_PURGE:-0}" == "1" ]] && have podman && podman volume exists "$(pd_app_volume "$hex")" 2>/dev/null; then
    run podman volume rm -f "$(pd_app_volume "$hex")" >/dev/null || rc=1
  fi
  return "$rc"
}

pd_app_remove_all() {
  local hex rc=0
  while IFS= read -r hex; do [[ -n "$hex" ]] && { pd_app_remove "$hex" || rc=1; }; done < <(pd_apps_present)
  return "$rc"
}

# periderm_runtime_apply <periderm-block> <full|current>
periderm_runtime_apply() {
  local pd="$1" mode="$2" proxy n i a id hex state ad phase rc=0
  local -a hexes=() busy=()
  proxy="$(jq -r '.proxyImage // ""' <<<"$pd")"
  n="$(jq -r '(.activations // []) | if type == "array" then length else 0 end' <<<"$pd")"
  # Releases being rolled out: one watchdog each, started once.
  for (( i = 0; i < n; i++ )); do
    a="$(jq -c ".activations[$i]" <<<"$pd")"
    hex="$(pd_act_valid "$a")" || { rc=1; continue; }
    id="$(jq -r '.activationId' <<<"$a")"; state="$(jq -r '.state // ""' <<<"$a")"
    hexes+=("$hex")
    case "$state" in approved|staging|probing) ;; *) continue ;; esac
    ad="$(pd_act_dir "$id")"; phase="$(pd_act_phase "$id")"
    if [[ -d "$ad/claimed" ]]; then
      pd_phase_terminal "$phase" && continue
      busy+=("$hex")
      pd_act_alive "$id" && continue
      log "periderm: resuming the watchdog of activation $id (phase ${phase:-new})"
    else
      pd_mkdir_private "$ad" || { rc=1; continue; }
      mkdir "$ad/claimed" 2>/dev/null || continue
      busy+=("$hex")
      log "periderm: activation $id approved; starting its watchdog"
    fi
    ( umask 077; jq -nc --argjson a "$a" --arg p "$proxy" '{activation:$a, proxyImage:$p}' > "$ad/activation.json" )
    printf '%s\n' "$hex" > "$ad/hex"
    local max; max=$(( ($(jq -r '(.readyWithinMs // 60000) + (.revertWindowMs // 600000)' <<<"$a")) / 1000 + 1800 ))
    pd_launch "pdwd-$id" "$max" "$AW_ROOT/bin/alwayswork" periderm watchdog "$id" || { rc=1; rm -rf "$ad/claimed"; }
  done
  # Active releases. A rollout cut off mid-window (a reboot) resumes; a
  # release this node reverted or failed is never brought back; otherwise the
  # newest active release converges (full deliveries only — enabled units
  # come back by themselves after a reboot).
  local -a seen=()
  for (( i = n - 1; i >= 0; i-- )); do
    a="$(jq -c ".activations[$i]" <<<"$pd")"
    [[ "$(jq -r '.state // ""' <<<"$a")" == active ]] || continue
    hex="$(pd_act_valid "$a" 2>/dev/null)" || continue
    id="$(jq -r '.activationId' <<<"$a")"; phase="$(pd_act_phase "$id")"; ad="$(pd_act_dir "$id")"
    [[ "$phase" == reverted || "$phase" == failed ]] && continue
    [[ " ${busy[*]:-} ${seen[*]:-} " == *" $hex "* ]] && continue
    seen+=("$hex")
    if [[ -d "$ad/claimed" ]] && ! pd_phase_terminal "$phase"; then
      if ! pd_act_alive "$id"; then
        log "periderm: resuming the watchdog of activation $id (phase ${phase:-new})"
        pd_launch "pdwd-$id" "$(( ($(jq -r '(.readyWithinMs // 60000) + (.revertWindowMs // 600000)' <<<"$a")) / 1000 + 1800 ))" \
          "$AW_ROOT/bin/alwayswork" periderm watchdog "$id" || rc=1
      fi
      continue
    fi
    [[ "$mode" == full ]] || continue
    pd_app_hex_alive "$hex" && continue
    pd_mkdir_private "$ad" || { rc=1; continue; }
    ( umask 077; jq -nc --argjson a "$a" --arg p "$proxy" '{activation:$a, proxyImage:$p}' > "$ad/activation.json" )
    printf '%s\n' "$hex" > "$ad/hex"
    local r=0; ( pd_app_reconcile_active "$a" "$proxy" ) || r=$?
    if (( r == 2 )); then
      pd_act_alive "$id" || pd_launch "pdrc-$id" 3600 "$AW_ROOT/bin/alwayswork" periderm reconcile "$id" || rc=1
    elif (( r != 0 )); then
      err "periderm: active release of $(jq -r '.appId' <<<"$a") did not converge"; rc=1
    fi
  done
  [[ "$mode" == full ]] || return "$rc"

  # Present but no longer delivered.
  local have_hex
  while IFS= read -r have_hex; do
    [[ -n "$have_hex" && " ${hexes[*]:-} " != *" $have_hex "* ]] || continue
    pd_app_remove "$have_hex" || rc=1
  done < <(pd_apps_present)
  return "$rc"
}

# --- backup (periderm.runtime) ----------------------------------------------------------------
# The app's hex: the appSurface of the app's activation on this node (its
# apps/<hex>/app file), else the control plane's mapping sha256(appId)[0:12].
pd_app_hex_for() {
  local app="$1" f
  for f in "$(pd_trust_dir)"/apps/*/app; do
    [[ -f "$f" && "$(cat "$f")" == "$app" ]] && { basename "$(dirname "$f")"; return 0; }
  done
  pd_app_hex_of "$app"
}

pd_backup_fail() { # <id> <attempt> <error>
  warn "periderm: backup $1 failed: $3"
  pd_post_result "$1" "$2" "$(jq -nc --arg e "$3" '{ok:false, error:$e}')"
  return 1
}

pd_backup_run() {
  local wd="$1" id attempt app key hex vol
  id="$(jq -r '.item.id' "$wd/work.json")"; attempt="$(jq -r '.item.attempt' "$wd/work.json")"
  app="$(pd_work_req "$wd" .appId)"; key="$(pd_work_req "$wd" .blobKey)"
  [[ "$app" =~ ^[A-Za-z0-9_-]{1,64}$ && -n "$key" ]] || { pd_backup_fail "$id" "$attempt" "the request names no app or blob key"; return 1; }
  hex="$(pd_app_hex_for "$app")"; vol="$(pd_app_volume "$hex")"
  podman volume exists "$vol" 2>/dev/null || { pd_backup_fail "$id" "$attempt" "no data volume $vol on this node"; return 1; }
  rm -f "$wd/backup.tar"
  run podman volume export "$vol" --output "$wd/backup.tar" >/dev/null 2>"$wd/backup.log" || { pd_backup_fail "$id" "$attempt" "podman volume export failed"; return 1; }
  chmod 600 "$wd/backup.tar"
  pd_blob_put "$id" "$wd/backup.tar" "$key" || { pd_backup_fail "$id" "$attempt" "the backup could not be uploaded"; return 1; }
  pd_post_result "$id" "$attempt" '{"ok":true}'
  rm -f "$wd/backup.tar"
  ok "periderm: backup of $app uploaded to $key"
}

# --- reconcile ------------------------------------------------------------------------------
# Finished work and activation records past their use; verify scratch space.
pd_trust_gc() {
  local d; d="$(pd_trust_dir)"
  [[ -d "$d" ]] || return 0
  find "$d/work" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true
  find "$d/verify" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null || true
}

# periderm_trust_apply <delivery-json> [full|current]: take the signed work
# addressed to this node and converge its production apps. `current` is a
# delivery already applied (same sequence): only new work and new rollouts.
periderm_trust_apply() {
  local json="$1" mode="${2:-full}" pd n i rc=0
  pd="$(jq -c '.periderm // null | if type == "object" then . else {} end' <<<"$json" 2>/dev/null)" || pd='{}'
  if [[ -z "$(pd_trust_roles)" ]]; then
    if jq -e '((.work // []) | length) + ((.activations // []) | length) > 0' >/dev/null 2>&1 <<<"$pd"; then
      warn "periderm: desired state carries work or activations but no Periderm trust role is enabled here; ignoring them"
    fi
    if [[ "$mode" == full && -n "$(pd_apps_present)" ]]; then pd_app_remove_all || return 1; fi
    return 0
  fi
  if pd_verifier_conflict; then
    err "periderm: $PD_ROLE_VERIFIER shares this node with another Periderm role; refusing all Periderm work (the verifier holds the podman socket)"
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "periderm: dry-run — would take $(jq -r '(.work // []) | length' <<<"$pd") work item(s) and $(jq -r '(.activations // []) | length' <<<"$pd") activation(s)"
    return 0
  fi
  pd_mkdir_private "$(pd_trust_dir)" || return 1
  ( pd_outbox_flush ) || true
  n="$(jq -r '(.work // []) | if type == "array" then length else 0 end' <<<"$pd")"
  for (( i = 0; i < n; i++ )); do
    pd_work_take "$(jq -c ".work[$i]" <<<"$pd")" "$pd" || rc=1
  done
  if pd_role_enabled "$PD_ROLE_RUNTIME"; then
    periderm_runtime_apply "$pd" "$mode" || rc=1
  else
    if jq -e '(.activations // []) | length > 0' >/dev/null 2>&1 <<<"$pd"; then
      warn "periderm: desired state carries activations but $PD_ROLE_RUNTIME is not enabled here; ignoring them"
    fi
    if [[ "$mode" == full && -n "$(pd_apps_present)" ]]; then pd_app_remove_all || rc=1; fi
  fi
  pd_trust_gc
  return "$rc"
}

# periderm_trust_tick: every agent tick — send what was queued.
periderm_trust_tick() {
  [[ -d "$(pd_outbox_dir)" ]] || return 0
  pd_outbox_flush || warn "periderm: reports still queued; retrying next tick"
}
