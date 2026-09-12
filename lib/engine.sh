# shellcheck shell=bash
# anakut-worker · container engine abstraction.
#
# Keeps the worker flexible: docker, podman, or nothing at all. Resource
# limits are tunable defaults (limits.mode: auto|fixed|off) and hardening
# can be dialled per box. The container socket is never exposed here.

engine_get()      { cfg_get '.engine.runtime' docker; }
engine_rootless() { cfg_bool '.engine.rootless' false; }

engine_bin() {
  case "$(engine_get)" in
    docker) echo docker ;;
    podman) echo podman ;;
    *)      echo "" ;;
  esac
}

engine_present() {
  local b; b="$(engine_bin)"
  [[ -n "$b" ]] && have "$b"
}

engine_active() {
  local b; b="$(engine_bin)"
  [[ -n "$b" ]] || return 1
  if [[ "$b" == "docker" ]]; then
    systemctl is-active --quiet docker 2>/dev/null || "$b" info >/dev/null 2>&1
  else
    "$b" info >/dev/null 2>&1
  fi
}

engine_compose_cmd() {
  case "$(engine_bin)" in
    docker) echo "docker compose" ;;
    podman) if have podman-compose; then echo "podman-compose"; else echo "podman compose"; fi ;;
    *)      echo "" ;;
  esac
}

engine_hardening_enabled() { cfg_bool '.hardening.container_hardening' true; }

# Populate the global AW_ENGINE_ARGS array with limits + hardening flags.
engine_build_args() {
  AW_ENGINE_ARGS=()
  AW_ENGINE_ARGS+=(--label "anakut-worker=true")
  [[ -n "${CAP_ID:-}" ]] && AW_ENGINE_ARGS+=(--label "anakut-worker.capability=${CAP_ID}")

  local mode; mode="$(cfg_get '.limits.mode' auto)"
  if [[ "$mode" != "off" ]]; then
    local cpu mem
    cpu="$(cfg_get '.limits.defaults.cpu' 2)"
    if [[ "$mode" == "fixed" ]]; then
      mem="$(cfg_get '.limits.defaults.memory_mb' 2048)"
    else
      mem="$(hw_limit_memory_mb)"
    fi
    AW_ENGINE_ARGS+=(--cpus "$cpu" --memory "${mem}m")
  fi

  if engine_hardening_enabled; then
    AW_ENGINE_ARGS+=(--cap-drop ALL --security-opt no-new-privileges:true)
    AW_ENGINE_ARGS+=(--pids-limit "$(cfg_get '.limits.defaults.pids' 512)")
  fi
}

engine_run() {
  local name="$1" image="$2"; shift 2
  local b; b="$(engine_bin)"
  [[ -n "$b" ]] || die "no container engine configured; enable runtime.docker or runtime.podman"
  engine_build_args
  run "$b" run --detach --restart unless-stopped --name "$name" "${AW_ENGINE_ARGS[@]}" "$image" "$@"
}

engine_run_once() {
  local name="$1" image="$2"; shift 2
  local b; b="$(engine_bin)"
  [[ -n "$b" ]] || die "no container engine configured"
  engine_build_args
  run "$b" run --rm --name "$name" "${AW_ENGINE_ARGS[@]}" "$image" "$@"
}

engine_exists() { local b; b="$(engine_bin)"; [[ -n "$b" ]] && "$b" inspect "$1" >/dev/null 2>&1; }
engine_rm()     { local b; b="$(engine_bin)"; [[ -n "$b" ]] && run "$b" rm -f "$1"; }
engine_logs()   { local b; b="$(engine_bin)"; [[ -n "$b" ]] && "$b" logs --tail 100 "$1"; }
engine_pull()   { local b; b="$(engine_bin)"; [[ -n "$b" ]] && run "$b" pull "$@"; }
engine_list()   { local b; b="$(engine_bin)"; [[ -n "$b" ]] && "$b" ps --filter "label=anakut-worker=true" --format '{{.Names}}\t{{.Image}}\t{{.Status}}'; }
