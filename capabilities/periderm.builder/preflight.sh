# alwayswork capability: periderm.builder (preflight)
# The verifier holds the host podman socket; it never shares a node.
if pd_role_enabled "$PD_ROLE_VERIFIER" || [[ "${_AW_CAP_DONE:-}" == *" $PD_ROLE_VERIFIER "* ]]; then
  die "periderm.builder: this node has $PD_ROLE_VERIFIER; the verifier runs alone (disable it first)"
fi
