# alwayswork capability: services.postgres (health)
# shellcheck disable=SC1090
source "${CAP_DIR}/postgres.sh"
systemctl is-active --quiet "$(pg_unit)" || die "$(pg_unit) is not active"
h="$(podman inspect --format '{{.State.Health.Status}}' "$(pg_container)" 2>/dev/null || echo unknown)"
[[ "$h" == "healthy" ]] || die "postgres container health: $h"
ok "postgres healthy on 127.0.0.1:$(pg_port)"
