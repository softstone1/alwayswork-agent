# alwayswork capability: runtime.docker (remove)
# Stop the daemon only if AlwaysWork started it: a docker the operator already
# ran (their own containers, CI runners) is theirs and stays up. The ledger
# recorded its state before we enabled it.
docker_was_ours() {
  local f; f="$(ledger_file 2>/dev/null)" || return 1
  [[ -s "$f" ]] || return 1
  jq -e -n '[inputs | select(.kind == "service" and .name == "docker.service")] | last | (.priorActive // false) == false and (.priorEnabled // false) == false' "$f" >/dev/null 2>&1
}
if declare -F ledger_file >/dev/null && ! docker_was_ours; then
  info "runtime.docker: docker was running before AlwaysWork; leaving the daemon as it is"
else
  warn "removing runtime.docker stops the docker daemon but keeps images and volumes"
  run systemctl disable --now docker 2>/dev/null || true
fi
