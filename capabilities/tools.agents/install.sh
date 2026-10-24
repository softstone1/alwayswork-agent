# alwayswork capability: tools.agents
#
# The developer's agentic CLIs, per user, never on the system PATH as root.
# A CLI the developer already has (native installer, standalone build, npm)
# is left exactly as it is and reported with its version; only missing ones
# are installed, from the npm registry (npm verifies each tarball's
# integrity) into ~/.local, as the developer. Versions are pinned per tool
# with `aw enable tools.agents --version.<tool> <semver>`; default latest.
#
# Config: tools (space separated, default all four), version.<tool>.

declare -A TA_PKG=(
  [claude]="@anthropic-ai/claude-code"
  [codex]="@openai/codex"
  [opencode]="opencode-ai"
  [dsh]="@deepseek-ai/dsh"
  [gemini]="@google/gemini-cli"
)

user="$(desk_user)"
if [[ -z "$user" ]]; then
  warn "tools.agents: no developer user on this desk yet; nothing installed"
  return 0
fi
home="$(desk_user_home "$user")"
[[ -n "$home" && -d "$home" ]] || { warn "tools.agents: $user has no home directory"; return 0; }

want="$(cap_config tools 'claude codex opencode dsh')"
for name in $want; do
  pkg="${TA_PKG[$name]:-}"
  [[ -n "$pkg" ]] || { warn "tools.agents: unknown tool '$name' (known: ${!TA_PKG[*]})"; continue; }
  have_it="$(desk_agent_cli "$user" "$home" "$name")"
  if [[ -n "$have_it" ]]; then
    info "tools.agents: $name present ($(jq -r '.version // "version unknown"' <<<"$have_it"), $(jq -r '.source' <<<"$have_it")) — kept"
    continue
  fi
  ver="$(cap_config "version.$name" latest)"
  [[ "$ver" =~ ^(latest|next|[0-9][0-9A-Za-z.+-]*)$ ]] || { warn "tools.agents: refusing version '$ver' for $name"; continue; }
  if ! have npm; then
    log "tools.agents: installing npm for per-user CLIs"
    pkg_install npm
  fi
  log "tools.agents: installing $pkg@$ver for $user"
  run runuser -u "$user" -- env HOME="$home" npm install -g --prefix "$home/.local" --no-fund --no-audit --loglevel=error "$pkg@$ver" \
    || warn "tools.agents: $name did not install; the desk reports it missing"
done
# The software report is cached; refresh it so the console sees the change now.
rm -f "$AW_STATE/desk-software.json" 2>/dev/null || true
ok "tools.agents converged for $user"
