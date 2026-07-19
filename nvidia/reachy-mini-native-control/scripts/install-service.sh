#!/usr/bin/env bash
set -euo pipefail

VENV="${REACHY_MINI_VENV:-$HOME/.venvs/reachy-mini}"
DAEMON="$VENV/bin/reachy-mini-daemon"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$SERVICE_DIR/reachy-mini-daemon.service"
HEALTHCHECK="${XDG_DATA_HOME:-$HOME/.local/share}/dgx-spark-reachy/reachy-mini-healthcheck"
STOPPER="${XDG_DATA_HOME:-$HOME/.local/share}/dgx-spark-reachy/stop-reachy-mini"
PLUGIN_DIR="${REACHY_GST_PLUGIN_DIR:-/opt/gst-plugins-rs/lib/aarch64-linux-gnu}"

if [[ $(uname -m) != aarch64 ]] || [[ $(dpkg --print-architecture) != arm64 ]]; then
    echo "This installer targets DGX Spark ARM64." >&2
    exit 2
fi
if [[ ! -x $DAEMON ]]; then
    echo "Reachy Mini daemon not found at $DAEMON" >&2
    exit 3
fi
if [[ ! -c /dev/ttyACM0 ]] || [[ ! -c /dev/video0 ]]; then
    echo "Reachy serial or camera device is missing." >&2
    exit 4
fi
for group in dialout video; do
    if ! id -nG | tr ' ' '\n' | grep -Fxq "$group"; then
        echo "The current login is not in the $group group." >&2
        exit 5
    fi
done
if ! GST_PLUGIN_PATH="$PLUGIN_DIR${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}" \
    gst-inspect-1.0 webrtcsink >/dev/null 2>&1; then
    echo "GStreamer webrtcsink is unavailable; complete the ARM64 plugin step first." >&2
    exit 6
fi

install -d -m 0755 "$SERVICE_DIR" "$(dirname "$HEALTHCHECK")"
install -m 0755 "$(dirname "$0")/reachy-mini-healthcheck" "$HEALTHCHECK"
install -m 0755 "$(dirname "$0")/stop-reachy-mini" "$STOPPER"

sed \
    -e "s|@DAEMON@|$DAEMON|g" \
    -e "s|@HEALTHCHECK@|$HEALTHCHECK|g" \
    -e "s|@STOPPER@|$STOPPER|g" \
    -e "s|@PLUGIN_DIR@|$PLUGIN_DIR|g" \
    "$(dirname "$0")/reachy-mini-daemon.service.in" >"$SERVICE"
chmod 0644 "$SERVICE"
systemctl --user daemon-reload
systemd-analyze --user verify "$SERVICE"

echo "Installed $SERVICE"
echo "The service was not enabled or started. Review it with:"
echo "  systemctl --user cat reachy-mini-daemon.service"
