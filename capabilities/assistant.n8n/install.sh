# alwayswork capability: assistant.n8n

engine_present || die "assistant.n8n needs a container runtime"
sec_init
if ! sec_has N8N_ENCRYPTION_KEY; then
  sec_set N8N_ENCRYPTION_KEY "$(aw_random_hex)"
fi
key="$(sec_get N8N_ENCRYPTION_KEY)"
name="alwayswork-n8n"
image="docker.n8n.io/n8nio/n8n:latest"
# Idempotent: adopt an existing container instead of destroying and re-pulling
# it on every reconcile. The encryption key is stable (generated once above),
# so an adopted container keeps working with its existing volume.
if engine_exists "$name"; then
  info "$name already present; adopting (not recreating)"
  engine_start "$name" 2>/dev/null || true
else
  engine_pull "$image"
  engine_run "$name" "$image" \
    -v "alwayswork-n8n:/home/node/.n8n" \
    -p "127.0.0.1:5678:5678" \
    -e "N8N_ENCRYPTION_KEY=$key" \
    -e "N8N_PORT=5678" \
    -e "GENERIC_TIMEZONE=$(cfg_get '.timezone' UTC)"
fi
ok "n8n on http://127.0.0.1:5678 (localhost only)"
