# shellcheck shell=bash
# aw desk — developer desk status and the local end of a terminal grant.

cmd_desk() {
  local sub="${1:-status}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    status)
      cfg_require
      section "Desk"
      kv "desk mode" "$(desk_mode && echo yes || echo "no (profile $(cfg_get '.profile' ''))")"
      kv "developer" "$(desk_user || true)"
      kv "organization" "$(cfg_get '.desk.organization' '—')"
      kv "cloudflare one" "$(desk_warp_json | jq -r 'if .installed then (.state // "unknown") else "not installed" end')"
      kv "terminal" "$(desk_terminal_json | jq -r 'if .open then "open until \((.until // 0) / 1000 | todate)" else "closed" end')"
      ;;
    software) cfg_require; desk_software_json | jq . ;;
    posture)  require_root desk; cfg_require; desk_posture_json | jq . ;;
    terminal-close)
      # The developer (or anyone with root at the desk) can always end a grant early.
      # The grant is vetoed on this desk: later deliveries of the same grant
      # are refused, so it stays closed until the operator opens a new one.
      require_root desk; cfg_require
      local gid; gid="$(jq -r '.grantId // ""' "$(desk_terminal_state)" 2>/dev/null || true)"
      [[ -n "$gid" ]] && printf '%s\n' "$gid" | aw_write "$AW_STATE/terminal-veto"
      desk_terminal_close "closed at the desk" ;;
    -h|--help) info "usage: aw desk <status|software|posture|terminal-close>" ;;
    *) die "usage: aw desk <status|software|posture|terminal-close>" ;;
  esac
}
