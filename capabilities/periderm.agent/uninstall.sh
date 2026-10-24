# alwayswork capability: periderm.agent (remove)
# Harness containers go; their workspaces stay (they fall back to failing
# closed until the capability returns or the session moves to the broker).
local_hex=""
while IFS= read -r local_hex; do [[ -n "$local_hex" ]] && pd_remove_harness "$local_hex"; done < <(pd_present)
ok "periderm agent harness removed"
