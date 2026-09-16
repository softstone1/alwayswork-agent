# shellcheck shell=bash
# alwayswork · firewall helpers.
#
# Secure by default: inbound denied, outbound allowed. Capabilities may open
# specific ports; every opening is tracked so "disable" can close it again.

fw_backend() {
  if have ufw; then echo ufw
  elif have firewall-cmd; then echo firewalld
  elif have nft; then echo nft
  else echo none
  fi
}

fw_active() {
  case "$(fw_backend)" in
    ufw)       ufw status 2>/dev/null | grep -qi '^Status: active' ;;
    firewalld) firewall-cmd --state 2>/dev/null | grep -qi running ;;
    nft)       return 0 ;;
    *)         return 1 ;;
  esac
}

fw_rules_file() { printf '%s\n' "$AW_STATE/firewall.rules"; }

fw_rule_track() {
  local cap="$1" port="$2" proto="$3" f
  f="$(fw_rules_file)"
  ensure_dir "$AW_STATE"
  [[ "$DRY_RUN" == "1" ]] && { printf '    [dry-run] track %s %s/%s\n' "$cap" "$port" "$proto" >&2; return 0; }
  grep -qx -- "${cap} ${port} ${proto}" "$f" 2>/dev/null || printf '%s %s %s\n' "$cap" "$port" "$proto" >> "$f"
}

fw_rule_untrack() {
  local cap="$1" port="$2" proto="$3" f
  f="$(fw_rules_file)"
  [[ -f "$f" ]] || return 0
  run sed -i "\|^${cap} ${port} ${proto}$|d" "$f"
}

fw_ensure() {
  case "$(fw_backend)" in
    ufw)
      run ufw --force default deny incoming
      run ufw --force default allow outgoing
      run ufw --force enable
      ;;
    firewalld)
      run systemctl enable --now firewalld
      run firewall-cmd --permanent --set-default-zone=drop
      run firewall-cmd --reload
      ;;
    *)
      warn "no supported firewall backend found (install ufw)"
      return 1
      ;;
  esac
}

fw_allow_port() {
  local cap="$1" port="$2" proto="${3:-tcp}"
  case "$(fw_backend)" in
    ufw)       run ufw allow "${port}/${proto}" comment "alwayswork:${cap}" ;;
    firewalld) run firewall-cmd --permanent --add-port="${port}/${proto}"; run firewall-cmd --reload ;;
    *)         warn "cannot open ${port}/${proto}: no firewall backend"; return 1 ;;
  esac
  fw_rule_track "$cap" "$port" "$proto"
}

fw_close_port() {
  local cap="$1" port="$2" proto="${3:-tcp}"
  case "$(fw_backend)" in
    ufw)       run ufw delete allow "${port}/${proto}" ;;
    firewalld) run firewall-cmd --permanent --remove-port="${port}/${proto}"; run firewall-cmd --reload ;;
    *)         return 1 ;;
  esac
  fw_rule_untrack "$cap" "$port" "$proto"
}

fw_allow_iface() {
  local cap="$1" iface="$2"
  case "$(fw_backend)" in
    ufw) run ufw allow in on "$iface" comment "alwayswork:${cap}" ;;
    *)   warn "cannot allow interface ${iface}: no firewall backend"; return 1 ;;
  esac
  fw_rule_track "$cap" "iface:$iface" "-"
}

fw_close_iface() {
  local cap="$1" iface="$2"
  case "$(fw_backend)" in
    ufw) run ufw delete allow in on "$iface" ;;
    *)   warn "cannot close interface ${iface}: no firewall backend"; return 1 ;;
  esac
  fw_rule_untrack "$cap" "iface:$iface" "-"
}

# fw_allow_subnet_port CAP SUBNET PORT [PROTO] — open PORT only to sources
# inside SUBNET (CIDR notation). Narrower than fw_allow_port: for LAN-scoped
# services like SSH so a default-deny firewall does not leave them reachable
# from everywhere or reachable nowhere.
fw_allow_subnet_port() {
  local cap="$1" subnet="$2" port="$3" proto="${4:-tcp}"
  case "$(fw_backend)" in
    ufw) run ufw allow from "$subnet" to any port "$port" proto "$proto" comment "alwayswork:${cap}" ;;
    firewalld)
      run firewall-cmd --permanent \
        --add-rich-rule="rule family=ipv4 source address=$subnet port port=$port protocol=$proto accept"
      run firewall-cmd --reload ;;
    *) warn "cannot open ${port}/${proto} for ${subnet}: no firewall backend"; return 1 ;;
  esac
  fw_rule_track "$cap" "from:${subnet}:${port}" "$proto"
}

fw_close_subnet_port() {
  local cap="$1" subnet="$2" port="$3" proto="${4:-tcp}"
  case "$(fw_backend)" in
    ufw) run ufw delete allow from "$subnet" to any port "$port" proto "$proto" ;;
    firewalld)
      run firewall-cmd --permanent \
        --remove-rich-rule="rule family=ipv4 source address=$subnet port port=$port protocol=$proto accept"
      run firewall-cmd --reload ;;
    *) warn "cannot close ${port}/${proto} for ${subnet}: no firewall backend"; return 1 ;;
  esac
  fw_rule_untrack "$cap" "from:${subnet}:${port}" "$proto"
}

# fw_close_cap_subnet_ports CAP — close every subnet-scoped port rule tracked
# under CAP. Used when a LAN-scoped policy (e.g. hardening.ssh=lan) is
# replaced, so its narrow firewall opening does not linger.
fw_close_cap_subnet_ports() {
  local cap="$1" f _cap spec proto rest subnet port
  local -a pending=()
  f="$(fw_rules_file)"
  [[ -f "$f" ]] || return 0
  while read -r _cap spec proto; do
    [[ "$_cap" == "$cap" && "$spec" == from:* ]] || continue
    pending+=("$spec $proto")
  done <"$f"
  for spec in "${pending[@]:-}"; do
    [[ -n "$spec" ]] || continue
    proto="${spec##* }"; rest="${spec% *}"
    rest="${rest#from:}"            # <subnet>:<port>
    port="${rest##*:}"; subnet="${rest%:*}"
    fw_close_subnet_port "$cap" "$subnet" "$port" "$proto"
  done
}

fw_status() {
  local backend; backend="$(fw_backend)"
  kv "firewall" "$backend"
  if fw_active; then kv "state" "active (default deny inbound)"; else kv "state" "INACTIVE"; fi
  local f; f="$(fw_rules_file)"
  if [[ -f "$f" && -s "$f" ]]; then
    info "opened by capabilities:"
    while IFS= read -r line; do printf '      %s\n' "$line" >&2; done < "$f"
  fi
}

# Returns one issue per line (empty when clean) — used by doctor.
fw_audit() {
  fw_active || printf '%s\n' "firewall is not active (inbound is unfiltered)"
  case "$(fw_backend)" in
    ufw) ufw status 2>/dev/null | grep -qi 'Default: allow (incoming)' && printf '%s\n' "ufw default incoming policy is allow" ;;
  esac
}
