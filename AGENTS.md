# cachyOS-headless — Autonomous Agent Guidance

## Project Summary

CachyOS-based headless gaming streaming container. Runs Sway (wayland compositor), Steam, and Sunshine in Docker for Moonlight/NVIDIA Shield streaming. AMD GPU rendering via ROCm, VA-API encoding.

## Architecture

- **Base OS**: CachyOS (Arch-derivative) in Docker
- **GPU**: AMD RX 7900 XT series, virtual display via `amdgpu.virtual_display` kernel parameter
- **Compositor**: Sway (wlroots) with `WLR_BACKENDS=headless,libinput` multi-backend
- **Encoder**: Sunshine with VA-API (AMD AMF)
- **Input**: Sunshine uinput virtual devices via libinput backend; dummy uinput devices created before Sway startup to bootstrap libinput
- **Audio**: PipeWire with null-sink for streaming

## Key Files

| File | Purpose |
|------|---------|
| `Containerfile` | Docker build — CachyOS, Sway, Steam, Sunshine, mesa, vulkan-radeon, pipewire |
| `docker-compose.yml` | Privileged container + moonlight-web sidecar, Sunshine ports, shm_size |
| `.env` | GPU render node, resolution, timezone |
| `system_files/etc/sunshine/sunshine.conf` | `capture = kms`, VA-API encoder, AMD preset |
| `system_files/etc/sway/config` | WLR_BACKENDS=headless,libinput multi-backend config |
| `system_files/usr/local/bin/entrypoint.sh` | D-Bus → PipeWire → seatd → dummy-uinput → Sway → Steam → Sunshine |
| `system_files/usr/local/bin/dummy-uinput.py` | Pre-Sway dummy uinput devices for libinput bootstrap |
| `home-template/.config/sunshine/apps.json` | Steam + Desktop app definitions |

## Supply Chain (Gitea → GitHub Mirror)

- **Gitea origin** (`origin`): `http://192.168.50.11:3042/mkadrlik/cachyOS-headless`
- **GitHub mirror** (`github`): `https://github.com/mkadrlik/cachyOS-headless.git` (push-only, NO fetch refspec)
- Gitea is source of truth. GitHub is readonly replica. Never fetch/pull from GitHub.
- CI workflow pushes `git push github main --force --tags` — no merge.

## Deployment

Container runs on `big-chungus` (192.168.50.10). Host kernel parameter `amdgpu.virtual_display=desc:1920x1080` required.
