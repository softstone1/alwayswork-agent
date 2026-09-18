# alwayswork capability: agents.dsh
# The node's own agent web UI. It binds loopback only; the public name is
# published by the node's Cloudflare Tunnel and gated by Cloudflare Access.

# shellcheck disable=SC1090
source "${CAP_DIR}/ensure.sh"

# Zero-touch: when no dsh binary exists on the node, install the pinned
# DeepSeek Harness release (and node 22 LTS first) instead of dying. An
# already-present binary is used as-is. Set one explicitly with --dsh to
# override.
dsh_bin="$(ds_ensure_harness)"

# The account that runs agent work: explicit, then the recorded node account,
# then whoever owns the harness CLI - the natural owner of its sessions.
ds_user="$(cap_config user)"
[[ -n "$ds_user" ]] || ds_user="$(cfg_get '.agent.user' '')"
[[ -n "$ds_user" ]] || ds_user="$(stat -Lc %U "$dsh_bin" 2>/dev/null || true)"
[[ -n "$ds_user" ]] || die "set the account that runs agent work: aw config set .agent.user <user>"
id "$ds_user" >/dev/null 2>&1 || die "no such user: $ds_user"
