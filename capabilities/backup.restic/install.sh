# alwayswork capability: backup.restic

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

aw_write /usr/local/bin/alwayswork-backup <<'SCRIPT'
#!/usr/bin/env bash
# Back up alwayswork state with restic.
set -euo pipefail
AW=/usr/local/bin/alwayswork
CFG=/etc/alwayswork/worker.yaml
# Same key the capability stores via `aw enable backup.restic --repository`
# (.capabilities.config.backup.restic.repository): reading a different key
# here meant scheduled backups silently never ran.
repo="$(yq -r '.capabilities.config["backup.restic"].repository // ""' "$CFG")"
if [[ -z "$repo" || "$repo" == "null" ]]; then
  echo "no repository configured in $CFG (aw enable backup.restic --repository ...)" >&2
  exit 1
fi
export RESTIC_REPOSITORY="$repo"
# Never export the password into the process environment (readable via
# /proc/<pid>/environ): hand restic a 0600 temp file instead, and remove it
# on EXIT even if the backup fails. No `exec` below — exec would replace this
# shell before the EXIT trap could run.
password_file="$(umask 077; mktemp /tmp/alwayswork-restic-pw.XXXXXX)"
trap 'rm -f "$password_file"' EXIT
"$AW" secrets get RESTIC_PASSWORD >"$password_file"
export RESTIC_PASSWORD_FILE="$password_file"
if ! restic snapshots >/dev/null 2>&1; then restic init; fi
restic backup /etc/alwayswork /srv/alwayswork /var/lib/alwayswork "$@"
SCRIPT
run chmod +x /usr/local/bin/alwayswork-backup

aw_write /etc/systemd/system/alwayswork-backup.service <<'UNIT'
[Unit]
Description=AlwaysWork backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alwayswork-backup
UNIT
aw_write /etc/systemd/system/alwayswork-backup.timer <<'UNIT'
[Unit]
Description=Run AlwaysWork backup daily

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
  run systemctl enable --now alwayswork-backup.timer
else
  info "timer created but not started until a repository is configured"
fi
ok "backup.restic ready"
