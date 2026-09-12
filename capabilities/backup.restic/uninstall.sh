# alwayswork capability: backup.restic (remove)
run systemctl disable --now alwayswork-backup.timer 2>/dev/null || true
run rm -f /etc/systemd/system/alwayswork-backup.service /etc/systemd/system/alwayswork-backup.timer
run rm -f /usr/local/bin/alwayswork-backup
run systemctl daemon-reload
cfg_set_expr '.backup.enabled' false
warn "removed the backup timer; existing restic snapshots are untouched"
