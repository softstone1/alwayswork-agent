# alwayswork capability: agents.dsh
systemctl is-active --quiet alwayswork-webui.service || die "alwayswork-webui.service is not active"

port="$(cap_config port)"
[[ -n "$port" ]] || port="$(cfg_get '.expose.webUi.port' 3080)"
port="${port:-3080}"

if have curl; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null || true)"
  case "$code" in
    ''|000) die "no HTTP response on 127.0.0.1:$port" ;;
    *)      ok "node web ui responding ($code)" ;;
  esac
else
  ok "node web ui service is active"
fi
