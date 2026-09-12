# anakut-worker capability: backup.restic (remove)
run systemctl disable --now anakut-worker-backup.timer 2>/dev/null || true
run rm -f /etc/systemd/system/anakut-worker-backup.service /etc/systemd/system/anakut-worker-backup.timer
run rm -f /usr/local/bin/anakut-worker-backup
run systemctl daemon-reload
cfg_set_expr '.backup.enabled' false
warn "removed the backup timer; existing restic snapshots are untouched"
