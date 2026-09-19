# alwayswork capability: tools.browser (remove) — the profile stays unless AW_PURGE=1.
# shellcheck disable=SC1090
source "${CAP_DIR}/browser.sh"
wl_remove_unit "$BR_ID"
wl_unreport_service "$BR_ID"
run rm -f "$(br_env_file)"
if [[ "${AW_PURGE:-0}" == "1" ]]; then run rm -rf "$(br_root)"; else info "tools.browser: kept $(br_profile) (AW_PURGE=1 removes it)"; fi
ok "agent browser removed"
