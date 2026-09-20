#!/usr/bin/env bash
# Host-free regression checks for reconciliation and systemd argument boundaries.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export AW_STATE="$TEST_DIR/state" AW_ETC="$TEST_DIR/etc" AW_ROOT="$ROOT" DRY_RUN=0
mkdir -p "$AW_STATE" "$AW_ETC"
source "$ROOT/lib/workload.sh"
[[ "$(wl_q '%n')" == '%%n' ]]
# Literal variable text must survive systemd expansion.
# shellcheck disable=SC2016
[[ "$(wl_q '$HOME')" == '"$$HOME"' ]]
[[ "$(wl_q $'a\nb')" == '"a\nb"' ]]
[[ "$(wl_q 'a\b')" == '"a\\b"' ]]
echo 'ok: systemd arguments preserve literal specifiers, variables and newlines'

source "$ROOT/lib/packages.sh"
ensure_dir() { mkdir -p "$1"; }
aw_write() { cat > "$1"; }
log() { :; }; warn() { :; }; info() { :; }; ok() { :; }; err() { :; }
run() { "$@"; }
pkg_capability_apply() { echo capability >> "$TEST_DIR/applied"; }
pkg_distro_apply() { echo distro >> "$TEST_DIR/applied"; }
mkdir -p "$(pkg_installed_dir)"
cap='{"name":"test","version":"1","digest":"sha256:one","kind":"capability","manifest":{}}'
pkg_install_one "$cap"
pkg_install_one "$cap"
[[ "$(wc -l < "$TEST_DIR/applied")" == 2 ]]
echo 'ok: unchanged capability packages are reapplied after configuration rebuild'
pkg_oci_apply() { echo unavailable >&2; return 1; }
pkg_record broken 1 sha256:one oci installed
pkg_install_one '{"name":"broken","version":"1","digest":"sha256:one","kind":"oci","manifest":{}}'
[[ "$(jq -r .state "$(pkg_installed_dir)/broken.json")" == failed ]]
echo 'ok: reassertion errors are reported instead of silently marked installed'
mkdir -p "$AW_STATE/services"
printf '%s' '{"id":"test-8080","workload":"test","name":"Friendly UI"}' > "$AW_STATE/services/test.json"
printf '%s' '{"id":"other","workload":"other","name":"test"}' > "$AW_STATE/services/other.json"
pkg_clear_surfaces test
[[ ! -f "$AW_STATE/services/test.json" && -f "$AW_STATE/services/other.json" ]]
echo 'ok: surface cleanup follows workload identity, not its display name'
sec_get() { printf '%s' "${TEST_SECRET:-}"; }
printf 'old=retained\n' > "$AW_ETC/pkg-test.env"
pkg_oci_render_env '{"name":"test","manifest":{"secrets":["TOKEN"]}}' && exit 1
[[ "$(cat "$AW_ETC/pkg-test.env")" == old=retained ]]
TEST_SECRET=$'secret\nINJECT=bad'
pkg_oci_render_env '{"name":"test","manifest":{"secrets":["TOKEN"]}}' && exit 1
[[ "$(cat "$AW_ETC/pkg-test.env")" == old=retained ]]
echo 'ok: missing and multiline credentials fail closed without replacing the env file'

source "$ROOT/commands/apply.sh"
require_root() { :; }; cfg_require() { :; }; cfg_need() { :; }; aw_state_init() { :; }
cfg_file() { echo test; }; cfg_bool() { return 1; }; power_apply() { :; }; aw_agent_reload_if_stale() { :; }
cfg_list() { [[ "$1" != .capabilities.enabled ]] || printf '%s\n' core services.keep; return 0; }
cap_resolve() { printf '%s\n' core runtime.podman services.keep; }
cap_install() { return 0; }; cap_is_enabled() { return 0; }; cfg_list_add() { :; }
cap_exists() { return 0; }; cap_meta() { [[ "$1" != services.* ]] || echo workload; return 0; }
cap_uninstall() { echo "$1" >> "$TEST_DIR/removed"; return "${FAIL_REMOVE:-0}"; }
printf '%s' '["core","runtime.podman","services.keep","services.remove"]' > "$AW_STATE/applied-capabilities.json"
FAIL_REMOVE=1
cmd_apply && exit 1
jq -e 'index("services.remove") != null' "$AW_STATE/applied-capabilities.json" >/dev/null
FAIL_REMOVE=0
cmd_apply
[[ "$(sort -u "$TEST_DIR/removed")" == services.remove ]]
jq -e 'index("services.remove") == null and index("runtime.podman") != null' "$AW_STATE/applied-capabilities.json" >/dev/null
echo 'ok: removals retry after failure, preserve dependencies, and commit only after success'

(
  source "$ROOT/lib/control.sh"
  die() { exit 7; }
  cfg_set_str() { touch "$TEST_DIR/early-mutation"; }
  cfg_set_expr() { touch "$TEST_DIR/early-mutation"; }
  control_apply_delivery '{"state":"approved","sequence":3,"config":{"configVersion":2}}'
) && exit 1
[[ ! -f "$TEST_DIR/early-mutation" ]]
echo 'ok: a mismatched delivery sequence is rejected before any configuration mutation'
