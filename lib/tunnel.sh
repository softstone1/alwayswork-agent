# shellcheck shell=bash
# alwayswork · Cloudflare Tunnel, delivered over signed desired-state.
#
# The control plane provisions the node's tunnel (tunnel + DNS) and hands the
# token to the agent inside a VERIFIED desired-state delivery, as a top-level
# "tunnel" object:
#
#   { "tunnel": { "token": "<cloudflared tunnel token>",
#                 "hostname": "<node-hostname>.<baseDomain>" } }
#
# The token is consumed ONLY from this signed channel — never from an
# unsigned source. It travels stdin -> secret store -> 0600 token file and is
# never placed on a command line, in a log line, or in a test fixture.
#
# Conflict rule (delivered wins): a verified delivered token always replaces
# the stored one, whether the stored value came from an earlier delivery or
# from the manual path. The manual `aw secrets set CLOUDFLARE_TUNNEL_TOKEN`
# is a fallback for nodes with no delivery yet; the moment a verified
# delivery carries a tunnel section, the delivered token takes over. This is
# deliberate: the control plane must be able to rotate tokens centrally, and
# a sticky local value would silently break rotation.
#
# Lifecycle: the agent reconciles the cloudflared service directly from the
# tunnel section (start on first receipt, restart on rotation) instead of
# going through the node's capability list, so a later delivery WITHOUT a
# tunnel section can never tear the tunnel down: absence of the section
# leaves existing tunnel state untouched. An explicit `"tunnel": null`
# (no tunnel provisioned, or the node opted out) is treated exactly like
# absence — a no-op. Teardown is only ever driven by explicit local operator
# action, never by a delivery.

tunnel_secret_key() { printf 'CLOUDFLARE_TUNNEL_TOKEN\n'; }
tunnel_state_file() { printf '%s\n' "$AW_STATE/tunnel.json"; }

# tunnel_section_present <delivery-json> — 0 when the delivery carries a
# tunnel object.
tunnel_section_present() {
  jq -e '.tunnel | type == "object"' >/dev/null 2>&1 <<<"$1"
}

# tunnel_managed — 0 when this node is tunnel-managed: a tunnel section was
# delivered before (state file), or the cloudflared unit exists (e.g. a
# manually installed tunnel). Only tunnel-managed nodes get agent-driven SSH
# lockdown; operator-managed nodes keep SSH as a bootstrap-time concern.
tunnel_managed() {
  [[ -f "$(tunnel_state_file)" ]] && return 0
  systemctl list-unit-files cloudflared.service >/dev/null 2>&1 && return 0
  return 1
}

# tunnel_apply_from_delivery <delivery-json> — store the delivered token and
# reconcile the cloudflared service. Returns:
#   0  applied (token stored or already current; service reconciled)
#   1  failure — the caller keeps the delivery unacked so the next tick retries
#   3  no tunnel section — existing tunnel state left alone
tunnel_apply_from_delivery() {
  local json="$1"
  tunnel_section_present "$json" || return 3
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would store the delivered tunnel token and reconcile cloudflared"
    return 0
  fi
  if [[ "$(sec_backend)" != "sops" ]]; then
    err "tunnel: no secret store (sops/age); refusing the delivered token — run: aw secrets init"
    return 1
  fi
  local token hostname
  token="$(jq -r '.tunnel.token // ""' <<<"$json" 2>/dev/null)"
  if [[ -z "$token" ]]; then
    err "tunnel: delivery carried an empty tunnel token; refusing"
    return 1
  fi
  hostname="$(jq -r '.tunnel.hostname // ""' <<<"$json" 2>/dev/null)"
  if [[ "$(sec_get "$(tunnel_secret_key)")" == "$token" ]]; then
    info "tunnel: delivered token already stored; reconciling service"
  else
    log "tunnel: storing the token delivered by the control plane (hostname: ${hostname:-unknown})"
    # Never on argv: the token travels stdin -> sec_set_stdin -> sops.
    printf '%s' "$token" | sec_set_stdin "$(tunnel_secret_key)" \
      || { err "tunnel: could not store the token"; return 1; }
  fi
  if [[ -n "$hostname" ]]; then
    # The public hostname the node is reachable as; also quiets the
    # capability's "no domain set" warning with the true value.
    cfg_set_str '.capabilities.config.access.tunnel.domain' "$hostname"
  fi
  # Reconcile the service directly from the signed section: start on first
  # receipt, restart on rotation (the capability detects the token change).
  # Deliberately not via the node's capability list — see the header.
  cap_install access.tunnel || { err "tunnel: cloudflared reconcile failed"; return 1; }
  # Record what the node is reachable as (informational, not a secret).
  ensure_dir "$AW_STATE"
  ( umask 077
    jq -n --arg h "$hostname" --argjson t "$(date +%s)" \
      '{hostname:$h, source:"control-plane", updated_at:$t}' > "$(tunnel_state_file)" )
  chmod 600 "$(tunnel_state_file)"
  ok "tunnel: cloudflared reconciled (token source: control-plane)"
  return 0
}
