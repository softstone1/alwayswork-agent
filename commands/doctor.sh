# shellcheck shell=bash
# aw doctor — scored security and health audit.

_DOCTOR_PASS=0; _DOCTOR_FAIL=0; _DOCTOR_WARN=0
# What failed or warned, for the heartbeat (health.doctorFindings): the
# console shows a score; this is why.
_DOCTOR_FINDINGS=()
_dpass() { _DOCTOR_PASS=$(( _DOCTOR_PASS + 1 )); printf '    %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1" >&2; }
_dfail() { _DOCTOR_FAIL=$(( _DOCTOR_FAIL + 1 )); _DOCTOR_FINDINGS+=("FAIL $1${2:+ — $2}"); printf '    %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; [[ -n "${2:-}" ]] && printf '         -> %s\n' "$2" >&2; }
_dwarn() { _DOCTOR_WARN=$(( _DOCTOR_WARN + 1 )); _DOCTOR_FINDINGS+=("WARN $1${2:+ — $2}"); printf '    %sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; [[ -n "${2:-}" ]] && printf '         -> %s\n' "$2" >&2; }

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
      # The default policy is printed only by `status verbose`; /etc/default/ufw
      # is the fallback when ufw cannot answer (e.g. doctor run without root).
      if ufw status verbose 2>/dev/null | grep -qi 'Default: deny (incoming)' \
        || grep -qE '^DEFAULT_INPUT_POLICY="?DROP"?' /etc/default/ufw 2>/dev/null; then
        _dpass "ufw default incoming policy is deny"
      else
        _dwarn "ufw default incoming policy is not deny" "sudo ufw default deny incoming"
      fi ;;
  esac

  # --- ssh ------------------------------------------------------------------
  local ssh_policy; ssh_policy="$(cfg_get '.hardening.ssh' disabled)"
  if systemctl is-enabled --quiet sshd 2>/dev/null; then
    if [[ "$ssh_policy" == "tunnel" ]] && ssh_loopback_only; then
      _dpass "sshd listens on loopback only (policy: tunnel)"
    elif [[ "$ssh_policy" == "tunnel" ]]; then
      _dwarn "sshd is enabled but not proven loopback-only (policy: tunnel)" "run: sudo aw apply, then check: ss -ltn sport = :22"
    else
      _dwarn "sshd is enabled" "set hardening.ssh and re-run bootstrap, or bind SSH to Tailscale"
    fi
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
    # checkupdates exits 2 when nothing is pending; under set -e -o pipefail
    # that would end doctor here, before the score is written.
    local pending; pending="$( (checkupdates 2>/dev/null || true) | wc -l)"
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

  # --- operator accounts ------------------------------------------------------
  # pam_faillock lockouts look like a changed password from the outside;
  # name them so a locked operator sees why in the console.
  if have faillock; then
    local u n deny
    deny="$( (grep -E '^deny' /etc/security/faillock.conf 2>/dev/null || true) | awk -F= '{print $2}' | tr -d ' ')"
    [[ "$deny" =~ ^[0-9]+$ ]] || deny=3
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      n="$(faillock --user "$u" 2>/dev/null | grep -c ' V$' || true)"
      if (( n >= deny )); then _dwarn "account $u is locked by pam_faillock ($n recent failures)" "faillock --user $u --reset  (or wait the unlock time)"; fi
    done < <(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /nologin|false/ {print $1}' /etc/passwd 2>/dev/null)
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
  # Cached for the heartbeat (health.doctorScore / doctorAt); the agent
  # refreshes it by re-running doctor at most hourly.
  health_doctor_record "$score" "${_DOCTOR_FINDINGS[@]}"

  if (( _DOCTOR_FAIL > 0 )); then
    err "doctor found $_DOCTOR_FAIL critical issue(s)"
    return 1
  fi
  ok "no critical issues"
}
