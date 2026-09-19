# alwayswork capability: agents.dsh (health)
# shellcheck disable=SC1090
source "${CAP_DIR}/ensure.sh"
# shellcheck disable=SC1090
source "${CAP_DIR}/container.sh"

unit="$DSH_UNIT"; [[ "$(dsc_mode)" == "host" ]] && unit="$DSH_LEGACY_UNIT"
systemctl is-active --quiet "$unit" || die "$unit is not active"
port="$(dsc_port)"

if have curl; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null || true)"
  case "$code" in
    ''|000) die "no HTTP response on 127.0.0.1:$port" ;;
    *)      ok "node web ui responding ($code)" ;;
  esac
else
  ok "node web ui service is active"
fi
