# alwayswork capability: agents.core

engine_present || die "agents.core needs a container runtime"

image="$(cap_config image)"
if [[ -z "$image" ]]; then
  image="ghcr.io/softstone1/alwayswork-agent:latest"
  warn "using placeholder image; set your own with: aw enable agents.core --image <ref>"
fi

ensure_dir /srv/alwayswork/agents/workspaces
ensure_dir /srv/alwayswork/agents/transcripts

aw_write /usr/local/bin/alwayswork-agent <<'SCRIPT'
#!/usr/bin/env bash
# Run one agent task in an isolated, hardened, ephemeral container.
set -euo pipefail
task_id="${1:?usage: alwayswork-agent <task-id> [cmd...]}"
shift
CFG=/etc/alwayswork/worker.yaml
image="$(yq -r '.capabilities.config["agents.core"].image // "ghcr.io/softstone1/alwayswork-agent:latest"' "$CFG")"
memory="$(yq -r '.limits.defaults.memory_mb // 2048' "$CFG")"
cpus="$(yq -r '.limits.defaults.cpu // 2' "$CFG")"
pids="$(yq -r '.limits.defaults.pids // 512' "$CFG")"
ws="/srv/alwayswork/agents/workspaces/$task_id"
mkdir -p "$ws" /srv/alwayswork/agents/transcripts
exec docker run --rm \
  --name "alwayswork-agent-$task_id" \
  --label alwayswork=true \
  --label alwayswork.capability=agents.core \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit "$pids" \
  --memory "${memory}m" \
  --cpus "$cpus" \
  --network bridge \
  -v "$ws:/work" \
  -w /work \
  "$image" "$@"
SCRIPT
run chmod +x /usr/local/bin/alwayswork-agent

aw_write /etc/systemd/system/alwayswork-agent@.service <<'UNIT'
[Unit]
Description=AlwaysWork agent task %i
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alwayswork-agent %i
TimeoutStartSec=infinity
UNIT
run systemctl daemon-reload
ok "agents.core scaffolding installed (runner: /usr/local/bin/alwayswork-agent)"
