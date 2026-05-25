# CachyOS Headless Steam

Headless gaming server: Steam Big Picture + Sunshine (Moonlight) streaming in Docker, running on CachyOS (Arch derivative). Sway compositor with `WLR_BACKEND=headless` renders on the AMD GPU via auto-detected GLES2/Vulkan, producing DMA-BUFs that Sunshine captures through wlr-screencopy for hardware-accelerated VA-API encoding.

No HDMI dummy plugs, no vkms, no pixman/SHM. Real GPU pixels from compositor to encoder.

## Architecture

```
Host (Linux, AMD GPU)
├── Kernel: amdgpu.virtual_display (creates DRM virtual connector)
├── Docker: cachyOS-headless (privileged container)
│   ├── Sway         — WLR_BACKEND=headless, renders on AMD GPU
│   ├── PipeWire     — audio via null-sink isolation
│   ├── Steam        — Big Picture Mode (-tenfoot)
│   └── Sunshine     — wlr capture + VA-API encode
└── Docker: moonlight-web (browser-based Moonlight client)
```

## Requirements

- Linux host with at least one AMD GPU (Radeon RX 6000/7000 series recommended)
- Docker with Compose V2
- Root/sudo access for kernel parameter setup

## ⚠️ Critical: Kernel Parameter (Required)

**Without this, Sway's headless backend cannot initialize GPU rendering properly.** wlroots fails to match the DRM and Vulkan devices, falling back to software rendering, and Sunshine's wlr-screencopy produces unusable buffers.

```bash
sudo grubby --update-kernel=ALL --args="amdgpu.virtual_display=desc:1920x1080"
```

Then **reboot**.

This creates a virtual DRM display connector (`card0-Virtual-1`) with a synthetic EDID. The Sway headless backend needs this to properly initialize its GLES2/Vulkan renderer against the real AMD GPU.

### Verify

```bash
cat /proc/cmdline | grep virtual_display
# Should show: ... amdgpu.virtual_display=desc:1920x1080

# After container starts, check Sway log:
docker exec cachyOS-headless cat /tmp/sway.log
# Should NOT show:
#   "Software rendering detected"
#   "Could not match drm and vulkan device"
# Expected:
#   "Renderer is AMD Radeon RX 7900 XTX (radeonsi, ...)"
#   "Output Virtual-1 (or HEADLESS-1) is using ..."
```

If you're on an Atomic/Fedora IoT/Bazzite system, use `rpm-ostree kargs` instead:

```bash
sudo rpm-ostree kargs --append="amdgpu.virtual_display=desc:1920x1080"
```

## Quick Start

### 1. Build and run

```bash
cd /path/to/cachyOS-headless
docker compose build --no-cache
docker compose up -d
```

### 2. Connect via Moonlight

| Service | URL | Description |
|---------|-----|-------------|
| Sunshine Web UI | `https://host-ip:47990` | Admin panel (default: admin/admin) |
| Moonlight Web | `http://host-ip:8080` | Browser-based Moonlight client |
| Moonlight App | Pair with `host-ip` | Native app (iOS, Android, PC) |

### 3. First-time Steam login

- Open the Sunshine Web UI and click "Steam" app
- Steam Big Picture will launch — complete login on the virtual display
- Games are persisted in `./games/` (bind mount to `/home/gamer/games`)

## Configuration

### Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | Container user UID |
| `PGID` | `1000` | Container user GID |
| `ENABLE_SUNSHINE` | `true` | Start Sunshine |
| `ENABLE_STEAM` | `true` | Start Steam |
| `RENDER_WIDTH` | `1920` | Virtual display width |
| `RENDER_HEIGHT` | `1080` | Virtual display height |
| `REFRESH_RATE` | `120` | Virtual display refresh rate |
| `RENDER_NODE` | `/dev/dri/renderD128` | AMD render node for VA-API |
| `SUNSHINE_USER` | `admin` | Sunshine UI username |
| `SUNSHINE_PASS` | `admin` | Sunshine UI password |

### Multi-GPU

If you have multiple AMD GPUs, only the first card (`card0`) gets the virtual display. To target a different GPU, change `RENDER_NODE` in `.env`:

```env
RENDER_NODE=/dev/dri/renderD129  # GPU 1 (second card)
```

Verify which render node corresponds to which GPU:

```bash
for d in /sys/class/drm/card*/device; do
    echo "$(basename $(dirname $d)): $(cat $d/vendor) $(cat $d/device)"
done
for r in /dev/dri/renderD*; do
    echo "$r -> $(readlink -f /sys/class/drm/$(basename $r)/device/device | xargs cat)"
done
```

## How It Works

### The Virtual Display Trick

`amdgpu.virtual_display=desc:1920x1080` tells the kernel DRM driver to create a synthetic display connector with a fake EDID. This gives Sway's headless backend a real DRM device it can match against the Vulkan physical device, enabling proper GPU rendering.

Without it:
- Sway starts, but wlroots can't find a matching DRM → Vulkan device pair
- Fallback: software rendering via llvmpipe
- DMA-BUFs are unusable for VA-API encoding
- Sunshine streams black frames or fails to start

### The Headless Backend

`WLR_BACKEND=headless` creates a virtual compositor output (`HEADLESS-1`) without needing a physical monitor. The renderer auto-detects the AMD GPU via GLES2/Vulkan, allocates DMA-BUFs, and wlr-screencopy passes real GPU pixel data to Sunshine.

```
Sway (WLR_BACKEND=headless)
  → AMD GPU (GLES2/Vulkan) renders pixels
  → DMA-BUF allocated in GPU memory
  → wlr-screencopy reads DMA-BUF
  → Sunshine VA-API encode (AV1/HEVC/H.264)
  → Moonlight client decodes and displays
```

### Audio Isolation

PipeWire's null-sink (`sunshine-null`) creates a virtual audio device. System audio routes to it, and Sunshine captures it for streaming. No physical audio hardware needed.

## Troubleshooting

### Moonlight cannot connect (error 111 / ECONNREFUSED)

**Cause:** Sunshine RTSP port (TCP 48010) is not listening, usually because Sway's renderer couldn't initialize.

**Check:**

```bash
docker exec cachyOS-headless tail -30 /tmp/sway.log
# Look for: "Software rendering detected" or "Could not match drm and vulkan device"
```

**Fix:** Ensure `amdgpu.virtual_display=desc:1920x1080` kernel parameter is set and host has been rebooted.

### Black screen / green screen in Moonlight

**Cause:** DMA-BUF path broken — Sway is rendering via software.

**Check:**

```bash
docker exec cachyOS-headless cat /tmp/sway.log | grep -i "software\|renderer\|vulkan"
```

**Fix:** Same as above — virtual display parameter is missing.

### Sunshine ports not accessible

```bash
ss -tlnp | grep 4798
ss -ulnp | grep 4801
```

All should show port 0.0.0.0:*. If missing, the container may not be running.

### Sway crashes on startup

```bash
docker logs cachyOS-headless
docker exec cachyOS-headless tail -50 /tmp/sway.log
```

Common causes: missing `/dev/dri` devices (check docker-compose.yml), no renderD128 permission.

## Container Lifecycle

- The container uses `init: false` and a custom `trap` handler in `entrypoint.sh` for clean signal handling
- Sunshine auto-restarts on crash (with throttle to prevent crash loops)
- Sway failing is fatal (logs the warning but keeps running)
- `docker compose down` stops both containers
- Moonlight pairings survive container rebuilds via persisted machine-id in the named volume

## Files

```
Containerfile                          # Docker image definition
docker-compose.yml                     # Service orchestration
.env                                   # Runtime configuration (gitignored)
system_files/
├── etc/
│   ├── sway/config                    # Sway compositor config
│   └── sunshine/sunshine.conf         # Sunshine streaming config
├── usr/
│   ├── local/bin/entrypoint.sh        # Container init script
│   └── share/sunshine/apps.json       # Default app list
home-template/
├── .config/sunshine/apps.json         # User app config
└── .steam/steam/config/
    └── libraryfolders.vdf              # Steam library paths
moonlight-web/
└── libopenh264/decoder.js              # OpenH264 WASM decoder
games/                                  # Game library (bind mount)
```

## Why Not Bazzite?

Bazzite is an immutable Fedora Atomic image — `rpm-ostree` for installs, `systemd` as PID 1, `/usr` read-only. Heavy, slow builds, hard to debug in Docker.

CachyOS is a standard Arch derivative — `pacman`, lean base, full control. The container is 100% self-contained; the host only needs Docker and the kernel parameter.

## Why Headless Backend (not vkms + pixman)

The `vkms` kernel module + pixman renderer path is a common alternative but hits a dead end: pixman renders in CPU memory (SHM), producing buffers that can't be directly consumed by VA-API GPU encoders. This forces an expensive GPU upload per frame.

The headless backend renders directly on the AMD GPU via Vulkan/GLES2, producing DMA-BUFs in GPU memory. Sunshine's wlr-screencopy reads these for zero-copy VA-API encode. No per-frame upload needed.