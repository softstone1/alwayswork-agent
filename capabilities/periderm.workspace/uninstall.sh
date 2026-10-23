# alwayswork capability: periderm.workspace (remove)
# Every workspace, preview forwarder, token file and workspace volume goes:
# checkpoints live in the control plane, so nothing on the node is the only
# copy. The proxy and the firewall openings go too; the networks stay unless
# AW_PURGE=1.
pd_remove_all || return 1
pd_firewall_close
run rm -rf "$(pd_env_dir)"
if [[ "${AW_PURGE:-0}" == "1" ]] && have podman; then
  run podman network rm -f "$PD_NET" "$PD_NET_EGRESS" >/dev/null 2>&1 || true
fi
ok "periderm workspaces removed"
