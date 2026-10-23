# alwayswork capability: periderm.runtime (preflight)
if pd_role_enabled "$PD_ROLE_VERIFIER" || [[ "${_AW_CAP_DONE:-}" == *" $PD_ROLE_VERIFIER "* ]]; then
  die "periderm.runtime: this node has $PD_ROLE_VERIFIER; the verifier runs alone (disable it first)"
fi
