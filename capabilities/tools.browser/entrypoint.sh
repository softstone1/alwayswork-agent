#!/usr/bin/env bash
# alwayswork-browser entrypoint: Xvfb -> window manager -> Chromium (CDP) -> x11vnc -> noVNC.
set -euo pipefail
: "${DISPLAY:=:99}" "${SCREEN:=1440x900x24}" "${CDP_PORT:=9222}" "${NOVNC_PORT:=6080}"
: "${BROWSER_START_URL:=about:blank}"

Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp -ac +extension RANDR >/tmp/xvfb.log 2>&1 &
for _ in $(seq 1 50); do [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ] && break; sleep 0.1; done
openbox >/tmp/openbox.log 2>&1 &

# CDP on all interfaces of the container namespace: the harness reaches it by
# container name over the node's podman network; nothing publishes it to the host.
chromium --no-sandbox --disable-dev-shm-usage --disable-gpu --no-first-run --no-default-browser-check \
  --user-data-dir=/profile --remote-debugging-address=0.0.0.0 --remote-debugging-port="$CDP_PORT" \
  --remote-allow-origins='*' --window-size="${SCREEN%x*}" --start-maximized \
  --disable-features=TranslateUI --lang=en-US "$BROWSER_START_URL" >/tmp/chromium.log 2>&1 &
chromium_pid=$!

x11vnc -display "$DISPLAY" -localhost -nopw -forever -shared -quiet -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
websockify --web /usr/share/novnc "0.0.0.0:${NOVNC_PORT}" localhost:5900 >/tmp/novnc.log 2>&1 &
novnc_pid=$!

echo "alwayswork-browser: CDP :${CDP_PORT}, noVNC :${NOVNC_PORT} (open /vnc.html?autoconnect=1&resize=scale)"
# Exit when Chromium or noVNC dies; the node's unit restarts the container.
wait -n "$chromium_pid" "$novnc_pid"
status=$?
kill "$chromium_pid" "$novnc_pid" 2>/dev/null || true
exit "$status"
