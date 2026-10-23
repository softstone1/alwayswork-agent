# alwayswork capability: periderm.verifier (remove)
# Running verifications stop and their scratch space goes. podman.socket is
# left as it is (other tools may use it); the network goes with AW_PURGE=1.
if have podman && [[ "$DRY_RUN" != "1" ]]; then
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep '^periderm-verifier-' \
    | while IFS= read -r c; do run podman rm -f "$c" >/dev/null 2>&1 || true; done
  [[ "${AW_PURGE:-0}" == "1" ]] && { run podman network rm -f "$PD_VERIFY_NET" >/dev/null 2>&1 || true; }
fi
run rm -rf "$(pd_trust_dir)/verify"
ok "periderm verifier removed"
