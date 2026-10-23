# alwayswork capability: periderm.runtime (health)
for f in "$WL_UNIT_DIR"/alwayswork-pdapp-*-lb.service; do
  [[ -f "$f" ]] || continue
  systemctl is-active --quiet "$(basename "$f")" || die "$(basename "$f") is not active"
done
! pd_role_enabled "$PD_ROLE_VERIFIER" || die "$PD_ROLE_VERIFIER is enabled on the same node"
ok "periderm runtime ready"
