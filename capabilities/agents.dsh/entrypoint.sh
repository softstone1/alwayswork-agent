#!/usr/bin/env bash
# alwayswork-dsh entrypoint: serve the DeepSeek Harness web UI.
#
# The harness only binds 127.0.0.1 (upstream refuses 0.0.0.0 on purpose),
# and a published container port cannot reach a container's loopback. So the
# harness listens on loopback inside the container and the alwayswork gate
# (gate.mjs) listens on the container's own interface, authenticates each
# request — Cloudflare Access JWT, or a control-plane tenant session — mints
# the harness's own session cookie and proxies to it. From the node the
# exposure is unchanged: podman publishes that interface to 127.0.0.1:<port>
# on the host only, and the public path stays the Cloudflare Tunnel behind
# Access. DSH_TRUSTED_HOST is the hostname the tunnel publishes; the harness
# refuses other Host headers.
set -euo pipefail

: "${DSH_PORT:=3080}"
: "${DSH_TRUSTED_HOST:?set DSH_TRUSTED_HOST to the public hostname of the node}"
mkdir -p "${HOME}/.config" 2>/dev/null || true

# The web profile's HMR plugin needs node's --expose-internals, which cannot
# travel in NODE_OPTIONS; invoke the CLI script through node explicitly.
node --expose-internals "$(command -v dsh)" web --host 127.0.0.1 --port "${DSH_PORT}" --no-open --trusted-host "${DSH_TRUSTED_HOST}" "$@" &
dsh_pid=$!

# No interface (--network none) means nothing to gate; the harness is then
# reachable only from inside the container.
addr="$(hostname -i 2>/dev/null | cut -d' ' -f1 || true)"
if [[ -n "$addr" && "$addr" != 127.* ]]; then
  AW_GATE_BIND="$addr" node /usr/local/bin/alwayswork-gate &
  gate_pid=$!
else
  gate_pid=""
fi

# Exit when either process dies; systemd on the node restarts the unit.
wait -n
status=$?
kill "$dsh_pid" ${gate_pid:+"$gate_pid"} 2>/dev/null || true
exit "$status"
