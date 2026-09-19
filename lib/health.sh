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

_health_unit_active() { have systemctl && systemctl is-active --quiet "$1" 2>/dev/null; }

control_health_json() {
  _HEALTH_ARGS=(); _HEALTH_FIELDS=""
  local v total avail used

  _health_str agentVersion "$AW_VERSION"
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
  _health_raw agent "$(jq -nc --arg k "$kind" --arg v "$v" \
    --argjson up "$(_health_bool _health_unit_active alwayswork-webui.service)" \
    '{kind:$k, up:$up} + (if $v == "" then {} else {version:$v} end)')"

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
  # Packages as installed (lib/packages.sh), digest included.
  local pk; pk="$(declare -F pkg_reports_json >/dev/null && pkg_reports_json || printf '[]')"
  [[ "$pk" != "[]" ]] && _health_raw packages "$pk"
  # Last update result (lib/updates.sh): what a rollout wave waits for.
  local upd; upd="$(declare -F upd_result_json >/dev/null && upd_result_json || printf null)"
  [[ "$upd" != "null" ]] && _health_raw update "$upd"

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
