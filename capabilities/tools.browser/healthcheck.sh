# alwayswork capability: tools.browser (health)
# shellcheck disable=SC1090
source "${CAP_DIR}/browser.sh"
systemctl is-active --quiet "$(wl_unit_name "$BR_ID")" || die "$(wl_unit_name "$BR_ID") is not active"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$(br_port)/vnc.html" 2>/dev/null || true)"
[[ "$code" == "200" ]] || die "noVNC not answering on 127.0.0.1:$(br_port) ($code)"
ok "agent browser responding"
