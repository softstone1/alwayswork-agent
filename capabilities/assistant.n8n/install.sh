# anakut-worker capability: assistant.n8n

engine_present || die "assistant.n8n needs a container runtime"
sec_init
if ! sec_has N8N_ENCRYPTION_KEY; then
  sec_set N8N_ENCRYPTION_KEY "$(aw_random_hex)"
fi
key="$(sec_get N8N_ENCRYPTION_KEY)"
name="anakut-worker-n8n"
engine_rm "$name" 2>/dev/null || true
engine_pull "docker.n8n.io/n8nio/n8n:latest"
engine_run "$name" "docker.n8n.io/n8nio/n8n:latest" \
  -v "anakut-worker-n8n:/home/node/.n8n" \
  -p "127.0.0.1:5678:5678" \
  -e "N8N_ENCRYPTION_KEY=$key" \
  -e "N8N_PORT=5678" \
  -e "GENERIC_TIMEZONE=$(cfg_get '.timezone' UTC)"
ok "n8n on http://127.0.0.1:5678 (localhost only)"
