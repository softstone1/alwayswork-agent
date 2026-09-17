# shellcheck shell=bash
# aw doctor — scored security and health audit.

_DOCTOR_PASS=0; _DOCTOR_FAIL=0; _DOCTOR_WARN=0
_dpass() { _DOCTOR_PASS=$(( _DOCTOR_PASS + 1 )); printf '    %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1" >&2; }
_dfail() { _DOCTOR_FAIL=$(( _DOCTOR_FAIL + 1 )); printf '    %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; [[ -n "${2:-}" ]] && printf '         -> %s\n' "$2" >&2; }
_dwarn() { _DOCTOR_WARN=$(( _DOCTOR_WARN + 1 )); printf '    %sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; [[ -n "${2:-}" ]] && printf '         -> %s\n' "$2" >&2; }

_container_socket_exposure() {
  local b; b="$(engine_bin)"
  [[ -n "$b" ]] || return 0
  local names
  names="$("$b" ps --filter "label=alwayswork=true" --format '{{.Names}}' 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if "$b" inspect "$n" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null | grep -q 'docker.sock'; then
      printf '%s\n' "$n"
    fi
  done <<< "$names"
}

cmd_doctor() {
  cfg_require
  section "AlwaysWork doctor"

  # --- firewall -------------------------------------------------------------
  if fw_active; then _dpass "firewall active (default deny inbound)"
  else _dfail "firewall is not active" "run: sudo aw apply  (or enable ufw)"; fi

  case "$(fw_backend)" in
    ufw)
      if ufw status 2>/dev/null | grep -qi 'Default: deny (incoming)'; then
        _dpass "ufw default incoming policy is deny"
      else
        _dwarn "ufw default incoming policy is not deny" "sudo ufw default deny incoming"
      fi ;;
  esac

  # --- ssh ------------------------------------------------------------------
  if systemctl is-enabled --quiet sshd 2>/dev/null; then
    _dwarn "sshd is enabled" "set hardening.ssh and re-run bootstrap, or bind SSH to Tailscale"
  else
    _dpass "sshd is disabled"
  fi

  # --- secrets --------------------------------------------------------------
  if [[ "$(sec_backend)" == "sops" ]]; then
    if sec_exists; then _dpass "encrypted secret store present"
    else _dwarn "secret store not initialised" "sudo aw secrets init"; fi
    local key perms
    key="$(sec_key_file)"
    if [[ -f "$key" ]]; then
      perms="$(stat -c '%a' "$key" 2>/dev/null || echo '?')"
      if [[ "$perms" == "600" ]]; then _dpass "age key permissions are 600"
      else _dfail "age key is mode $perms" "chmod 600 $key"; fi
    else
      _dwarn "no age key found" "sudo aw secrets init"
    fi
  else
    _dwarn "sops/age not installed" "install sops and age, then: sudo aw secrets init"
  fi

  # --- always-on ------------------------------------------------------------
  if cfg_bool '.always_on.enabled' true; then
    if [[ "$(systemctl is-enabled sleep.target 2>/dev/null || true)" == "masked" ]]; then
      _dpass "sleep/suspend masked (safe for 24/7 agents)"
    else
      _dfail "sleep.target is not masked" "run: sudo aw power apply"
    fi
  fi

  # --- storage / updates ----------------------------------------------------
  if hw_is_btrfs && have snapper; then _dpass "btrfs + snapper available (reversible updates)"
  else _dwarn "snapshots unavailable" "root fs is $(hw_root_fs); snapper present: $(have snapper && echo yes || echo no)"; fi

  local free_gb; free_gb="$(hw_free_disk_gb)"
  if [[ "${free_gb:-0}" =~ ^[0-9]+$ ]] && (( free_gb >= 10 )); then _dpass "disk free: ${free_gb} GiB"
  else _dwarn "low disk space: ${free_gb:-?} GiB free" "free space before running agents"; fi

  if have checkupdates; then
    local pending; pending="$(checkupdates 2>/dev/null | wc -l)"
    if (( pending > 0 )); then _dwarn "${pending} package update(s) pending" "run: sudo aw update"
    else _dpass "system is up to date"; fi
  elif distro_is_debian && have apt-get; then
    local pending
    pending="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
    if (( pending > 0 )); then _dwarn "${pending} package update(s) pending" "run: sudo aw update"
    else _dpass "system is up to date"; fi
  fi

  # --- container surface ----------------------------------------------------
  if engine_present; then
    _dpass "container engine '$(engine_get)' present"
    local exposed; exposed="$(_container_socket_exposure)"
    if [[ -z "$exposed" ]]; then _dpass "no worker container exposes the engine socket"
    else _dfail "worker containers mount the engine socket: ${exposed}" "remove the docker.sock mount"; fi
  else
    _dwarn "no container engine configured" "enable runtime.docker or runtime.podman when needed"
  fi

  if have arch-audit; then
    local vuln; vuln="$(arch-audit --quiet 2>/dev/null | wc -l)"
    if (( vuln > 0 )); then _dwarn "${vuln} known-vulnerable package(s)" "run: sudo aw update"
    else _dpass "no known vulnerable packages (arch-audit)"; fi
  fi

  # --- capabilities ---------------------------------------------------------
  local failing=0 id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if cap_have_hook "$id" healthcheck; then
      if cap_health "$id" >/dev/null 2>&1; then _dpass "capability ${id} healthy"
      else _dwarn "capability ${id} healthcheck failed" "aw logs not available; inspect the service"; failing=$(( failing + 1 )); fi
    fi
  done < <(cfg_list '.capabilities.enabled')

  section "Summary"
  local total score
  total=$(( _DOCTOR_PASS + _DOCTOR_FAIL + _DOCTOR_WARN ))
  (( total > 0 )) || total=1
  score=$(( _DOCTOR_PASS * 100 / total ))
  kv "passed" "$_DOCTOR_PASS"
  kv "warnings" "$_DOCTOR_WARN"
  kv "failed" "$_DOCTOR_FAIL"
  kv "score" "${score}%"

  if (( _DOCTOR_FAIL > 0 )); then
    err "doctor found $_DOCTOR_FAIL critical issue(s)"
    return 1
  fi
  ok "no critical issues"
}
