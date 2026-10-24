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

  # --- infra ssh (Access for Infrastructure) --------------------------------
  # With infraAccess, every sshd socket must sit on the awinfra0 /32: a
  # listener anywhere else (wildcard, LAN, even loopback) is a way in that
  # bypasses Access for Infrastructure.
  if declare -F infra_configured >/dev/null && infra_configured; then
    local infra_addr infra_l l infra_bad=0 infra_seen=0
    infra_addr="$(jq -r '.address // ""' "$(infra_state_file)" 2>/dev/null)"; infra_addr="${infra_addr%/32}"
    if infra_l="$(infra_sshd_listeners)"; then
      while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        if [[ "$l" == "$infra_addr:22" ]]; then infra_seen=1
        else infra_bad=1; _dfail "sshd listens on $l (infraAccess allows only $infra_addr:22 on $INFRA_IFACE)" "disable the distro sshd: hardening.ssh=disabled"; fi
      done <<<"$infra_l"
      if (( ! infra_bad && infra_seen )); then _dpass "sshd bound only to $INFRA_IFACE ($infra_addr:22)"
      elif (( ! infra_seen )); then _dfail "infra sshd is not listening on $infra_addr:22" "journalctl -u $INFRA_SSHD_UNIT"; fi
    else
      _dwarn "cannot verify the infra sshd binding (ss not found)" "install iproute2"
    fi
    # The last login refusal, in sshd's own words: a "Permission denied" at
    # the client says nothing about why (wrong CA, principal not listed,
    # account refused by PAM). Reported so the operator never needs a shell
    # to diagnose the one way in (live: contabo-use-1, 2026-10-17).
    if have journalctl; then
      local infra_deny
      infra_deny="$(journalctl -u "$INFRA_SSHD_UNIT" --since "-24h" -o cat --no-pager 2>/dev/null \
        | grep -E "Certificate invalid|not a listed principal|CA .* is not trusted|refusing|Invalid user|User .* not allowed|Failed publickey|Authentication refused|error:|fatal:" \
        | tail -n 1 | tr -cd '[:print:]' | cut -c1-140)"
      if [[ -n "$infra_deny" ]]; then _dwarn "infra sshd last refusal: $infra_deny" "check the Gateway SSH CA, principals and the user"
      fi
    fi
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
  if desk_mode; then
    _dpass "desk: power left to the desktop (sleep allowed)"
  elif cfg_bool '.always_on.enabled' true; then
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

  # --- listeners ------------------------------------------------------------
  # Nodes accept no inbound connections (tunnel out, publish on 127.0.0.1).
  # All exposed sockets are ONE finding, so an exposed node keeps a score that
  # still lets it take the update that fixes it. The list is kept short enough
  # that the recorded finding (cut at 200 chars) keeps its explanation:
  # 130 + ", +NN more" + the fixed text stays under 200 bytes.
  local lsn l list="" more=0
  if lsn="$(health_listeners_json 2>/dev/null)"; then
    if [[ "$lsn" == "[]" ]]; then _dpass "nothing listens outside loopback and the container network"
    else
      while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        if (( more == 0 && ${#list} + ${#l} <= 130 )); then list+="${list:+, }$l"; else more=$(( more + 1 )); fi
      done < <(health_listener_lines <<<"$lsn")
      (( more > 0 )) && list+=", +$more more"
      _dfail "listening on $list" "nodes accept no inbound connections"
    fi
  else
    _dwarn "listener audit unavailable (ss not found)" "install iproute2"
  fi

  if have arch-audit; then
    # arch-audit fetches the advisory feed: bounded, so a stalled network
    # (a VPN coming up, a captive portal) never hangs doctor.
    local audit rc=0 vuln; audit="$(timeout 30 arch-audit --quiet 2>/dev/null)" || rc=$?
    vuln="$(grep -c . <<<"$audit" || true)"
    if (( rc == 124 )); then _dwarn "arch-audit timed out (advisory feed unreachable)" "retried on the next doctor run"
    elif (( vuln > 0 )); then _dwarn "${vuln} known-vulnerable package(s)" "run: sudo aw update"
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

  # --- desk (lib/desk.sh) ----------------------------------------------------
  if desk_mode; then
    local dfinding
    while IFS= read -r dfinding; do [[ -n "$dfinding" ]] && _dwarn "desk: $dfinding"; done < <(desk_audit)
  fi

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
