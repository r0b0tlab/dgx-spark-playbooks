#!/usr/bin/env bash
set -euo pipefail

VENV="${REACHY_MINI_VENV:-$HOME/.venvs/reachy-mini}"
DAEMON="$VENV/bin/reachy-mini-daemon"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$SERVICE_DIR/reachy-mini-daemon.service"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dgx-spark-reachy"
HEALTHCHECK="$DATA_DIR/reachy-mini-healthcheck"
STOPPER="$DATA_DIR/stop-reachy-mini"
PLUGIN_DIR="${REACHY_GST_PLUGIN_DIR:-/opt/gst-plugins-rs/lib/aarch64-linux-gnu/gstreamer-1.0}"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TEMPLATE="$SCRIPT_DIR/reachy-mini-daemon.service.in"
STAGE=$(mktemp -d)
COMMITTED=false
health_tmp=""
stop_tmp=""
service_tmp=""
TARGETS=("$HEALTHCHECK" "$STOPPER" "$SERVICE")

rollback() {
    if [[ $COMMITTED != true ]]; then
        for index in "${!TARGETS[@]}"; do
            target=${TARGETS[$index]}
            if [[ -e $STAGE/backup-$index ]]; then
                cp -a "$STAGE/backup-$index" "$target"
            else
                rm -f "$target"
            fi
        done
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    [[ -z $health_tmp ]] || rm -f "$health_tmp"
    [[ -z $stop_tmp ]] || rm -f "$stop_tmp"
    [[ -z $service_tmp ]] || rm -f "$service_tmp"
    rm -rf "$STAGE"
}
trap rollback EXIT

render_unit() {
    local output=$1 healthcheck=$2 stopper=$3
    python3 - "$TEMPLATE" "$output" "$DAEMON" "$healthcheck" "$stopper" "$PLUGIN_DIR" <<'PY'
from pathlib import Path
import sys

template, output, daemon, healthcheck, stopper, plugin_dir = sys.argv[1:]
text = Path(template).read_text()
for marker, value in {
    "@DAEMON@": daemon,
    "@HEALTHCHECK@": healthcheck,
    "@STOPPER@": stopper,
    "@PLUGIN_DIR@": plugin_dir,
}.items():
    text = text.replace(marker, value)
Path(output).write_text(text)
PY
}

if [[ $(uname -m) != aarch64 ]] || [[ $(dpkg --print-architecture) != arm64 ]]; then
    echo "This installer targets DGX Spark ARM64." >&2
    exit 2
fi
if [[ ! -x $DAEMON ]]; then
    echo "Reachy Mini daemon not found at $DAEMON" >&2
    exit 3
fi
for group in dialout video; do
    if ! id -nG | tr ' ' '\n' | grep -Fxq "$group"; then
        echo "The current login is not in the $group group." >&2
        exit 4
    fi
done
for element in webrtcsink webrtcsrc; do
    if ! GST_PLUGIN_PATH="$PLUGIN_DIR${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}" \
        gst-inspect-1.0 "$element" >/dev/null 2>&1; then
        echo "GStreamer $element is unavailable; complete the ARM64 plugin step first." >&2
        exit 5
    fi
done

install -m 0755 "$SCRIPT_DIR/reachy-mini-healthcheck" "$STAGE/reachy-mini-healthcheck"
install -m 0755 "$SCRIPT_DIR/stop-reachy-mini" "$STAGE/stop-reachy-mini"
render_unit "$STAGE/reachy-mini-daemon.service" \
    "$STAGE/reachy-mini-healthcheck" "$STAGE/stop-reachy-mini"
systemd-analyze --user verify "$STAGE/reachy-mini-daemon.service"

install -d -m 0755 "$SERVICE_DIR" "$DATA_DIR"
for index in "${!TARGETS[@]}"; do
    if [[ -e ${TARGETS[$index]} ]]; then
        cp -a "${TARGETS[$index]}" "$STAGE/backup-$index"
    fi
done

health_tmp=$(mktemp "$DATA_DIR/.reachy-mini-healthcheck.XXXXXX")
stop_tmp=$(mktemp "$DATA_DIR/.stop-reachy-mini.XXXXXX")
service_tmp=$(mktemp "$SERVICE_DIR/.reachy-mini-daemon.service.XXXXXX")
install -m 0755 "$SCRIPT_DIR/reachy-mini-healthcheck" "$health_tmp"
install -m 0755 "$SCRIPT_DIR/stop-reachy-mini" "$stop_tmp"
render_unit "$service_tmp" "$HEALTHCHECK" "$STOPPER"
chmod 0644 "$service_tmp"
mv -f "$health_tmp" "$HEALTHCHECK"
mv -f "$stop_tmp" "$STOPPER"
mv -f "$service_tmp" "$SERVICE"
systemctl --user daemon-reload
COMMITTED=true

echo "Installed $SERVICE"
echo "The service was not enabled or started. Review it with:"
echo "  systemctl --user cat reachy-mini-daemon.service"
