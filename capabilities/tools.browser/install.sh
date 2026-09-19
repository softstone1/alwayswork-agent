# alwayswork capability: tools.browser
# shellcheck disable=SC1090
source "${CAP_DIR}/browser.sh"
if ! have podman; then [[ "$DRY_RUN" == "1" ]] || die "tools.browser: podman not found; runtime.podman is a dependency"; fi
log "tools.browser: $(br_image) -> noVNC 127.0.0.1:$(br_port), CDP alwayswork-browser:9222"
wl_subvolume "$(br_profile)"
br_render_env
WL_PULL="$(cap_config pull)" WL_BUILD="$(cap_config build)" wl_ensure_image "$(br_image)" "$CAP_DIR"
br_apply_unit
wl_report_service "$BR_ID" "Agent browser" http 6080 "/vnc.html?autoconnect=1&resize=scale"
ok "agent browser ready: watch at 127.0.0.1:$(br_port)/vnc.html; harness uses BROWSER_CDP_URL=http://alwayswork-browser:9222"
