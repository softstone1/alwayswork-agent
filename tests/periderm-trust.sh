#!/usr/bin/env bash
# periderm.builder / periderm.verifier / periderm.runtime: signed work from
# desired state -> checked, run detached at most once, results through the
# outbox; activations -> listener, instances, watchdog switch and revert.
# Host-free: podman, systemctl, systemd-run and curl are stubs (the control
# plane is a curl stub serving blobs and logging every request); openssl,
# git and jq are real, so signatures and bundles are real.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
command -v openssl >/dev/null && openssl genpkey -algorithm ED25519 -out "$TMP/probe.key" 2>/dev/null \
  || { echo "  skip  periderm-trust: openssl with Ed25519 missing"; echo "periderm.trust: passed 0 failed 0"; exit 0; }

# --- stubs ------------------------------------------------------------------
S="$TMP/stubs"; mkdir -p "$S"
export CALLS="$TMP/calls" PS="$TMP/podman" ACTIVE="$TMP/active" BLOBS="$TMP/blobs" REQS="$TMP/reqs" \
       OFFLINE="$TMP/offline" PROBES="$TMP/probes" SCRATCH_LS="$TMP/scratch-ls"
mkdir -p "$PS" "$ACTIVE" "$BLOBS" "$PROBES"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$S/$1"; chmod +x "$S/$1"; }
stub podman '
hex64() { [[ "$1" =~ ^(sha256:)?[0-9a-f]{64}$ ]]; }
case "$1 $2" in
  "network exists")  [[ -f "$PS/net-$3" ]] ;;
  "network create")  if [[ "$3" == --internal ]]; then echo true > "$PS/net-$4"; else echo false > "$PS/net-$3"; fi ;;
  "network inspect") [[ -f "$PS/net-$3" ]] || exit 125
                     case "$5" in *Internal*) cat "$PS/net-$3" ;; *Subnet*) echo 10.90.0.0/24 ;; esac ;;
  "image exists")    if hex64 "$3"; then [[ -f "$PS/img-${3#sha256:}" ]]; else exit 0; fi ;;
  "image inspect")   r="${@: -1}"
                     if [[ "$r" == localhost/periderm-build:* ]]; then echo "sha256:$BUILT_ID"
                     elif hex64 "$r" && [[ -f "$PS/img-${r#sha256:}" ]]; then echo "sha256:${r#sha256:}"; else exit 125; fi ;;
  "load -i")         id="$(head -c 64 "$3")"; touch "$PS/img-$id"; echo "Loaded image: sha256:$id" ;;
  "save --format")   [[ "$4" == -o ]] && printf "%s" "$SAVE_CONTENT" > "$5" ;;
  "inspect --format") echo "10.88.0.7 " ;;
  "container exists") [[ -f "$PS/ctr-$3" ]] ;;
  "ps -a")           for f in "$PS"/ctr-*; do [[ -e "$f" ]] && echo "${f##*/ctr-}"; done; exit 0 ;;
  "volume ls")       for f in "$PS"/vol-*; do [[ -e "$f" ]] && echo "${f##*/vol-}"; done; exit 0 ;;
  "volume exists")   [[ -f "$PS/vol-$3" ]] ;;
  "volume export")   [[ -f "$PS/vol-$3" ]] && cp "$PS/vol-$3" "$5" ;;
  "volume rm")       rm -f "$PS/vol-${@: -1}" ;;
  "rm -f")           rm -f "$PS/ctr-${@: -1}" ;;
  *) case "$1" in
       build) echo "STEP 1/2: FROM scratch"; echo "STEP 2/2: COPY . /app"; echo "COMMIT"; exit "${BUILD_RC:-0}" ;;
       run)   [[ -z "${VERIFY_RC:-}" ]] || { echo "Error: the verifier crashed"; exit "$VERIFY_RC"; }
              req="${@: -1}"; d="$(dirname "$req")"; ls "$d" > "$SCRATCH_LS"
              w="$(jq -r .workId "$req")"; a="$(jq -r .attempt "$req")"
              printf "%s" "{\"workId\":\"$w\",\"attempt\":$a,\"candidateId\":\"pdcand_1\",\"imageId\":\"sha256:abc\",\"checks\":[],\"mutation\":{\"10\":1,\"2\":0.5}}" > "$d/receipt.json"
              sha="$(jq -j "$CANON canon" "$d/receipt.json" | sha256sum | cut -d" " -f1)"
              printf "AW-VERIFY-RECEIPT-V1\n%s\n%s\n%s" "$w" "$a" "${RECEIPT_SHA:-$sha}" > "$d/receipt.sign" ;;
       *) exit 0 ;;
     esac ;;
esac'
stub systemctl '
quiet=0; args=(); for a in "$@"; do [[ "$a" == --quiet ]] && quiet=1 || args+=("$a"); done
case "${args[0]}" in
  is-active) [[ -f "$ACTIVE/${args[1]}" ]] ;;
  restart|start) u="${args[1]}"; touch "$ACTIVE/$u"; touch "$PS/ctr-${u%.service}"; exit 0 ;;
  disable) [[ "${args[1]}" == --now ]] && rm -f "$ACTIVE/${args[2]}"; exit 0 ;;
  *) exit 0 ;;
esac'
# systemd-run: the transient unit runs to completion, synchronously.
stub systemd-run '
args=("$@"); while [[ "${args[0]}" == --* ]]; do args=("${args[@]:1}"); done
"${args[@]}" >> "$JOBS_LOG" 2>&1; exit 0'
stub ufw '[[ "$1" == status ]] && echo "Status: active"; exit 0'
# curl: the control plane at https://cp.test and the instances probed over HTTP.
stub curl '
method=GET url="" out="" data="" dfile="" w="" ts="" nonce="" sig=""
while (( $# )); do case "$1" in
  -X) method="$2"; shift ;; -o) out="$2"; shift ;; -w) w="$2"; shift ;; --data) data="$2"; shift ;;
  --data-binary) dfile="${2#@}"; shift ;;
  -H) case "$2" in x-timestamp:*) ts="${2#*: }" ;; x-nonce:*) nonce="${2#*: }" ;; x-signature:*) sig="${2#*: }" ;; esac; shift ;;
  -D|--connect-timeout|--max-time|--resolve|--noproxy) shift ;;
  http*) url="$1" ;; esac; shift; done
if [[ "$url" =~ ^http://alwayswork-pdapp-[0-9a-f]{12}-([0-9a-f]{12}):[0-9]+ ]]; then
  img="${BASH_REMATCH[1]}"; f="$PROBES/$img"; n="$(cat "$f.n" 2>/dev/null || echo 0)"; n=$(( n + 1 )); echo "$n" > "$f.n"
  code="$(sed -n "${n}p" "$f" 2>/dev/null)"; [[ -n "$code" ]] || code="$(tail -n1 "$f" 2>/dev/null)"
  printf "%s" "${code:-000}"; exit 0
fi
[[ -f "$OFFLINE" ]] && exit 7
p="${url#https://cp.test}"; body="$data"; [[ -n "$dfile" ]] && body="@raw $(wc -c < "$dfile")"
# The device signature, checked the way the control plane does: METHOD, path
# without query, timestamp, nonce, sha256 of the exact body bytes.
if [[ -n "$dfile" ]]; then bh="$(sha256sum "$dfile" | cut -d" " -f1)"; else bh="$(printf "%s" "$data" | sha256sum | cut -d" " -f1)"; fi
m="$(mktemp)"; printf "%s\n%s\n%s\n%s\n%s" "$method" "${p%%\?*}" "$ts" "$nonce" "$bh" > "$m"
sigok=false; printf "%s" "$sig" | base64 -d > "$m.sig" 2>/dev/null \
  && openssl pkeyutl -verify -pubin -inkey "$DEVICE_PUB" -rawin -in "$m" -sigfile "$m.sig" >/dev/null 2>&1 && sigok=true
rm -f "$m" "$m.sig"
jq -nc --arg m "$method" --arg p "$p" --arg b "$body" --argjson s "$sigok" "{m:\$m, p:\$p, b:\$b, sig:\$s}" >> "$REQS"
code=200 resp="{\"accepted\":true}"
case "$method ${p%%\?*}" in
  "GET /v1/device/periderm/blobs") k="${p#*key=}"; k="$(printf "%b" "${k//%/\\x}")"
      if [[ -f "$BLOBS/$k" ]]; then cp "$BLOBS/$k" "$out"; printf 200; exit 0; fi; code=404 resp="{\"error\":{\"code\":\"not_found\"}}" ;;
  POST\ /v1/device/periderm/work/*/upload) cp "$dfile" "$BLOBS/uploaded-$(basename "$(dirname "$p")")"; code=201 resp="{}" ;;
  POST\ /v1/device/periderm/work/*/uploads) code=201 resp="{\"uploadId\":\"pdup_1\",\"key\":\"$(cat "$BLOBS/.upkey")\"}" ;;
  PUT\ /v1/device/periderm/uploads/*/parts/*) cat "$dfile" >> "$BLOBS/multipart.bin"; resp="{}" ;;
  POST\ /v1/device/periderm/uploads/*/complete) resp="{\"key\":\"$(cat "$BLOBS/.upkey")\"}" ;;
esac
if [[ -n "$out" ]]; then printf "%s" "$resp" > "$out"; printf "%s" "$code"; else printf "%s\n%s" "$resp" "$code"; fi'
export PATH="$S:$PATH" JOBS_LOG="$TMP/jobs.log" DEVICE_PUB="$TMP/device.pub"

export AW_TEST=1 DRY_RUN=0 AW_ROOT="$ROOT" AW_CLOCK_FLOOR=0
export AW_ETC="$TMP/etc" AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log" AW_CONFIG="$TMP/etc/worker.yaml"
export AW_SYSTEMD_DIR="$TMP/systemd" AW_OS_RELEASE="$TMP/os-release"
export PD_PART_BYTES=1024 PD_RETRY_SLEEP=0
mkdir -p "$AW_ETC/identity" "$AW_STATE" "$AW_SYSTEMD_DIR"
printf 'ID=arch\n' > "$AW_OS_RELEASE"
cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
roles() { yq -i ".control.url = \"https://cp.test\" | .capabilities.enabled = [\"core\",\"runtime.podman\"$(printf ',"%s"' "$@")]" "$AW_CONFIG"; }
DEV=dev_test0001
openssl genpkey -algorithm ED25519 -out "$AW_ETC/identity/device.key" 2>/dev/null
openssl pkey -in "$AW_ETC/identity/device.key" -pubout -out "$TMP/device.pub" 2>/dev/null
jq -n --arg d "$DEV" '{deviceId:$d}' > "$AW_ETC/control.json"
openssl genpkey -algorithm ED25519 -out "$TMP/control.key" 2>/dev/null
openssl genpkey -algorithm ED25519 -out "$TMP/other.key" 2>/dev/null
jq -n --arg k "$(openssl pkey -in "$TMP/control.key" -pubout -outform DER 2>/dev/null | base64 -w0)" '{kid:"ck1", publicKey:$k}' > "$AW_STATE/control-pubkey.json"

LIBS=(core config hardware distro engine firewall secrets capability workload periderm periderm-trust control)
libs() { local l; for l in "${LIBS[@]}"; do source "$ROOT/lib/$l.sh"; done; }   # shellcheck disable=SC1090
# shellcheck disable=SC1090
CANON="$(source "$ROOT/lib/periderm-trust.sh" 2>/dev/null; printf '%s' "$PD_JQ_CANON")"; export CANON
apply() { ( libs; periderm_trust_apply "$1" "${2:-full}" ) > "$TMP/out" 2>&1; }
reqs()  { cat "$REQS" 2>/dev/null; }
calls() { cat "$CALLS" 2>/dev/null; }
reset_logs() { : > "$CALLS"; : > "$REQS"; }
HAVE_NODE=0; command -v node >/dev/null && HAVE_NODE=1

# bodysha <json>: the control plane's sha256(canonicalJson(x)) — node when
# present (the reference), else the agent's own canonicalizer.
bodysha() {
  if (( HAVE_NODE )); then
    node -e 'const c=v=>Array.isArray(v)?v.map(c):(v!==null&&typeof v==="object")?Object.fromEntries(Object.keys(v).sort().map(k=>[k,c(v[k])])):v;
      process.stdout.write(require("crypto").createHash("sha256").update(JSON.stringify(c(JSON.parse(process.argv[1])))).digest("hex"))' "$1"
  else jq -j "$CANON canon" <<<"$1" | sha256sum | cut -d' ' -f1; fi
}
# work <kind> <id> <attempt> <expiresAt> <request> [signing-key] [device] [domain]
work() {
  local kind="$1" id="$2" att="$3" exp="$4" req="$5" key="${6:-$TMP/control.key}" dev="${7:-$DEV}" dom="${8:-}" body sha sig
  [[ -n "$dom" ]] || case "$kind" in build) dom=AW-BUILD-V1 ;; verify) dom=AW-VERIFY-V1 ;; backup) dom=AW-BACKUP-V1 ;; esac
  body="$(jq -nc --arg i "$id" --arg k "$kind" --argjson a "$att" --argjson e "$exp" --argjson r "$req" '{id:$i, kind:$k, attempt:$a, expiresAt:$e, request:$r}')"
  sha="$(bodysha "$body")"
  printf '%s\n%s\n%s\n%s\n%s\n%s' "$dom" "$dev" "$id" "$att" "$exp" "$sha" > "$TMP/msg"
  sig="$(openssl pkeyutl -sign -inkey "$key" -rawin -in "$TMP/msg" | base64 -w0)"
  jq -c --arg s "$sha" --arg d "$dom" --arg v "$sig" '. + {bodySha256:$s, signature:{domain:$d, kid:"ck1", value:$v}}' <<<"$body"
}
delivery() { # <work-json-array> <activations-json-array>
  jq -nc --argjson w "$1" --argjson a "${2:-[]}" '{state:"approved", config:{configVersion:7},
    periderm:{proxyImage:"ghcr.io/acme/periderm-proxy@sha256:bbbb", verifierImage:"ghcr.io/acme/periderm-verifier@sha256:cccc",
      egressAllow:["cp.test"], workspaces:[], work:$w, activations:$a}}'
}
LATER=$(( $(date +%s%3N) + 3600000 ))
BUILT_ID="$(printf built | sha256sum | cut -d' ' -f1)"; export BUILT_ID
SAVE_CONTENT="$(printf 'oci-archive-%.0s' {1..200})"; export SAVE_CONTENT   # 2400 bytes: three 1 KiB parts

echo "== periderm trust: canonical JSON =="
if (( HAVE_NODE )); then
  FX='{"z":1,"10":"a","2":[{"b":0.1,"a":1e21,"c":1.5e-7}],"a":"\u007f é \u2028 / \" \\ \n \u0001 😀","big":1700000000000,"e":[],"o":{"y":null,"x":true}}'
  FXJS="$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1])))' "$FX")"
  check "jq canonicalizer == JS canonicalJson (numeric keys, exponents, U+007F, unicode)" \
    '[[ "$(jq -j "$CANON canon" <<<"$FXJS" | sha256sum | cut -d" " -f1)" == "$(bodysha "$FXJS")" ]]'
  check "plain jq -S -c is NOT the same on that fixture (why the canonicalizer exists)" \
    '[[ "$(jq -S -c . <<<"$FXJS" | tr -d "\n" | sha256sum | cut -d" " -f1)" != "$(bodysha "$FXJS")" ]]'
else
  echo "  skip  node not installed: jq canonicalizer not cross-checked against JS"
fi

echo "== periderm trust: refusals =="
roles periderm.builder
git -C "$TMP" init -q -b main repo && printf 'FROM scratch\nCOPY . /app\n' > "$TMP/repo/Containerfile"
git -C "$TMP/repo" add . && git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm init
COMMIT="$(git -C "$TMP/repo" rev-parse HEAD)"
mkdir -p "$BLOBS/src/app1" && git -C "$TMP/repo" bundle create -q "$BLOBS/src/app1/$COMMIT.bundle" main 2>/dev/null
BREQ="$(jq -nc --arg c "$COMMIT" --arg s "$(sha256sum "$BLOBS/src/app1/$COMMIT.bundle" | cut -d' ' -f1)" \
  '{commitId:$c, bundleKey:("src/app1/" + $c + ".bundle"), bundleSha256:$s, archiveKey:"images/app1/pdcand_1.oci.tar", kind:"build", appId:"app1", candidateId:"pdcand_1"}')"
reset_logs
check "a work item signed by another key is refused: nothing runs, nothing posted" \
  '! apply "$(delivery "[$(work build pdwb_bad 1 $LATER "$BREQ" "$TMP/other.key")]")" && grep -q "SIGNATURE INVALID" "$TMP/out" && ! calls | grep -q "^systemd-run\|^podman build" && [[ ! -s "$REQS" ]]'
check "a work item signed for another device is refused" \
  '! apply "$(delivery "[$(work build pdwb_dev 1 $LATER "$BREQ" "$TMP/control.key" dev_other)]")" && grep -q "SIGNATURE INVALID" "$TMP/out" && ! calls | grep -q "^systemd-run"'
check "a work item whose request was altered after signing is refused" \
  '! apply "$(delivery "[$(work build pdwb_alt 1 $LATER "$BREQ" | jq -c ".request.archiveKey = \"images/evil.tar\"")]")" && grep -q "body digest" "$TMP/out" && ! calls | grep -q "^systemd-run"'
check "a build signed in the verify domain is refused" \
  '! apply "$(delivery "[$(work build pdwb_dom 1 $LATER "$BREQ" "$TMP/control.key" "$DEV" AW-VERIFY-V1)]")" && grep -q "domain" "$TMP/out" && ! calls | grep -q "^systemd-run"'
check "an expired work item is refused" \
  '! apply "$(delivery "[$(work build pdwb_old 1 $(( $(date +%s%3N) - 1000 )) "$BREQ")]")" && grep -q "expired" "$TMP/out" && ! calls | grep -q "^systemd-run"'
check "work for a role not enabled here (verify on a builder) is refused" \
  '! apply "$(delivery "[$(work verify pdwv_no 1 $LATER "{\"mode\":\"candidate\"}")]")" && grep -q "periderm.verifier is not enabled" "$TMP/out" && ! calls | grep -q "^systemd-run\|^podman run"'
check "nothing at all reached the control plane for refused work" '[[ ! -s "$REQS" ]]'
: > "$TMP/out"
check "a refused-for-good item is not logged again on the next delivery" \
  '! apply "$(delivery "[$(work build pdwb_old 1 $(( $(date +%s%3N) - 1000 )) "$BREQ")]")"; ! grep -q "expired" "$TMP/out"'

echo "== periderm.builder: build =="
reset_logs; printf 'images/app1/pdcand_1.oci.tar' > "$BLOBS/.upkey"; rm -f "$BLOBS/multipart.bin"
BW="$(work build pdwb_ok 1 $LATER "$BREQ")"
apply "$(delivery "[$BW]")"
check "the build runs as a transient unit, outside the apply" 'calls | grep -q "^systemd-run --unit=alwayswork-pdjob-pdwb_ok-1 "'
check "podman build: never --network=host; the internal periderm network" \
  'calls | grep "^podman build" | grep -q -- "--network periderm " && ! calls | grep -q -- "--network=host\|--network host"'
check "podman build: proxy build args, hardened, bounded" \
  'calls | grep "^podman build" | grep -q -- "--build-arg HTTPS_PROXY=http://alwayswork-periderm-proxy:3128 --build-arg HTTP_PROXY=http://alwayswork-periderm-proxy:3128" && calls | grep "^podman build" | grep -q -- "--cap-drop ALL" && calls | grep "^podman build" | grep -q -- "--security-opt no-new-privileges" && calls | grep "^podman build" | grep -q -- "--memory 4096m"'
check "the build uses the checked-out commit's Containerfile" 'calls | grep "^podman build" | grep -q -- "-f $AW_STATE/periderm/work/pdwb_ok.1/src/Containerfile"'
check "the egress proxy is up for the build" '[[ -f "$AW_SYSTEMD_DIR/alwayswork-periderm-proxy.service" ]] && grep -q "alwayswork.capability=periderm.builder" "$AW_SYSTEMD_DIR/alwayswork-periderm-proxy.service"'
check "image saved as an oci-archive" 'calls | grep -q "^podman save --format oci-archive -o .*image.oci.tar localhost/periderm-build:"'
check "multipart upload: opened for the chosen key, three parts in order, completed" \
  '[[ "$(reqs | jq -r "select(.p | test(\"uploads\")) | .m + \" \" + .p" | paste -sd,)" == "POST /v1/device/periderm/work/pdwb_ok/uploads,PUT /v1/device/periderm/uploads/pdup_1/parts/1,PUT /v1/device/periderm/uploads/pdup_1/parts/2,PUT /v1/device/periderm/uploads/pdup_1/parts/3,POST /v1/device/periderm/uploads/pdup_1/complete" ]] && [[ "$(cat "$BLOBS/multipart.bin")" == "$SAVE_CONTENT" ]]'
RES="$(reqs | jq -r 'select(.p == "/v1/device/periderm/work/pdwb_ok/result") | .b')"
check "result posted after the upload: ok, image id, duration, log tail" \
  '[[ "$(jq -r ".attempt, .result.ok, .result.imageId" <<<"$RES" | paste -sd,)" == "1,true,sha256:$BUILT_ID" ]] && jq -e ".result.durationMs >= 0 and (.result.logTail | test(\"STEP 2/2\"))" <<<"$RES" >/dev/null && [[ "$(reqs | jq -r .p | tail -n1)" == /v1/device/periderm/work/pdwb_ok/result ]]'
check "every call carried a device signature valid over its exact body (JSON, raw parts, GET)" \
  '[[ "$(reqs | jq -s "length > 5 and all(.sig)")" == true ]]'
check "the control plane's blob download was signed with the device headers" 'calls | grep "^curl .*https://cp.test/v1/device/periderm/blobs?key=src%2Fapp1%2F" | grep -q "x-device-id: $DEV .*x-signature: [A-Za-z0-9+/=]\{80,\}"'
reset_logs
check "a repeated delivery does not rebuild or repost" \
  'apply "$(delivery "[$BW]")" && ! calls | grep -q "^systemd-run\|^podman build" && [[ ! -s "$REQS" ]]'
reset_logs
NOCF="$(jq -c '.bundleKey = "src/app1/nocf.bundle"' <<<"$BREQ")"
git -C "$TMP/repo" rm -q Containerfile && git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm rm
C2="$(git -C "$TMP/repo" rev-parse HEAD)"; git -C "$TMP/repo" bundle create -q "$BLOBS/src/app1/nocf.bundle" main 2>/dev/null
NOCF="$(jq -c --arg c "$C2" '.commitId = $c | del(.bundleSha256)' <<<"$NOCF")"
check "a repository without a Containerfile/Dockerfile is refused: no build, ok:false posted" \
  'apply "$(delivery "[$(work build pdwb_nocf 1 $LATER "$NOCF")]")"; ! calls | grep -q "^podman build" && reqs | jq -r "select(.p == \"/v1/device/periderm/work/pdwb_nocf/result\") | .b" | jq -e ".result.ok == false and (.result.error | test(\"Containerfile\"))" >/dev/null'

echo "== periderm.verifier =="
roles periderm.verifier; reset_logs
for f in cand revert backup; do printf '%s-archive' "$f" > "$BLOBS/$f.tar"; done
VREQ="$(jq -nc --arg c "$COMMIT" --arg cs "$(sha256sum "$BLOBS/cand.tar" | cut -d' ' -f1)" --arg bs "$(sha256sum "$BLOBS/backup.tar" | cut -d' ' -f1)" \
  '{mode:"candidate", candidate:{archiveKey:"cand.tar", archiveSha256:$cs, imageId:"sha256:abc", commitId:$c},
    revertTo:{archiveKey:"revert.tar", imageId:"sha256:def"}, bundleKey:("src/app1/" + $c + ".bundle"),
    backup:{blobKey:"backup.tar", sha256:$bs}, appPort:8080, kind:"verify", appId:"app1", candidateId:"pdcand_1"}')"
apply "$(delivery "[$(work verify pdwv_ok 2 $LATER "$VREQ")]")"
SCR="$AW_STATE/periderm/verify/pdwv_ok"
RUNL="$(calls | grep '^podman run ' | tail -n1)"
check "the internal periderm-verify network is created" 'calls | grep -qx "podman network create --internal periderm-verify"'
check "the verifier can resolve its candidates by name through a strict firewall: DNS only, from the verify subnet" \
  'calls | grep -q "^ufw allow from 10.90.0.0/24 to any port 53 proto udp comment alwayswork:periderm.verifier" && calls | grep -q "^ufw allow from 10.90.0.0/24 to any port 53 proto tcp comment alwayswork:periderm.verifier" && ! calls | grep -q "^ufw route allow from 10.90.0.0/24.*periderm.verifier"'
check "verifier container: socket, same-path scratch, network, env, command" \
  'grep -q -- "-v /run/podman/podman.sock:/run/podman/podman.sock" <<<"$RUNL" && grep -q -- "-v $SCR:$SCR " <<<"$RUNL" && grep -q -- "--network periderm-verify" <<<"$RUNL" && grep -q -- "--name periderm-verifier-[0-9a-f]\{12\}" <<<"$RUNL" && grep -q -- "-e PERIDERM_VERIFY_NETWORK=periderm-verify" <<<"$RUNL" && grep -q -- "-e PERIDERM_VERIFIER_HOST=periderm-verifier-[0-9a-f]\{12\}" <<<"$RUNL" && grep -q -- "-e PERIDERM_VERIFIER_IMAGE=ghcr.io/acme/periderm-verifier@sha256:cccc" <<<"$RUNL" && [[ "${RUNL##* }" == "$SCR/request.json" ]]'
check "scratch held candidate.tar, revert.tar, source.bundle, backup.tar and request.json (+workId, attempt)" \
  '[[ "$(sort "$SCRATCH_LS" | paste -sd,)" == "backup.tar,candidate.tar,request.json,revert.tar,source.bundle" ]] && jq -e ".workId == \"pdwv_ok\" and .attempt == 2 and .mode == \"candidate\"" "$SCR/request.json" >/dev/null'
VRES="$(reqs | jq -r 'select(.p == "/v1/device/periderm/work/pdwv_ok/result") | .b')"
check "receipt posted as written, with the device's signature over receipt.sign" \
  '[[ "$(jq -c .result.receipt <<<"$VRES")" == "$(jq -c . "$SCR/receipt.json")" ]] && jq -r .result.signature <<<"$VRES" | base64 -d > "$TMP/rsig" && openssl pkeyutl -verify -pubin -inkey "$TMP/device.pub" -rawin -in "$SCR/receipt.sign" -sigfile "$TMP/rsig" >/dev/null 2>&1 && [[ "$(jq -r .attempt <<<"$VRES")" == 2 ]]'
reset_logs
apply "$(delivery "[$(work verify pdwv_nob 1 $LATER "$(jq -c '.backup = null' <<<"$VREQ")")]")"
check "no backup in the request: no backup.tar downloaded" \
  '[[ "$(sort "$SCRATCH_LS" | paste -sd,)" == "candidate.tar,request.json,revert.tar,source.bundle" ]] && ! reqs | grep -q "backup.tar"'
reset_logs; export RECEIPT_SHA=0000000000000000000000000000000000000000000000000000000000000000
apply "$(delivery "[$(work verify pdwv_forged 1 $LATER "$VREQ")]")"
check "a receipt.sign that is not this receipt's statement is never signed: only an unsigned could-not-run report goes" \
  'FR="$(reqs | jq -r "select(.p == \"/v1/device/periderm/work/pdwv_forged/result\") | .b")"; jq -e ".result.ok == false and (.result.error | test(\"refusing to sign\")) and (.result | has(\"signature\") | not) and (.result | has(\"receipt\") | not)" <<<"$FR" >/dev/null && grep -q "refusing to sign" "$JOBS_LOG"'
unset RECEIPT_SHA
reset_logs; export VERIFY_RC=3
apply "$(delivery "[$(work verify pdwv_crash 1 $LATER "$VREQ")]")"
check "a verifier that fails reports it could not run (with its last lines), so the control plane retries" \
  'CR="$(reqs | jq -r "select(.p == \"/v1/device/periderm/work/pdwv_crash/result\") | .b")"; jq -e ".attempt == 1 and .result.ok == false and (.result.error | test(\"the verifier failed: .*crashed\"))" <<<"$CR" >/dev/null'
unset VERIFY_RC
reset_logs; mkdir -p "$AW_STATE/periderm/work/pdwv_orphan.1/claimed"; touch "$AW_STATE/periderm/work/pdwv_orphan.1/done"
apply "$(delivery "[$(work verify pdwv_orphan 1 $LATER "$VREQ")]")"
check "claimed verify work whose job ended without a result is reported once, never re-run" \
  'OR="$(reqs | jq -r "select(.p == \"/v1/device/periderm/work/pdwv_orphan/result\") | .b")"; jq -e ".result.ok == false and (.result.error | test(\"ended without a result\"))" <<<"$OR" >/dev/null && ! calls | grep -q "^systemd-run" && reset_logs && apply "$(delivery "[$(work verify pdwv_orphan 1 $LATER "$VREQ")]")" && ! reqs | grep -q "pdwv_orphan/result"'
reset_logs; roles periderm.verifier periderm.runtime
check "the verifier refuses to share a node with another Periderm role (nothing runs)" \
  '! apply "$(delivery "[$(work verify pdwv_x 1 $LATER "$VREQ")]")" && grep -q "shares this node" "$TMP/out" && ! calls | grep -q "^systemd-run\|^podman run"'
pre() { ( libs; _AW_CAP_DONE=" "; source "$ROOT/capabilities/$1/preflight.sh" ) >/dev/null 2>&1; }
check "preflight: the verifier refuses when builder/workspace/runtime is enabled" \
  '! pre periderm.verifier && roles periderm.builder && ! pre periderm.verifier && roles periderm.workspace && ! pre periderm.verifier && roles && pre periderm.verifier'
check "preflight: builder and runtime refuse a node with the verifier" \
  'roles periderm.verifier && ! pre periderm.builder && ! pre periderm.runtime && roles && pre periderm.builder && pre periderm.runtime'

echo "== periderm.runtime: activations =="
roles periderm.runtime; reset_logs
HEX="$(printf app1 | sha256sum | cut -c1-12)"
I1="$(printf img1 | sha256sum | cut -d' ' -f1)"; I2="$(printf img2 | sha256sum | cut -d' ' -f1)"; I3="$(printf img3 | sha256sum | cut -d' ' -f1)"
printf '%s' "$I1" > "$BLOBS/r1.tar"; printf '%s' "$I1" > "$BLOBS/r3-wrong.tar"   # r3's archive holds another image
ref() { jq -nc --arg i "$1" --arg k "$2" --arg s "$(sha256sum "$BLOBS/$2" 2>/dev/null | cut -d' ' -f1)" '{candidateId:"c", commitId:"x", archiveKey:$k, archiveSha256:$s, imageId:("sha256:" + $i)}'; }
act() { # <id> <state> <target-ref> <revertTo-ref|null> <windowMs>
  jq -nc --arg id "$1" --arg st "$2" --arg h "$HEX" --argjson t "$3" --argjson r "$4" --argjson w "$5" \
    '{activationId:$id, appId:"app1", state:$st, appSurface:("pa-" + $h), appPort:8080, target:$t, revertTo:$r,
      probe:{kind:"http", path:"/healthz", expect:200, intervalMs:20}, readyWithinMs:2000, revertWindowMs:$w,
      env:{PERIDERM_APP_ID:"app1", PERIDERM_ISSUER:"https://cp.test/periderm"}}'
}
TF="$AW_STATE/periderm/apps/$HEX/target"
LB="$AW_SYSTEMD_DIR/alwayswork-pdapp-$HEX-lb.service"; IN1="$AW_SYSTEMD_DIR/alwayswork-pdapp-$HEX-${I1:0:12}.service"
printf '200\n' > "$PROBES/${I1:0:12}"
A1="$(act pdact_1 approved "$(ref "$I1" r1.tar)" null 200)"
apply "$(delivery '[]' "[$A1]")"
check "the watchdog runs detached" 'calls | grep -q "^systemd-run --unit=alwayswork-pdwd-pdact_1 "'
check "image loaded from the archive and its id checked" 'calls | grep -q "^podman load -i" && [[ -f "$PS/img-$I1" ]]'
check "target instance: workload network, data volume, hardened, env file" \
  'grep -q -- "--network alwayswork" "$IN1" && grep -q -- "--volume pdapp-$HEX-data:/data:U" "$IN1" && grep -q -- "--userns=auto" "$IN1" && grep -q -- "--cap-drop ALL" "$IN1" && grep -q -- "--read-only" "$IN1" && grep -q " $I1 *$" "$IN1" && E="$AW_ETC/periderm/pdapp-$HEX-${I1:0:12}.env" && [[ "$(stat -c %a "$E")" == 600 ]] && grep -qx PORT=8080 "$E" && grep -qx DATA_DIR=/data "$E" && grep -qx PERIDERM_APP_ID=app1 "$E"'
HP=$(( 25000 + (16#${HEX:0:4} % 4000) ))
check "listener: proxy image with FORWARD_TO_FILE, state dir read-only, loopback port in the app range" \
  'grep -q "FORWARD_TO_FILE=/run/periderm/target" "$LB" && grep -q -- "--volume $AW_STATE/periderm/apps/$HEX:/run/periderm:ro" "$LB" && grep -q -- "--publish 127.0.0.1:$HP:3129" "$LB" && grep -q -- "--network alwayswork" "$LB" && grep -q "periderm-proxy@sha256:bbbb" "$LB" && (( HP >= 25000 && HP < 29000 ))'
check "listener reported as exposed service pa-<hex> (http)" \
  '[[ "$(jq -c "[.id, .protocol, .port]" "$AW_STATE/services/pa-$HEX.json")" == "[\"pa-$HEX\",\"http\",$HP]" ]]'
check "traffic flipped to the target instance; staging then active reported" \
  '[[ "$(cat "$TF")" == "alwayswork-pdapp-$HEX-${I1:0:12}:8080" ]] && [[ "$(reqs | jq -r "select(.p == \"/v1/device/periderm/activations/pdact_1/report\") | .b | fromjson | .state" | paste -sd,)" == "staging,active" ]]'
check "first release: nothing to stop after the window; instance keeps running" '[[ -f "$IN1" && "$(cat "$AW_STATE/periderm/activations/pdact_1/phase")" == done ]]'
reset_logs
A1A="$(act pdact_1 active "$(ref "$I1" r1.tar)" null 200)"
check "repeated deliveries (approved again, then active) do not restart the rollout" \
  'apply "$(delivery "[]" "[$A1]")" && apply "$(delivery "[]" "[$A1A]")" && ! calls | grep -q "^systemd-run\|systemctl restart" && [[ ! -s "$REQS" ]]'

echo "== periderm.runtime: local revert with the control plane unreachable =="
reset_logs; touch "$PS/img-$I2"                       # the release is already on the node
printf '200\n200\n500\n' > "$PROBES/${I2:0:12}"
A2="$(act pdact_2 approved "$(ref "$I2" r2.tar)" "$(ref "$I1" r1.tar)" 5000)"
touch "$OFFLINE"
apply "$(delivery '[]' "[$A1A,$A2]")"
check "target started next to the current release" 'calls | grep -q "systemctl restart alwayswork-pdapp-$HEX-${I2:0:12}.service" && ! calls | grep -q "systemctl restart alwayswork-pdapp-$HEX-${I1:0:12}.service"'
check "3 failed probes: traffic back on the revertTo instance, target stopped" \
  '[[ "$(cat "$TF")" == "alwayswork-pdapp-$HEX-${I1:0:12}:8080" ]] && [[ ! -f "$AW_SYSTEMD_DIR/alwayswork-pdapp-$HEX-${I2:0:12}.service" && -f "$IN1" ]] && [[ "$(cat "$AW_STATE/periderm/activations/pdact_2/phase")" == reverted ]]'
check "nothing reached the control plane; staging, active, reverted queued in order" \
  '[[ ! -s "$REQS" ]] && [[ "$(for f in "$AW_STATE"/periderm/outbox/*.json; do jq -r .body.state "$f"; done | paste -sd,)" == "staging,active,reverted" ]]'
rm -f "$OFFLINE"
( libs; periderm_trust_tick ) > "$TMP/out" 2>&1
check "next tick, control plane back: the queued reports are delivered in order, outbox empty" \
  '[[ "$(reqs | jq -r "select(.p == \"/v1/device/periderm/activations/pdact_2/report\") | .b | fromjson | .state" | paste -sd,)" == "staging,active,reverted" ]] && [[ -z "$(ls "$AW_STATE/periderm/outbox"/*.json 2>/dev/null)" ]]'
check "the revert report says what the probe saw" \
  'reqs | jq -r "select(.p == \"/v1/device/periderm/activations/pdact_2/report\") | .b | fromjson | select(.state == \"reverted\") | .detail.probe" | grep -q "GET /healthz -> 500 (3 consecutive)"'
reset_logs
A2D="$(act pdact_2 active "$(ref "$I2" r2.tar)" "$(ref "$I1" r1.tar)" 5000)"
check "a release this node reverted is never brought back by a later delivery" \
  'apply "$(delivery "[]" "[$A1A,$A2D]")" && [[ "$(cat "$TF")" == "alwayswork-pdapp-$HEX-${I1:0:12}:8080" ]] && ! calls | grep -q "pdapp-$HEX-${I2:0:12}.service"'

echo "== periderm.runtime: image id check =="
reset_logs
A3="$(act pdact_3 approved "$(ref "$I3" r3-wrong.tar)" "$(ref "$I1" r1.tar)" 200)"
apply "$(delivery '[]' "[$A1A,$A3]")"
check "an archive whose loaded image id differs is refused: no instance, traffic untouched, failed reported" \
  '[[ ! -f "$AW_SYSTEMD_DIR/alwayswork-pdapp-$HEX-${I3:0:12}.service" ]] && [[ "$(cat "$TF")" == "alwayswork-pdapp-$HEX-${I1:0:12}:8080" ]] && reqs | jq -r "select(.p == \"/v1/device/periderm/activations/pdact_3/report\") | .b | fromjson | .state" | grep -qx failed && grep -q "refusing it" "$JOBS_LOG"'

echo "== periderm.runtime: reboot reconcile =="
reset_logs; rm -f "$IN1" "$TF"
check "an active release whose units are gone is converged again (instance, listener, target file)" \
  'apply "$(delivery "[]" "[$A1A]")" && [[ -f "$IN1" && -f "$LB" ]] && [[ "$(cat "$TF")" == "alwayswork-pdapp-$HEX-${I1:0:12}:8080" ]] && ! calls | grep -q "^systemd-run"'

echo "== periderm.runtime: backup =="
reset_logs; printf 'volume-tar-bytes' > "$PS/vol-pdapp-$HEX-data"
apply "$(delivery "[$(work backup pdwk_1 1 $LATER '{"blobKey":"backups/app1/x.tar","kind":"backup","appId":"app1","candidateId":null}')]" "[$A1A]")"
check "backup exports the app's data volume" 'calls | grep -q "^podman volume export pdapp-$HEX-data --output .*backup.tar"'
check "uploaded to the work's key (single request) and {ok:true} posted" \
  '[[ "$(cat "$BLOBS/uploaded-pdwk_1")" == volume-tar-bytes ]] && [[ "$(reqs | jq -r "select(.p == \"/v1/device/periderm/work/pdwk_1/result\") | .b" | jq -c .)" == "{\"attempt\":1,\"result\":{\"ok\":true}}" ]]'

echo "== periderm.runtime: removal =="
reset_logs
check "no activation delivered any more: listener, instances, surface go; the data volume stays" \
  'apply "$(delivery "[]" "[]")" && [[ -z "$(ls "$AW_SYSTEMD_DIR" | grep pdapp)" && ! -f "$AW_STATE/services/pa-$HEX.json" && -f "$PS/vol-pdapp-$HEX-data" ]]'
roles
check "no trust role: delivered work is ignored, nothing runs" \
  'apply "$(delivery "[$(work backup pdwk_2 1 $LATER "{\"blobKey\":\"b\",\"appId\":\"app1\"}")]")" && grep -q "no Periderm trust role" "$TMP/out" && ! calls | grep -q "^systemd-run"'

echo "== periderm trust: control-agent wiring =="
check "same-sequence deliveries still pick up new work; ticks flush the outbox; apply runs it isolated" \
  'grep -q "( periderm_trust_apply \"\$out\" current ) >&2 || true" "$ROOT/lib/control.sh" && grep -q "( periderm_trust_tick ) || true" "$ROOT/lib/control.sh" && grep -q "( periderm_trust_apply \"\$json\" full ) >>\"\$plog\" 2>&1 || { prc=1" "$ROOT/lib/control.sh"'

printf 'periderm.trust: passed %d failed %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
