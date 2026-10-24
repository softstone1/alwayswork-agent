# alwayswork capability: periderm.agent
# Nothing to install on the host: harness containers come from desired state.
# Warns about the logins this node does not hold yet, so a session does not
# discover it at start.
have age || [[ "$DRY_RUN" == "1" ]] || warn "periderm.agent: age is not installed; workspace tokens cannot be opened"
if [[ "$DRY_RUN" != "1" ]]; then
  held=()
  for k in CLAUDE_CODE_OAUTH_TOKEN CODEX_AUTH_JSON OPENCODE_AUTH_JSON DEEPSEEK_API_KEY; do sec_has "$k" && held+=("$k"); done
  if (( ${#held[@]} == 0 )); then
    warn "periderm.agent: no CLI login in this node's secrets yet (e.g. CLAUDE_CODE_OAUTH_TOKEN from 'claude setup-token', set as a group secret)"
  else
    info "periderm.agent: logins held: ${held[*]}"
  fi
fi
ok "periderm agent harness ready (sessions arrive in desired state)"
