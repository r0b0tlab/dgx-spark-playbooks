# Native Reachy Mini Control on DGX Spark (proposal draft)

> Draft for NVIDIA/dgx-spark-playbooks issue #86. The native daemon and systemd
> lifecycle are validated. The official desktop-app ARM64 packaging and final
> upstream version pins remain in flight.

## Overview

This playbook runs Reachy Mini Lite directly on DGX Spark ARM64. It is the
ordinary robot-control path: native Python daemon, local API, camera/WebRTC,
Conversation app, and an opt-in user service. It complements the containerized
[Spark & Reachy Photo Booth](../reachy-photo-booth/).

The default service binds only to `127.0.0.1`, does not wake the robot at
startup, and puts it to sleep during a graceful stop.

## Status

Validated on DGX Spark (`aarch64`, Debian `arm64`) with:

- `reachy-mini==1.9.0`
- `reachy-mini-conversation-app==0.10.0`
- Python 3.12
- GStreamer 1.24.2
- `gst-plugins-rs` WebRTC plugin 0.14.5

In-flight upstream work:

- pollen-robotics/reachy-mini-desktop-app#137 — official Linux ARM64 application support
- pollen-robotics/reachy-mini-desktop-app#298 — existing `WebApp` mode repair; optional workaround, not an ARM64 package
- pollen-robotics/reachy-mini-desktop-app#297 — DoA endpoint regression
- pollen-robotics/reachy_mini#1280 — live backend readiness status
- pollen-robotics/reachy_mini#1281 — `HF_HOME` token persistence
- pollen-robotics/reachy_mini_conversation_app#504 — idempotent app stop

Do not copy the locally validated `site-packages` patches into a production
installation. This draft will replace the in-flight section with released
version pins before an upstream playbook PR.

The Reachy SDK maintainers deprecated the old bundled full web dashboard in
favor of the desktop app (reachy_mini#932 and #1264). This playbook will not
restore or depend on the local proof's `/v2/` dashboard mount. The supported UI
target is the official Reachy Mini Control application once ARM64 packaging is
available; the merged external-browser camera fallback remains applicable.

## Prerequisites

- NVIDIA DGX Spark running the official DGX OS
- Reachy Mini Lite connected by USB-C and powered on
- Python 3.12 and `uv`
- A new login after joining the `dialout` and `video` groups

Install native dependencies:

```bash
sudo apt update
sudo apt install -y \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-nice \
  gstreamer1.0-tools \
  libnice10 \
  libportaudio2 \
  python3-gi \
  python3-gi-cairo
sudo usermod -aG dialout,video "$USER"
```

Log out and back in before continuing. Verify access:

```bash
uname -m
dpkg --print-architecture
id
python3 - <<'PY'
from glob import glob

print("serial candidates:", glob("/dev/serial/by-id/*") or glob("/dev/ttyACM*"))
print("video candidates:", glob("/dev/video*"))
PY
```

Expected architecture values are `aarch64` and `arm64`.
The service intentionally leaves serial and camera identity selection to the
SDK's upstream discovery code rather than assuming `/dev/ttyACM0` or
`/dev/video0`. Confirm the selected devices in the first-start logs.

## Install the native Python environment

```bash
uv venv --python 3.12 "$HOME/.venvs/reachy-mini"
uv pip install --python "$HOME/.venvs/reachy-mini/bin/python" \
  "reachy-mini==1.9.0"
```

Verify the daemon CLI and safety flags:

```bash
"$HOME/.venvs/reachy-mini/bin/reachy-mini-daemon" --help
```

## Verify WebRTC

The daemon requires the GStreamer Rust WebRTC elements for its camera stream:

```bash
gst-inspect-1.0 webrtcsink
gst-inspect-1.0 webrtcsrc
```

DGX Spark ARM64 images may not provide these elements as distro packages. The
validated fallback builds `gst-plugin-webrtc` from the exact upstream 0.14.5
tag and installs it under `/opt/gst-plugins-rs`. That build procedure will be
added here only after its source commit and installer integrity checks are
frozen for the final playbook.

If installed under the validated prefix:

```bash
export GST_PLUGIN_PATH=/opt/gst-plugins-rs/lib/aarch64-linux-gnu/gstreamer-1.0
```

## Install the opt-in service

From this playbook directory:

```bash
bash scripts/install-service.sh
systemctl --user daemon-reload
```

Installation deliberately does not enable or start the service. Review it:

```bash
systemctl --user cat reachy-mini-daemon.service
```

Then start it explicitly:

```bash
systemctl --user start reachy-mini-daemon.service
bash scripts/reachy-mini-healthcheck
```

Enable login startup only if an automatically running, sleeping robot is the
intended behavior:

```bash
systemctl --user enable reachy-mini-daemon.service
```

## API and Conversation smoke tests

The daemon API remains loopback-only:

```bash
curl -fsS http://127.0.0.1:8000/api/daemon/status
curl -fsS http://127.0.0.1:8000/api/media/status
```

Install the Conversation app from the official Reachy Mini app catalog through
Reachy Mini Control or the daemon app API; it is not a PyPI package. Launch it
only after configuring the required application credentials.
Stop the app before stopping the service:

```bash
curl -fsS -X POST http://127.0.0.1:8000/api/apps/stop-current-app
systemctl --user stop reachy-mini-daemon.service
```

The final playbook will include the exact released ARM64 control-app package and
Conversation smoke sequence after the upstream changes are published.

## DGX Spark Control window rendering

A source-built ARM64 Reachy Mini Control binary can start normally while its
WebKitGTK content area remains uniformly gray or white. Confirm this specific
DGX Spark/NVIDIA DMA-BUF failure from the application log before applying a
workaround:

```text
KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied
Failed to create GBM buffer ... Permission denied
```

For that signature, disable only WebKitGTK's DMA-BUF renderer in the Control
application launcher:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 reachy-mini-control
```

This changes UI compositing only; it does not disable CUDA or daemon media.
Persist the variable in the packaged desktop launcher after confirming that the
connection UI renders. Also start a fresh graphical login after joining
`dialout` and `video`; group database membership alone does not update an
already-running desktop session.

## Troubleshooting

| Symptom | Check | Resolution |
| --- | --- | --- |
| Serial permission denied | `id`, daemon's selected serial path | Join `dialout`, then log in again |
| Camera permission denied | `id`, daemon's selected V4L2 path | Join `video`, then log in again |
| `webrtcsink` missing | `gst-inspect-1.0 webrtcsink` | Install the pinned ARM64 plugin build |
| Control window is blank and logs GBM/KMS permission failures | launch once with `WEBKIT_DISABLE_DMABUF_RENDERER=1` | Persist the variable in the Control launcher; do not apply it without the matching log signature |
| Port 8000 occupied | `ss -ltnp 'sport = :8000'` | Stop the stale daemon before starting systemd |
| Robot moves at login | inspect daemon flags | Keep the service disabled or retain `--no-wake-up-on-start` |
| API reachable from LAN | inspect `--fastapi-host` | Bind to `127.0.0.1`; do not expose the unauthenticated API |
| OAuth succeeds but apps remain logged out | inspect `HF_HOME` | Requires the fix tracked in reachy_mini#1281 |

## Rollback

```bash
systemctl --user disable --now reachy-mini-daemon.service
rm -f "$HOME/.config/systemd/user/reachy-mini-daemon.service"
systemctl --user daemon-reload
rm -rf "$HOME/.venvs/reachy-mini"
```

Disconnect the robot only after it is asleep and the daemon has stopped.
