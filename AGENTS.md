# AGENTS.md — CachyOS Headless Steam

## Project Identity

Headless gaming streaming server for AMD GPUs. Docker container running Sway (headless compositor) + Steam + Sunshine (Moonlight server). Intended for remote game streaming from a headless Linux server with no physical displays.

## Key Architecture Decisions

- **Display:** `WLR_BACKEND=headless` — Sway rendered on AMD GPU via auto-detected GLES2/Vulkan. No HDMI dongle, no vkms, no pixman.
- **Streaming:** Sunshine with `capture = wlr` (wlr-screencopy reads compositor DMA-BUFs directly).
- **Encoding:** VA-API hardware encoding on AMD (AV1/HEVC/H.264).
- **Audio:** PipeWire null-sink isolation (`sunshine-null`).
- **Container:** Privileged (needs `/dev/dri`, `/dev/input`, `/dev/uinput`, `/dev/snd`).

## Host Prerequisites (Critical)

### 1. AMD Virtual Display Kernel Parameter

**REQUIRED.** Without this, Sway's headless backend falls back to software rendering (llvmpipe) because wlroots cannot match a DRM device to the Vulkan physical device. This breaks DMA-BUF allocation and Sunshine produces unusable output.

**Setup:**
```bash
sudo grubby --update-kernel=ALL --args="amdgpu.virtual_display=desc:1920x1080"
sudo reboot
```

**Atomic systems (Fedora IoT, Bazzite):**
```bash
sudo rpm-ostree kargs --append="amdgpu.virtual_display=desc:1920x1080"
```

**Verification:**
```bash
cat /proc/cmdline | grep virtual_display
```

### 2. Docker with Compose V2

```bash
sudo dnf install docker docker-compose-v2
sudo systemctl enable --now docker
```

### 3. GPU driver availability

- `/dev/dri/renderD128` must exist and be accessible
- `vulkan-radeon` or `amdgpu-pro` on the host (container has its own drivers)

## Container Architecture

### Entry Point

`/usr/local/bin/entrypoint.sh` (bash) — starts this dependency chain:

```
D-Bus (session + system)
  → PipeWire + PipeWire-Pulse (audio null-sink)
  → seatd (DRM seat management)
  → Sway (WLR_BACKEND=headless, HEADLESS-1)
  → Steam (big picture mode, auto-retry on crash)
  → Sunshine (wlr capture, auto-restart on crash)
  → Keepalive loop (PIDs tracked in $PIDS, SIGTERM cascade)
```

### Sway config (`/etc/sway/config`)

- Uses `HEADLESS-1` output from headless backend
- Resolution/refresh rate set at runtime via `sed` in entrypoint
- `hide_cursor 0` — Sunshine needs cursor visible to capture it
- `focus_follows_mouse no` — Sunshine injects input via virtual pointer

### Sunshine config (`/etc/sunshine/sunshine.conf`)

- `capture = wlr` — uses wlr-screencopy
- `encoder = vaapi` — VA-API on AMD
- `adapter_name = /dev/dri/renderD128` — specific render node (configurable via `RENDER_NODE` env var)
- Resolution list covers common streaming targets (720p→4K, various ultrawides)
- Audio sink: `alsa_output.sunshine-null` (PipeWire null-sink)

### Apps (`apps.json`)

- **Steam:** `steam -tenfoot` (detached — auto-exit doesn't kill Sunshine)
- **Desktop:** `steam -bigpicture` (attached)

Output is empty string (`""`) — Sunshine auto-detects via wlr-screencopy; no hardcoded connector name needed.

## Port Mapping

| Port(s) | Protocol | Purpose |
|---------|----------|---------|
| 47984-47990 | TCP+UDP | Streaming + Web UI + discovery |
| 47998-48000 | TCP+UDP | Control + video/data streams |
| 48010 | TCP+UDP | RTSP handshake + gamestream data |
| 8080 | TCP | Moonlight Web (browser client) |
| 40000-40010 | UDP | Moonlight Web WebRTC media |

## Known Issues & Gotchas

### #1: amdgpu.virtual_display REQUIRED
Most common failure mode. Symptoms in `/tmp/sway.log`:
```
Software rendering detected
Could not match drm and vulkan device
Could not initialize EGL context
```

**Fix:** Add kernel parameter, reboot.

### #2: Black screen in Moonlight
Same root cause as #1 — software rendering means no DMA-BUFs. Sunshine starts but produces unusable capture.

### #3: GPU render node selection
Default is `renderD128` (first AMD GPU). With multi-GPU setups, verify which node corresponds to which card:
```bash
for r in /dev/dri/renderD*; do
    echo "$r -> $(cat /sys/class/drm/$(basename $r)/device/gpu_id 2>/dev/null || cat /sys/class/drm/$(basename $r)/device/device 2>/dev/null || echo 'unknown')"
done
```

### #4: Moonlight port error 111 (ECONNREFUSED)
Sunshine RTSP service not listening. Check #1 first, then verify container is running:
```bash
docker ps | grep cachyOS-headless
docker exec cachyOS-headless pidof sunshine
```

### #5: machine-id persistence
Machine-ID is persisted in the gamer home volume (`/home/gamer/.machine-id`). If the volume is deleted, Sunshine pairings are invalidated. Keep the volume or back up the machine-id.

### #6: Steam login persistence
Steam login is stored in the `gamer_home` Docker volume. First login requires Sunshine Web UI interaction (browse to `https://host:47990`, click Steam app).

### #7: Sunshine credentials
Set via `sunshine --creds` on first run using `SUNSHINE_USER`/`SUNSHINE_PASS` env vars. Stored in `~/.config/sunshine/credentials.json`.

### #8: Container startup time
Full startup (Sway → Steam → Sunshine) takes ~30-60 seconds. Steam retries 5 times with 15-second wait; on first run expect longer due to Steam client update.

## Debugging Workflow

```bash
# Check container health
docker ps -a | grep cachyOS

# Check Sway init
docker exec cachyOS-headless tail -50 /tmp/sway.log
# Good: "Renderer is AMD Radeon RX 7900 XTX (radeonsi, ...)"
# Bad:  "Software rendering detected"

# Check Sunshine status
docker exec cachyOS-headless tail -30 /tmp/sunshine.log
# Should show encoder detection (AV1/HEVC/H.264 found)

# Check Steam status
docker exec cachyOS-headless tail -20 /tmp/steam.log

# Check all ports
ss -tulnp | grep -E '479[0-9][0-9]|4801[0]|8080'

# Test Sunshine Web UI (returns 401 = alive)
curl -sk https://localhost:47990 | head -1
# Should return "401 Unauthorized" (needs auth) or "200 OK"

# Live process status
docker exec cachyOS-headless ps aux | grep -E 'sway|sunshine|steam|pipe'
```

## Common Commands

```bash
# Build and start
docker compose build --no-cache && docker compose up -d

# Stop
docker compose down

# Rebuild only container
docker compose build cachyOS-headless

# View logs
docker compose logs -f cachyOS-headless

# Exec into container
docker exec -it cachyOS-headless bash
```