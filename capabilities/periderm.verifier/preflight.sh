# alwayswork capability: periderm.verifier (preflight)
# The verifier container gets the host podman socket — root on this host —
# so it never shares a node with workspaces, builds or production apps.
for r in "$PD_ROLE_WORKSPACE" "$PD_ROLE_BUILDER" "$PD_ROLE_RUNTIME"; do
  if pd_role_enabled "$r" || [[ "${_AW_CAP_DONE:-}" == *" $r "* ]]; then
    die "periderm.verifier: this node has $r; the verifier must run on a node with no other Periderm role"
  fi
done
