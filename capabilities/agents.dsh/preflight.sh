# alwayswork capability: agents.dsh (preflight)
# Container mode needs podman with user namespaces; host mode needs the
# harness binary and an unprivileged account. Both bind loopback only.

# shellcheck disable=SC1090
source "${CAP_DIR}/ensure.sh"
# shellcheck disable=SC1090
source "${CAP_DIR}/container.sh"

if [[ "$(dsc_mode)" == "container" ]]; then
  if ! have podman; then
    if [[ "$DRY_RUN" == "1" ]]; then info "agents.dsh: dry-run — podman would be provided by runtime.podman"
    else die "agents.dsh: podman not found; runtime.podman is a dependency (or set --mode host)"; fi
  fi
  if [[ -r /proc/sys/user/max_user_namespaces && "$(cat /proc/sys/user/max_user_namespaces)" == "0" ]]; then
    die "agents.dsh: user namespaces are disabled on this kernel; set --mode host or enable them"
  fi
  dsc_port >/dev/null; dsc_host >/dev/null; dsc_image >/dev/null
  # Hooks are sourced inside a subshell function, so `return` ends the hook.
  return 0
fi

# --- legacy host mode -------------------------------------------------------
dsh_bin="$(ds_ensure_harness)"
ds_user="$(cap_config user)"
[[ -n "$ds_user" ]] || ds_user="$(cfg_get '.agent.user' '')"
[[ -n "$ds_user" ]] || ds_user="$(stat -Lc %U "$dsh_bin" 2>/dev/null || true)"
[[ -n "$ds_user" ]] || die "set the account that runs agent work: aw config set .agent.user <user>"
id "$ds_user" >/dev/null 2>&1 || die "no such user: $ds_user"
