# shellcheck shell=bash
# aw status — node, runtime and capability status.

_cap_state_word() {
  local id="$1"
  cfg_exists && cap_is_enabled "$id" && echo enabled || echo disabled
}

cmd_status() {
  cfg_require
  if [[ "$JSON_OUT" == "1" ]]; then
    _status_json
    return 0
  fi

  section "AlwaysWork"
  kv "version" "$AW_VERSION"
  if cfg_exists; then
    kv "name"    "$(cfg_get '.name' "$(hostname)")"
    kv "profile" "$(cfg_get '.profile' foundation)"
    kv "config"  "$(cfg_file)"
  else
    kv "config"  "missing (run: aw init)"
  fi

  hw_report

  section "Runtime"
  kv "engine" "$(engine_get)"
  if cfg_exists; then kv "limits" "$(cfg_get '.limits.mode' auto)"; fi
  if engine_active; then kv "engine state" "active"; else kv "engine state" "inactive/absent"; fi

  section "Security"
  fw_status
  kv "secrets" "$(sec_backend)"
  if [[ "$(sec_backend)" == "sops" ]]; then
    if sec_exists; then kv "store" "present ($(sec_list | wc -l) keys)"; else kv "store" "not initialised"; fi
  fi

  section "Always-on"
  if cfg_bool '.always_on.enabled' true; then
    kv "policy" "enabled (headless 24/7)"
    kv "suspend" "$(systemctl is-enabled sleep.target 2>/dev/null || echo unknown)"
  else
    kv "policy" "disabled"
  fi

  section "Capabilities"
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    local status; status="$(_cap_state_word "$id")"
    printf '    %-24s %s\n' "$id" "$status" >&2
  done < <(cfg_list '.capabilities.enabled')

  if engine_present; then
    local containers; containers="$(engine_list 2>/dev/null || true)"
    if [[ -n "$containers" ]]; then
      section "Containers"
      printf '%s\n' "$containers" | while IFS= read -r line; do printf '    %s\n' "$line" >&2; done
    fi
  fi
}

_status_json() {
  local name profile engine mode
  name="$(cfg_get '.name' "$(hostname)")"
  profile="$(cfg_get '.profile' foundation)"
  engine="$(engine_get)"
  mode="$(cfg_get '.limits.mode' auto)"
  printf '{'
  printf '"version":"%s",' "$(json_escape "$AW_VERSION")"
  printf '"name":"%s",' "$(json_escape "$name")"
  printf '"profile":"%s",' "$(json_escape "$profile")"
  printf '"engine":"%s",' "$(json_escape "$engine")"
  printf '"limits":"%s",' "$(json_escape "$mode")"
  printf '"firewall":"%s",' "$(json_escape "$(fw_backend)")"
  printf '"secrets":"%s",' "$(json_escape "$(sec_backend)")"
  # The same typed object the agent sends on heartbeat (SYSTEM_SPEC §6).
  printf '"health":%s,' "$(control_health_json)"
  printf '"capabilities":['
  local id first=1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    (( first )) || printf ','
    printf '"%s"' "$(json_escape "$id")"
    first=0
  done < <(cfg_list '.capabilities.enabled')
  printf ']}\n'
}
