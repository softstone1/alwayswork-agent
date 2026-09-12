# anakut-worker capability: backup.restic (health)
repo="$(cap_config repository)"
[[ -n "$repo" ]] && systemctl is-enabled --quiet anakut-worker-backup.timer
