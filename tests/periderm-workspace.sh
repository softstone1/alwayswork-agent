#!/usr/bin/env bash
# periderm.workspace: desired state `periderm` -> networks, proxy, workspace
# and preview units on the workload contract, and their removal. Host-free:
# podman, systemctl, ufw and (unless the real one is wanted) age are stubs
# that log their argv; units land in a scratch systemd dir.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
REAL_AGE="$(command -v age 2>/dev/null || true)"; REAL_KEYGEN="$(command -v age-keygen 2>/dev/null || true)"

# --- stubs ------------------------------------------------------------------
S="$TMP/stubs"; mkdir -p "$S"
export CALLS="$TMP/calls" PS="$TMP/podman" ACTIVE="$TMP/active"
mkdir -p "$PS" "$ACTIVE"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$S/$1"; chmod +x "$S/$1"; }
stub podman '
case "$1 $2" in
  "network exists")  [[ -f "$PS/net-$3" ]] ;;
  "network create")  if [[ "$3" == --internal ]]; then echo true > "$PS/net-$4"; else echo "${NET_INTERNAL_DEFAULT:-false}" > "$PS/net-$3"; fi ;;
  "network inspect") [[ -f "$PS/net-$3" ]] || exit 125
                     case "$5" in *Internal*) cat "$PS/net-$3" ;; *Subnet*) [[ "$3" == periderm ]] && echo 10.90.0.0/24 || echo 10.91.0.0/24 ;; esac ;;
  "network rm")      exit 0 ;;
  "image exists")    exit 0 ;;
  "ps -a")           for f in "$PS"/ctr-*; do [[ -e "$f" ]] && echo "${f##*/ctr-}"; done; exit 0 ;;
  "volume ls")       for f in "$PS"/vol-*; do [[ -e "$f" ]] && echo "${f##*/vol-}"; done; exit 0 ;;
  "volume exists")   [[ -f "$PS/vol-$3" ]] ;;
  "volume rm")       rm -f "$PS/vol-${@: -1}" ;;
  "container exists") [[ -f "$PS/ctr-$3" ]] ;;
  "rm -f")           rm -f "$PS/ctr-${@: -1}" ;;
  *) exit 0 ;;
esac'
# systemctl: a (re)start runs the unit: its container appears, and so does
# its named volume, the way podman run creates one.
stub systemctl '
quiet=0; args=(); for a in "$@"; do [[ "$a" == --quiet ]] && quiet=1 || args+=("$a"); done
case "${args[0]}" in
  is-active) [[ -f "$ACTIVE/${args[1]}" ]] ;;
  restart|start)
    u="${args[1]}"; touch "$ACTIVE/$u"; c="${u%.service}"; touch "$PS/ctr-$c"
    v="$(grep -o -- "--volume alwayswork-pdws-[0-9a-f]*" "$AW_SYSTEMD_DIR/$u" | sed "s/--volume //")"
    [[ -n "$v" ]] && touch "$PS/vol-$v"; exit 0 ;;
  disable) [[ "${args[1]}" == --now ]] && rm -f "$ACTIVE/${args[2]}"; exit 0 ;;
  *) exit 0 ;;
esac'
stub ufw '[[ "$1" == status ]] && echo "Status: active"; exit 0'
# age: `age -d -i <key>` on stdin; the "sealed" body is base64 of the token
# between the armor lines. A body of BAD fails like a wrong recipient.
mkdir -p "$TMP/agestub"
printf '#!/usr/bin/env bash\necho "age $*" >> "$CALLS"\n%s\n' '
[[ "$1" == -d && "$2" == -i && -r "$3" ]] || exit 1
body="$(sed -n 2p)"; [[ "$body" == BAD ]] && exit 1
printf "%s" "$body" | base64 -d' > "$TMP/agestub/age"; chmod +x "$TMP/agestub/age"
export PATH="$S:$TMP/agestub:$PATH"

export AW_TEST=1 DRY_RUN=0 AW_ROOT="$ROOT"
export AW_ETC="$TMP/etc" AW_STATE="$TMP/state" AW_LOG_DIR="$TMP/log" AW_CONFIG="$TMP/etc/worker.yaml"
export AW_SYSTEMD_DIR="$TMP/systemd" AW_OS_RELEASE="$TMP/os-release"
mkdir -p "$AW_ETC" "$AW_STATE" "$AW_SYSTEMD_DIR"
printf 'ID=arch\n' > "$AW_OS_RELEASE"
cp "$ROOT/config/defaults.yaml" "$AW_CONFIG"
yq -i '.control.url = "https://alwayswork.space" | .capabilities.enabled = ["core","runtime.podman","periderm.workspace"]' "$AW_CONFIG"
printf 'AGE-SECRET-KEY-TEST\n' > "$AW_ETC/age.key"; chmod 600 "$AW_ETC/age.key"

libs() {
  local l; for l in core config hardware distro engine firewall secrets capability workload periderm; do
    # shellcheck disable=SC1090
    source "$ROOT/lib/$l.sh"; done
}
apply() { ( libs; periderm_apply_from_delivery "$1" ) > "$TMP/out" 2>&1; }

TOKEN="pdws_Tok3nV4lueAbcdefGhijkl"
seal() { printf -- '-----BEGIN AGE ENCRYPTED FILE-----\n%s\n-----END AGE ENCRYPTED FILE-----\n' "$(printf '%s' "$1" | base64 -w0)"; }
# ws <sid> <surface> <previewPort|null> [paused] [sealed]
ws() {
  jq -nc --arg s "$1" --arg pv "$2" --argjson p "$3" --argjson paused "${4:-false}" --arg t "${5:-$(seal "$TOKEN")}" \
    '{sessionId:$s, appId:"pdapp_ref", generation:3, image:"ghcr.io/acme/periderm-workspace@sha256:aaaa",
      limits:{cpu:2, memoryMb:4096, pids:1024}, previewPort:$p, previewSurface:$pv, baseCommit:null, paused:$paused, sealedToken:$t}'
}
delivery() { # <workspace-json>...
  local w='[]' x; for x in "$@"; do w="$(jq -c --argjson x "$x" '. + [$x]' <<<"$w")"; done
  jq -nc --argjson w "$w" '{state:"approved", config:{configVersion:7},
    periderm:{proxyImage:"ghcr.io/acme/periderm-proxy@sha256:bbbb", egressAllow:["alwayswork.space","*.example.org"], workspaces:$w}}'
}
H1=0123456789ab; H2=fedcba987654
WS="$AW_SYSTEMD_DIR/alwayswork-pdws-$H1.service"; PV="$AW_SYSTEMD_DIR/alwayswork-pdpv-$H1.service"
PX="$AW_SYSTEMD_DIR/alwayswork-periderm-proxy.service"; ENVF="$AW_ETC/periderm/pdws-$H1.env"
flags() { grep -o -- "$2" "$1" | wc -l; }
calls() { cat "$CALLS" 2>/dev/null; }

echo "== periderm.workspace: one workspace with a preview =="
check "converge succeeds"            'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)")" || { cat "$TMP/out"; false; }'
check "networks: periderm is --internal, periderm-egress a plain bridge" \
  'calls | grep -qx "podman network create --internal periderm" && calls | grep -qx "podman network create periderm-egress"'
check "workspace unit: isolation contract" \
  'grep -q -- "--userns=auto" "$WS" && grep -q -- "--cap-drop ALL" "$WS" && grep -q -- "--security-opt no-new-privileges:true" "$WS" && grep -q -- "--read-only" "$WS" && grep -q -- "--tmpfs /tmp:" "$WS" && grep -q -- "--tmpfs /home/node:" "$WS"'
check "workspace unit: budget from limits (last flag wins over engine defaults)" \
  'grep -q -- "--cpus 2 --memory 4096m --pids-limit 1024" "$WS"'
check "workspace unit: only the periderm network" \
  '[[ "$(flags "$WS" "--network [^ ]*")" == 1 ]] && grep -q -- "--network periderm " "$WS" && ! grep -q -- "--network host" "$WS" && ! grep -q -- "--network alwayswork" "$WS"'
check "workspace unit: no host mounts, no socket, no publish — only its own volume" \
  '[[ "$(flags "$WS" "--volume ")" == 1 ]] && grep -q -- "--volume alwayswork-pdws-$H1:/workspace:U" "$WS" && ! grep -q -- "--volume /" "$WS" && ! grep -q "podman.sock\|docker.sock" "$WS" && ! grep -q -- "--publish" "$WS"'
check "workspace unit: env from a file, session labels" \
  'grep -q -- "--env-file $ENVF" "$WS" && ! grep -q -- "--env " "$WS" && grep -q "dev.alwayswork.periderm.session=pds_AbC-12_xyz" "$WS" && grep -q "alwayswork.capability=periderm.workspace" "$WS"'
check "env file: 0600, decrypted token, control URL and proxy" \
  '[[ "$(stat -c %a "$ENVF")" == 600 ]] && grep -qx "PERIDERM_WORKSPACE_TOKEN=$TOKEN" "$ENVF" && grep -qx "PERIDERM_CONTROL=https://alwayswork.space" "$ENVF" && grep -qx "HTTPS_PROXY=http://alwayswork-periderm-proxy:3128" "$ENVF" && grep -qx "HTTP_PROXY=http://alwayswork-periderm-proxy:3128" "$ENVF" && grep -qx "NO_PROXY=127.0.0.1,localhost" "$ENVF"'
check "token never in a unit file, an argv or the log" \
  '! grep -rq "$TOKEN" "$AW_SYSTEMD_DIR" && ! grep -q "$TOKEN" "$CALLS" && ! grep -q "$TOKEN" "$TMP/out"'
check "token opened with the node age identity, sealed text on stdin" \
  'calls | grep -qx "age -d -i $AW_ETC/age.key"'
check "proxy unit: both networks, allowlist, hardened, nothing published" \
  'grep -q -- "--network periderm " "$PX" && grep -q -- "--network periderm-egress" "$PX" && grep -q "PERIDERM_EGRESS_ALLOW=alwayswork.space,\*.example.org" "$PX" && grep -q -- "--userns=auto" "$PX" && grep -q -- "--cap-drop ALL" "$PX" && grep -q -- "no-new-privileges:true" "$PX" && grep -q -- "--read-only" "$PX" && grep -q -- "--pids-limit 256" "$PX" && grep -q -- "--memory 256m" "$PX" && ! grep -q -- "--publish" "$PX" && grep -q "periderm-proxy@sha256:bbbb" "$PX"'
check "preview unit: forwarder to the workspace, both networks, loopback publish on the hashed port" \
  'grep -q -- "--publish 127.0.0.1:21291:3129" "$PV" && grep -q "FORWARD_TO=alwayswork-pdws-$H1:5173" "$PV" && grep -q -- "--network periderm " "$PV" && grep -q -- "--network periderm-egress" "$PV" && grep -q "periderm-proxy@sha256:bbbb" "$PV" && ! grep -q -- "--publish 0.0.0.0" "$PV"'
hb() { ( libs; wl_services_json ); }
check "heartbeat expose.services carries the preview as surface pv-<hex>" \
  '[[ "$(hb | jq -c ".[] | select(.id == \"pv-$H1\") | [.protocol, .port, .workload, .kind]")" == "[\"http\",21291,\"pdws-$H1\",\"http\"]" ]] && hb | jq -e ".[] | select(.id == \"pv-$H1\") | .name | length > 0 and length <= 64" >/dev/null'
: > "$CALLS"
check "an unchanged delivery restarts nothing" \
  'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)")" && ! calls | grep -q "systemctl restart" && ! calls | grep -q "network create"'

echo "== periderm.workspace: reconcile =="
check "a second workspace (no preview yet) joins" \
  'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)" "$(ws pds_Second pv-$H2 null)")" && [[ -f "$AW_SYSTEMD_DIR/alwayswork-pdws-$H2.service" && ! -f "$AW_SYSTEMD_DIR/alwayswork-pdpv-$H2.service" && -f "$PS/vol-alwayswork-pdws-$H2" ]] && [[ "$(hb | jq "[.[] | select(.id | startswith(\"pv-\"))] | length")" == 1 ]]'
check "a workspace no longer delivered: unit, container, token file and volume removed" \
  'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)")" && [[ ! -f "$AW_SYSTEMD_DIR/alwayswork-pdws-$H2.service" && ! -f "$PS/ctr-alwayswork-pdws-$H2" && ! -f "$PS/vol-alwayswork-pdws-$H2" && ! -f "$AW_ETC/periderm/pdws-$H2.env" ]] && [[ -f "$WS" && -f "$PS/vol-alwayswork-pdws-$H1" ]]'
check "previewPort back to null: forwarder and surface go, workspace stays" \
  'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 null)")" && [[ ! -f "$PV" && ! -f "$PS/ctr-alwayswork-pdpv-$H1" && -f "$WS" ]] && [[ "$(hb | jq length)" == 0 ]]'
check "paused: stopped and the token file removed, volume kept" \
  'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173 true)")" && [[ ! -f "$WS" && ! -f "$PV" && ! -f "$ENVF" && -f "$PS/vol-alwayswork-pdws-$H1" ]]'
check "paused only: the proxy stops too" '[[ ! -f "$PX" && ! -f "$PS/ctr-alwayswork-periderm-proxy" ]]'
check "a token that does not open fails that workspace only" \
  '! apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)" "$(ws pds_Second pv-$H2 null false "$(printf -- "-----BEGIN AGE ENCRYPTED FILE-----\nBAD\n-----END AGE ENCRYPTED FILE-----")")")" && [[ -f "$WS" && -f "$PV" && ! -f "$AW_SYSTEMD_DIR/alwayswork-pdws-$H2.service" ]] && grep -q "could not decrypt" "$TMP/out"'
check "a bad previewSurface is refused (it names every resource)" \
  '! apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)" "$(ws pds_Evil "pv-../../x" null)")" && [[ -z "$(ls "$AW_SYSTEMD_DIR" | grep -v -e "$H1" -e periderm-proxy)" ]]'
check "no periderm field: everything goes, proxy and volumes included" \
  'apply "{\"state\":\"approved\",\"config\":{\"configVersion\":8}}" && [[ -z "$(ls "$AW_SYSTEMD_DIR")" && -z "$(ls "$PS" | grep -e ctr- -e vol-)" && -z "$(ls "$AW_ETC/periderm" 2>/dev/null)" ]] && [[ "$(hb | jq length)" == 0 ]]'

echo "== periderm.workspace: capability gate =="
yq -i '.capabilities.enabled = ["core","runtime.podman"]' "$AW_CONFIG"
rm -f "$PS"/net-*; : > "$CALLS"
check "capability disabled: a delivered workspace creates nothing" \
  'apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)")" && [[ -z "$(ls "$AW_SYSTEMD_DIR")" && -z "$(ls "$AW_ETC/periderm" 2>/dev/null)" ]] && ! calls | grep -q "^podman network create" && ! calls | grep -q "^age" && grep -q "not enabled" "$TMP/out"'
touch "$AW_SYSTEMD_DIR/alwayswork-pdws-$H1.service" "$PS/vol-alwayswork-pdws-$H1"
check "capability disabled: leftovers of an earlier enablement are removed" \
  'apply "{\"state\":\"approved\",\"config\":{\"configVersion\":9}}" && [[ ! -f "$WS" && ! -f "$PS/vol-alwayswork-pdws-$H1" ]]'
yq -i '.capabilities.enabled = ["core","runtime.podman","periderm.workspace"]' "$AW_CONFIG"
echo false > "$PS/net-periderm"
check "an existing periderm network that is not --internal is refused" \
  '! apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173)")" && [[ ! -f "$WS" ]] && grep -q "not --internal" "$TMP/out"'
rm -f "$PS"/net-*

echo "== periderm.workspace: firewall =="
: > "$CALLS"
check "firewall: DNS from both subnets, egress and metadata drop from periderm-egress only" \
  '( libs; pd_ensure_networks && pd_firewall_open ) >/dev/null 2>&1 && calls | grep -q "ufw allow from 10.90.0.0/24 to any port 53 proto udp" && calls | grep -q "ufw allow from 10.91.0.0/24 to any port 53 proto tcp" && calls | grep -q "ufw route allow from 10.91.0.0/24" && ! calls | grep -q "ufw route allow from 10.90.0.0/24" && calls | grep -q "ufw route insert 1 deny from 10.91.0.0/24 to 169.254.169.254"'
check "firewall: openings tracked and closed again" \
  'grep -q "^periderm.workspace deny:10.91.0.0/24>169.254.169.254 -$" "$AW_STATE/firewall.rules" && ( libs; pd_firewall_close ) >/dev/null 2>&1 && ! grep -q "^periderm.workspace" "$AW_STATE/firewall.rules" && calls | grep -q "ufw route delete deny from 10.91.0.0/24 to 169.254.169.254"'

echo "== periderm.workspace: control_apply_delivery =="
# A periderm failure is isolated: the version is still applied and recorded.
iso() {
  ( libs; source "$ROOT/lib/control.sh"
    cfg_set_str() { :; }; cfg_set_expr() { [[ "$1" != .control.appliedVersion ]] || echo "$2" > "$TMP/applied"; }
    tunnel_section_present() { return 1; }; control_apply_access() { :; }; upd_apply_from_delivery() { :; }
    obj_apply_from_delivery() { :; }; pkg_apply_from_delivery() { :; }; control_note_apply() { :; }
    control_apply_lockdown() { :; }; infra_apply_from_delivery() { :; }
    run() { [[ "$1" == "$AW_ROOT/bin/alwayswork" ]] && { echo apply >> "$TMP/order"; return 0; }; "$@"; }
    periderm_apply_from_delivery() { echo periderm >> "$TMP/order"; exit 1; }
    control_apply_delivery "$1" ) > "$TMP/out" 2>&1
}
rm -f "$TMP/applied" "$TMP/order"
check "a failing periderm step neither aborts nor un-acks the delivery, and runs after apply" \
  'iso "{\"state\":\"approved\",\"sequence\":11,\"config\":{\"configVersion\":11}}" && [[ "$(cat "$TMP/applied")" == 11 && "$(paste -sd, "$TMP/order")" == apply,periderm ]] && grep -q "periderm workspaces of version 11" "$TMP/out"'

echo "== periderm.workspace: real age =="
if [[ -n "$REAL_AGE" && -n "$REAL_KEYGEN" ]]; then
  rm -f "$AW_ETC/age.key"; "$REAL_KEYGEN" -o "$AW_ETC/age.key" 2>/dev/null; chmod 600 "$AW_ETC/age.key"
  pub="$(sed -n 's/^# public key: //p' "$AW_ETC/age.key")"
  sealed="$(printf '%s' "$TOKEN" | "$REAL_AGE" -a -r "$pub")"
  check "a token sealed to the node's age key is opened into the env file" \
    'PATH="$(dirname "$REAL_AGE"):$PATH" apply "$(delivery "$(ws pds_AbC-12_xyz pv-$H1 5173 false "$sealed")")" && grep -qx "PERIDERM_WORKSPACE_TOKEN=$TOKEN" "$ENVF" && ! grep -rq "$TOKEN" "$AW_SYSTEMD_DIR"'
else
  echo "  skip  age not installed (stub age covers the same path)"
fi

printf 'periderm.workspace: passed %d failed %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
