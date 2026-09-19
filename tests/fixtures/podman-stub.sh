#!/bin/sh
case "$1" in
  ps) cat <<'J'
[{"Names":["alwayswork-dsh"],"Image":"ghcr.io/softstone1/alwayswork-dsh:0.1.5-rc.2","State":"running","Status":"Up 3 hours (healthy)","Labels":{"alwayswork":"true","alwayswork.capability":"agents.dsh"},"StartedAt":1789800000},
 {"Names":["alwayswork-n8n"],"Image":"docker.io/n8nio/n8n:1.80.0","State":"exited","Status":"Exited (1) 5 minutes ago","Labels":{"alwayswork":"true","dev.alwayswork.package":"n8n"},"StartedAt":1789801000},
 {"Names":["alwayswork-postgres"],"Image":"docker.io/library/postgres:16","State":"running","Status":"Up 2 days (unhealthy)","Labels":{"alwayswork":"true","alwayswork.capability":"services.postgres"},"StartedAt":1789700000}]
J
  ;;
  stats) cat <<'J'
[{"Name":"alwayswork-dsh","CPU":12.3456,"MemUsage":734003200,"MemLimit":4294967296,"PIDs":41},
 {"Name":"alwayswork-postgres","CPUPerc":"0.75%","MemUsage":"120MB / 2GB","PIDS":"9"}]
J
  ;;
esac
