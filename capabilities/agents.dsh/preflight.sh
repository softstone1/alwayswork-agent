# alwayswork capability: agents.dsh
# The node's own agent web UI. It binds loopback only; the public name is
# published by the node's Cloudflare Tunnel and gated by Cloudflare Access.

# The harness CLI is a node script, so look beyond root's PATH: an operator
# installs it under their own home. Set one explicitly with --dsh to override.
ds_dsh_bin() {
  local candidate
  for candidate in "$(cap_config dsh)" "$(command -v dsh 2>/dev/null || true)" \
    /usr/local/bin/dsh /opt/*/dsh /home/*/.local/bin/dsh; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

dsh_bin="$(ds_dsh_bin || true)"
[[ -n "$dsh_bin" ]] || die "agents.dsh needs the DeepSeek Harness CLI: aw enable agents.dsh --dsh /path/to/dsh"

# The account that runs agent work: explicit, then the recorded node account,
# then whoever owns the harness CLI - the natural owner of its sessions.
ds_user="$(cap_config user)"
[[ -n "$ds_user" ]] || ds_user="$(cfg_get '.agent.user' '')"
[[ -n "$ds_user" ]] || ds_user="$(stat -Lc %U "$dsh_bin" 2>/dev/null || true)"
[[ -n "$ds_user" ]] || die "set the account that runs agent work: aw config set .agent.user <user>"
id "$ds_user" >/dev/null 2>&1 || die "no such user: $ds_user"
