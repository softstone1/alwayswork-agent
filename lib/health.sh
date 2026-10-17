# shellcheck shell=bash
# alwayswork · typed health heartbeat (docs/SYSTEM_SPEC.md §6).
#
# control_health_json prints the `health` object the agent sends on every
# heartbeat. Every field is optional: each probe is guarded so a missing tool
# or file simply omits the field, and the result is always valid JSON. The
# probes are cheap (/proc, /sys, df, systemctl is-active, one 2 s loopback
# curl); the one expensive input — the doctor score — comes from a cache that
# `aw doctor` writes and the agent tick refreshes at most hourly.

_HEALTH_ARGS=()
_HEALTH_FIELDS=""

# _health_str <field> <value>   — string, omitted when empty
# _health_num <field> <value>   — number, omitted unless numeric
# _health_raw <field> <json>    — pre-built JSON, omitted unless it parses
_health_str() {
  [[ -n "${2:-}" ]] || return 0
  _HEALTH_ARGS+=(--arg "$1" "$2"); _HEALTH_FIELDS+="$1:\$$1,"
}
_health_num() {
  [[ "${2:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 0
  _HEALTH_ARGS+=(--argjson "$1" "$2"); _HEALTH_FIELDS+="$1:\$$1,"
}
_health_raw() {
  [[ -n "${2:-}" ]] && jq -e . >/dev/null 2>&1 <<<"$2" || return 0
  _HEALTH_ARGS+=(--argjson "$1" "$2"); _HEALTH_FIELDS+="$1:\$$1,"
}
_health_bool() { if "$@"; then printf 'true'; else printf 'false'; fi; }

# Doctor cache: {score, at} written by `aw doctor` on every run (at = unix ms).
health_doctor_cache() { printf '%s\n' "$AW_STATE/doctor.json"; }

# health_doctor_record <score> — called by `aw doctor` after scoring.
health_doctor_record() {
  local score="$1" f; shift || true
  [[ "$score" =~ ^[0-9]+$ ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  f="$(health_doctor_cache)"
  ensure_dir "$AW_STATE" 2>/dev/null || return 0
  # Findings (FAIL/WARN lines) ride along, capped so the heartbeat stays small.
  printf '%s\n' "$@" | head -n 24 | cut -c1-200 | jq -R . | jq -s --argjson s "$score" --argjson at "$(( $(date +%s) * 1000 ))" \
    '{score:$s, at:$at, findings:(map(select(length > 0)))}' > "$f" 2>/dev/null \
    || warn "could not record doctor score"
}

health_doctor_refresh() {
  local f at now
  f="$(health_doctor_cache)"
  now="$(( $(date +%s) * 1000 ))"
  at="$(jq -r '.at // 0' "$f" 2>/dev/null || printf 0)"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  [[ $(( now - at )) -ge 3600000 ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ -x "$AW_ROOT/bin/alwayswork" ]] || return 0
  ASSUME_YES=1 NO_COLOR=1 "$AW_ROOT/bin/alwayswork" doctor >/dev/null 2>&1 </dev/null || true
}

# --- listener audit (issue #16, NETWORK_SECURITY N1) -------------------------
# A node accepts no inbound connections: everything it serves is reached
# through the outbound tunnel or published on 127.0.0.1. health.listeners
# names every socket that breaks that rule — TCP LISTEN / UDP bound sockets
# whose address is neither loopback nor inside the `alwayswork` podman
# network. Wildcard binds (0.0.0.0, ::, *) are exactly the exposure looked
# for, so they are reported.

# _health_v4_int <a.b.c.d> — the address as one integer, or fails.
_health_v4_int() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i n=0
  for i in 1 2 3 4; do
    (( 10#${BASH_REMATCH[i]} <= 255 )) || return 1
    n=$(( n * 256 + 10#${BASH_REMATCH[i]} ))
  done
  printf '%s' "$n"
}

# _health_v6_hex <addr> — the address as 32 lowercase hex digits, or fails.
# Accepts "::" compression and a trailing dotted quad (::ffff:1.2.3.4).
_health_v6_hex() {
  local a h t g out="" fill=0 hg=() tg=()
  a="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
  if [[ "$a" =~ ^(.*:)([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    local pre="${BASH_REMATCH[1]}" n
    n="$(_health_v4_int "${BASH_REMATCH[2]}")" || return 1
    a="${pre}$(printf '%x:%x' $(( n >> 16 )) $(( n & 65535 )))"
  fi
  [[ "$a" =~ ^[0-9a-f:]+$ && "$a" == *:* ]] || return 1
  if [[ "$a" == *::* ]]; then
    h="${a%%::*}"; t="${a#*::}"
    [[ "$t" != *::* ]] || return 1
    [[ -n "$h" ]] && IFS=: read -ra hg <<<"$h"
    [[ -n "$t" ]] && IFS=: read -ra tg <<<"$t"
    fill=$(( 8 - ${#hg[@]} - ${#tg[@]} ))
    (( fill >= 1 )) || return 1
  else
    IFS=: read -ra hg <<<"$a"
    (( ${#hg[@]} == 8 )) || return 1
  fi
  for g in "${hg[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+="$(printf '%04x' "0x$g")"; done
  while (( fill-- > 0 )); do out+="0000"; done
  for g in "${tg[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+="$(printf '%04x' "0x$g")"; done
  [[ ${#out} -eq 32 ]] || return 1
  printf '%s' "$out"
}

# _health_in_cidr <addr> <cidr> — 0 when addr lies inside cidr (same family).
_health_in_cidr() {
  local addr="$1" net="${2%/*}" bits="${2##*/}" a n
  [[ "$2" == */* && "$bits" =~ ^[0-9]+$ ]] || return 1
  if a="$(_health_v4_int "$addr")"; then
    n="$(_health_v4_int "$net")" || return 1
    (( bits <= 32 )) || return 1
    local mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (a & mask) == (n & mask) ))
    return
  fi
  a="$(_health_v6_hex "$addr")" || return 1
  n="$(_health_v6_hex "$net")" || return 1
  (( bits <= 128 )) || return 1
  local full=$(( bits / 4 )) rest=$(( bits % 4 ))
  [[ "${a:0:full}" == "${n:0:full}" ]] || return 1
  (( rest == 0 )) && return 0
  local m=$(( (0xF << (4 - rest)) & 0xF ))
  (( (0x${a:full:1} & m) == (0x${n:full:1} & m) ))
}

# _health_loopback <addr> — 127.0.0.0/8, ::1, and v4-mapped 127.x.
_health_loopback() {
  local a="$1"
  [[ "$a" =~ ^::[fF]{4}:([0-9.]+)$ ]] && a="${BASH_REMATCH[1]}"
  _health_in_cidr "$a" 127.0.0.0/8 && return 0
  [[ "$(_health_v6_hex "$a" 2>/dev/null)" == "00000000000000000000000000000001" ]]
}

# The `alwayswork` podman network's subnets (netavark `.subnets[].subnet`
# or CNI `ipam.ranges`), one per line. Nothing when podman or the network is
# absent. Under AW_TEST podman is only consulted when AW_TEST_PODMAN is set.
_health_container_subnets() {
  have podman || return 0
  [[ -z "${AW_TEST:-}" || -n "${AW_TEST_PODMAN:-}" ]] || return 0
  podman network inspect alwayswork 2>/dev/null \
    | jq -r '[.. | objects | .subnet? // empty | strings] | unique | .[]' 2>/dev/null || true
}

# Addresses of the private infrastructure interfaces, one per line; nothing
# for an interface that does not exist. A socket bound there is not an
# exposure:
#   awinfra0        a dummy interface holding a /32 from 10.255.0.0/16 that
#                   is routed only through the node's Cloudflare Tunnel
#                   (NETWORK_SECURITY N2 binds sshd there)
#   CloudflareWARP  the Cloudflare Mesh / Cloudflare One Client (WARP)
#                   interface, reachable only through Cloudflare policy
_HEALTH_PRIVATE_IFACES=(awinfra0 CloudflareWARP)
_health_mesh_addrs() {
  have ip || return 0
  local dev
  for dev in "${_HEALTH_PRIVATE_IFACES[@]}"; do
    ip -o addr show dev "$dev" 2>/dev/null \
      | awk '$3 == "inet" || $3 == "inet6" { sub(/\/.*/, "", $4); print $4 }' 2>/dev/null || true
  done
}

# _health_same_addr <a> <b> — equal addresses (IPv6 compared expanded).
_health_same_addr() {
  [[ "$1" == "$2" ]] && return 0
  local x y
  x="$(_health_v6_hex "$1")" && y="$(_health_v6_hex "$2")" && [[ "$x" == "$y" ]]
}

# health_listeners_json — the health.listeners array (max 32). Fails (prints
# nothing) when `ss` is unavailable, so the field is omitted, not [] .
health_listeners_json() {
  have ss || return 1
  local out
  out="$(ss -Htulnp 2>/dev/null)" || return 1
  local subnets mesh m; subnets="$(_health_container_subnets)"; mesh="$(_health_mesh_addrs)"
  local netid state local_ rest addr port proc s skip rows=""
  while read -r netid state _ _ local_ _ rest; do
    case "$netid:$state" in tcp:LISTEN|udp:UNCONN) ;; *) continue ;; esac
    port="${local_##*:}"; addr="${local_%:*}"
    [[ "$port" =~ ^[0-9]+$ && -n "$addr" ]] || continue
    addr="${addr#\[}"; addr="${addr%\]}"; addr="${addr%%\%*}"
    [[ -n "$addr" ]] || continue
    # The DHCP client's socket (udp 68) is a client, not a service.
    [[ "$netid" == udp && "$port" == 68 ]] && continue
    _health_loopback "$addr" && continue
    skip=0
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      if _health_in_cidr "$addr" "$s"; then skip=1; break; fi
    done <<<"$subnets"
    # Bound to an awinfra0 / CloudflareWARP address: reachable only through
    # the tunnel or Cloudflare policy. Wildcards never match an interface
    # address, so they stay reported.
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      if _health_same_addr "$addr" "$m"; then skip=1; break; fi
    done <<<"$mesh"
    (( skip )) && continue
    proc=""
    [[ "$rest" =~ users:\(\(\"([^\"]*)\" ]] && proc="${BASH_REMATCH[1]}"
    rows+="${netid}"$'\t'"${addr}"$'\t'"${port}"$'\t'"${proc}"$'\n'
  done <<<"$out"
  printf '%s' "$rows" | jq -Rsc '[split("\n")[] | select(length > 0) | split("\t")
      | {proto: .[0], addr: .[1], port: (.[2] | tonumber), process: (.[3] // "")}]
    | unique_by([.proto, .addr, .port]) | .[:32]'
}

# health_listener_lines < listeners-json — one "addr:port/proto (process)" per entry;
# IPv6 addresses are bracketed so the port reads unambiguously.
health_listener_lines() {
  jq -r '.[] | (if (.addr | test(":")) then "[" + .addr + "]" else .addr end)
    + ":" + (.port | tostring) + "/" + .proto + " (" + (if .process == "" then "unknown" else .process end) + ")"' 2>/dev/null
}

_health_unit_active() { have systemctl && systemctl is-active --quiet "$1" 2>/dev/null; }

control_health_json() {
  _HEALTH_ARGS=(); _HEALTH_FIELDS=""
  local v total avail used

  _health_str agentVersion "$AW_VERSION"
  _health_num updateProtocol 2
  local commit=""; [[ -f "$AW_ROOT/COMMIT" ]] && commit="$(tr -dc 'a-f0-9' < "$AW_ROOT/COMMIT" | head -c 40)"
  [[ "$commit" =~ ^[a-f0-9]{7,40}$ ]] && _health_str agentCommit "$commit"
  # Behind what the control plane ships (lib/updates.sh)? Shown as a badge.
  if declare -F upd_agent_behind >/dev/null && upd_agent_behind 2>/dev/null; then _health_raw agentOutdated true; fi
  _health_str os "$(hw_os_pretty 2>/dev/null || true)"
  _health_str kernel "$(uname -r 2>/dev/null || true)"
  _health_str arch "$(uname -m 2>/dev/null || true)"
  _health_num uptimeSec "$(cut -d. -f1 /proc/uptime 2>/dev/null || true)"
  _health_num load1 "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)"
  _health_num cpuCount "$(nproc 2>/dev/null || true)"

  total="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
  avail="$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
  _health_num memTotalMb "$total"
  if [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]]; then
    used=$(( total - avail )); _health_num memUsedMb "$used"
  fi

  _health_num diskRootTotalGb "$(df -BG --output=size / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
  _health_num diskRootUsedPct "$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"

  local zone
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$zone" ]] || continue
    v="$(cat "$zone" 2>/dev/null || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && _health_num tempC "$(( v / 1000 ))"
    break
  done

  local kind state
  kind="none"
  if cfg_exists; then
    case "$(cfg_get '.engine.runtime' none 2>/dev/null || true)" in
      docker) kind=docker ;; podman) kind=podman ;;
    esac
  fi
  state=inactive
  [[ "$kind" != "none" ]] && engine_active 2>/dev/null && state=active
  _health_raw engine "$(jq -nc --arg k "$kind" --arg s "$state" '{kind:$k, state:$s}')"

  kind=none; v=""
  if cfg_exists; then
    if cap_is_enabled agents.dsh 2>/dev/null; then
      kind=dsh
      # Cheaply known: the pinned/configured harness version, not a `dsh
      # --version` process spawn on every tick.
      v="$(cfg_get '.capabilities.config.agents.dsh.dsh_version' '' 2>/dev/null || true)"
      [[ -n "$v" ]] || v="$(sed -n 's/^DSH_NPM_VERSION_DEFAULT="\([^"]*\)".*/\1/p' "$AW_ROOT/capabilities/agents.dsh/ensure.sh" 2>/dev/null | head -1)"
    elif cap_is_enabled agents.opencode 2>/dev/null; then
      kind=opencode
    fi
  fi
  # Container mode runs the harness as alwayswork-dsh.service; the legacy
  # host install as alwayswork-webui.service. "up" is whichever exists.
  local agent_unit=alwayswork-webui.service
  { have systemctl && systemctl list-unit-files alwayswork-dsh.service 2>/dev/null | grep -q '^alwayswork-dsh.service'; } && agent_unit=alwayswork-dsh.service
  # Credential names the harness was given (values never leave the node).
  local creds='[]'
  [[ -s "$AW_STATE/dsh/credentials.json" ]] && creds="$(jq -c '.' "$AW_STATE/dsh/credentials.json" 2>/dev/null || printf '[]')"
  [[ "$creds" == \[* ]] || creds='[]'
  _health_raw agent "$(jq -nc --arg k "$kind" --arg v "$v" --argjson creds "$creds" \
    --argjson up "$(_health_bool _health_unit_active "$agent_unit")" \
    '{kind:$k, up:$up, credentials:$creds} + (if $v == "" then {} else {version:$v} end)')"

  if have systemctl; then
    _health_raw tunnelUp "$(_health_bool _health_unit_active cloudflared.service)"
  fi

  local port
  port="$(control_webui_json | jq -r '.port // empty' 2>/dev/null || true)"
  if [[ "$port" =~ ^[0-9]+$ ]] && have curl; then
    _health_raw webUiUp "$(_health_bool curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/")"
  fi

  if cfg_exists; then
    _health_str sshPolicy "$(cfg_get '.hardening.ssh' disabled 2>/dev/null || true)"
    _health_raw capabilities "$(cfg_list '.capabilities.enabled' 2>/dev/null | jq -R . 2>/dev/null | jq -sc . 2>/dev/null || true)"
  fi

  local cache; cache="$(health_doctor_cache)"
  if [[ -s "$cache" ]]; then
    _health_num doctorScore "$(jq -r '.score // empty' "$cache" 2>/dev/null || true)"
    _health_num doctorAt "$(jq -r '.at // empty' "$cache" 2>/dev/null || true)"
    _health_raw doctorFindings "$(jq -c '.findings // [] | .[:24]' "$cache" 2>/dev/null || true)"
  fi

  if have ip; then
    _health_str lanIp "$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
  fi

  # Sockets reachable from outside loopback and the container network
  # (omitted when ss is unavailable; [] when it ran and found none).
  local lsn; if lsn="$(health_listeners_json 2>/dev/null)"; then _health_raw listeners "$lsn"; fi

  _health_raw clockSynced "$(_health_bool control_clock_trusted)"
  # Inventory (capacity, not load): what this box is made of.
  _health_str cpuModel "$(hw_cpu_model 2>/dev/null | head -c 128)"
  _health_raw gpus "$(hw_gpus_json 2>/dev/null)"
  _health_str virt "$(hw_virt 2>/dev/null | head -c 32)"
  _health_num diskRootFreeGb "$(hw_free_disk_gb 2>/dev/null || true)"
  # What is installed: catalog apps, and every workload container with live usage.
  if cfg_exists; then
    _health_raw apps "$(cfg_list '.capabilities.apps' 2>/dev/null | jq -R . 2>/dev/null | jq -sc . 2>/dev/null || true)"
  fi
  local wl; wl="$(declare -F wl_workloads_json >/dev/null && wl_workloads_json || printf '[]')"
  [[ "$wl" != "[]" ]] && _health_raw workloads "$wl"
  # Workload images this node is behind on (channel moved): `aw update` applies them.
  local iu; iu="$(declare -F wl_image_updates_json >/dev/null && wl_image_updates_json 2>/dev/null || printf '[]')"
  [[ "$iu" == \[* && "$iu" != "[]" ]] && _health_raw imageUpdates "$iu"
  # Packages as installed (lib/packages.sh), digest included.
  local pk; pk="$(declare -F pkg_reports_json >/dev/null && pkg_reports_json || printf '[]')"
  [[ "$pk" != "[]" ]] && _health_raw packages "$pk"
  # Last update result (lib/updates.sh): what a rollout wave waits for.
  local upd; upd="$(declare -F upd_result_json >/dev/null && upd_result_json || printf null)"
  [[ "$upd" != "null" ]] && _health_raw update "$upd"
  # Operator SSH via Access for Infrastructure (lib/infra.sh): address,
  # sshd state and CA fingerprint only.
  declare -F infra_health_json >/dev/null && _health_raw infraAccess "$(infra_health_json 2>/dev/null)"

  # A field that jq rejects must be visible, not a silent empty heartbeat.
  local jqerr; jqerr="$(mktemp)"
  if ! jq -nc "${_HEALTH_ARGS[@]}" "{${_HEALTH_FIELDS%,}}" 2>"$jqerr"; then
    warn "health: could not assemble the report: $(head -c 300 "$jqerr" | tr '\n' ' ')"
    # Name the offending value so a report from the field is actionable.
    local i; for ((i = 0; i < ${#_HEALTH_ARGS[@]}; i += 3)); do
      [[ "${_HEALTH_ARGS[i]}" == "--argjson" ]] || continue
      if [[ "$(jq -c . <<<"${_HEALTH_ARGS[i + 2]}" 2>/dev/null | wc -l)" != "1" ]]; then warn "health: field ${_HEALTH_ARGS[i + 1]} is not one JSON value: $(printf '%s' "${_HEALTH_ARGS[i + 2]}" | head -c 200 | tr '\n' '|')"; fi
    done
    printf '{}'
  fi
  rm -f "$jqerr"
}
