# alwayswork capability: backup.restic (health)
repo="$(cap_config repository)"
[[ -n "$repo" ]] && systemctl is-enabled --quiet alwayswork-backup.timer
