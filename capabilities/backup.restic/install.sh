# anakut-worker capability: backup.restic

log "backup.restic: installing restic"
run pacman -S --needed --noconfirm restic
sec_init

if ! sec_has RESTIC_PASSWORD; then
  sec_set RESTIC_PASSWORD "$(aw_random_hex)"
  info "generated a restic repository password (stored encrypted)"
  info "back it up safely: losing it means losing the backups"
fi

repo="$(cap_config repository)"
if [[ -z "$repo" ]]; then
  warn "no repository configured"
  info "set one with: aw enable backup.restic --repository s3:https://.../bucket"
fi

aw_write /usr/local/bin/anakut-worker-backup <<'SCRIPT'
#!/usr/bin/env bash
# Back up anakut-worker state with restic.
set -euo pipefail
AW=/usr/local/bin/anakut-worker
CFG=/etc/anakut-worker/worker.yaml
repo="$(yq -r '.backup.repository' "$CFG")"
if [[ -z "$repo" || "$repo" == "null" ]]; then
  echo "no backup.repository configured in $CFG" >&2
  exit 1
fi
export RESTIC_REPOSITORY="$repo"
export RESTIC_PASSWORD="$("$AW" secrets get RESTIC_PASSWORD)"
if ! restic snapshots >/dev/null 2>&1; then restic init; fi
exec restic backup /etc/anakut-worker /srv/anakut-worker /var/lib/anakut-worker "$@"
SCRIPT
run chmod +x /usr/local/bin/anakut-worker-backup

aw_write /etc/systemd/system/anakut-worker-backup.service <<'UNIT'
[Unit]
Description=Anakut Worker backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/anakut-worker-backup
UNIT
aw_write /etc/systemd/system/anakut-worker-backup.timer <<'UNIT'
[Unit]
Description=Run Anakut Worker backup daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
UNIT
run systemctl daemon-reload
cfg_set_expr '.backup.enabled' true

if [[ -n "$repo" ]]; then
  run systemctl enable --now anakut-worker-backup.timer
else
  info "timer created but not started until a repository is configured"
fi
ok "backup.restic ready"
