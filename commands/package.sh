# shellcheck shell=bash
# aw package — what the control plane delivered to this node (lib/packages.sh).

cmd_package() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list|status) pkg_status ;;
    reapply)
      require_root package "re-applies the delivered packages"
      cfg_require
      local f; f="$(pkg_desired_file)"
      [[ -f "$f" ]] || die "no packages have been delivered yet"
      PKG_FORCE=1 pkg_apply_from_delivery "$(jq -c '{packages: .}' "$f")"
      ;;
    -h|--help|help) cat <<'USAGE'
usage: aw package [list|reapply]
  list      the packages the control plane delivered and their state
  reapply   re-run every delivered package (after fixing a failure by hand)
Packages are approved and assigned in the console; the node only installs
what arrives in signed desired state (SYSTEM_SPEC §9).
USAGE
      ;;
    *) die "unknown subcommand: package $sub" ;;
  esac
}
