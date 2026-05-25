#!/bin/bash
# SPDX-License-Identifier: MIT
# entrypoint.sh — CachyOS Headless Steam container
# Runs: D-Bus → PipeWire → seatd → Sway (headless+GPU) → Steam → Sunshine
#
# Key design: Sway uses WLR_BACKEND=headless — renders on the AMD GPU via
# auto-detected GLES2/Vulkan, allocates DMA-BUFs. wlr-screencopy returns
# real GPU pixel data for Sunshine VA-API encode. No vkms/pixman/SHM.
# ⚠️ Host kernel parameter amdgpu.virtual_display REQUIRED (see README).

set -o pipefail

# ── Signal handlers for clean shutdown ───────────────────────────
PIDS=()
cleanup() {
    echo "[entrypoint] Caught signal — shutting down..."
    for i in $(seq $((${#PIDS[@]} - 1)) -1 0); do
        PID="${PIDS[$i]}"
        if kill -0 "$PID" 2>/dev/null; then
            echo "[entrypoint]   Sending SIGTERM to PID $PID"
            kill -TERM "$PID" 2>/dev/null || true
        fi
    done
    WAITED=0
    while [ "$WAITED" -lt 10 ]; do
        ALIVE=0
        for PID in "${PIDS[@]}"; do
            kill -0 "$PID" 2>/dev/null && ALIVE=$((ALIVE + 1))
        done
        [ "$ALIVE" -eq 0 ] && break
        sleep 1
        WAITED=$((WAITED + 1))
    done
    for PID in "${PIDS[@]}"; do
        if kill -0 "$PID" 2>/dev/null; then
            echo "[entrypoint]   Force-killing PID $PID"
            kill -9 "$PID" 2>/dev/null || true
        fi
    done
    echo "[entrypoint] All processes stopped. Exiting."
    exit 0
}
trap cleanup TERM INT

# ── Defaults ──────────────────────────────────────────────────
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CONTAINER_USER="${CONTAINER_USER:-gamer}"
ENABLE_SUNSHINE="${ENABLE_SUNSHINE:-true}"
ENABLE_STEAM="${ENABLE_STEAM:-true}"
TZ="${TZ:-America/Chicago}"
LANG="${LANG:-en_US.UTF-8}"
PIPEWIRE_LATENCY="${PIPEWIRE_LATENCY:-256/48000}"
AUDIO_SINK="${AUDIO_SINK:-sunshine-null}"
SUNSHINE_ENCODER="${SUNSHINE_ENCODER:-vaapi}"
SUNSHINE_ADAPTER="${SUNSHINE_ADAPTER:-/dev/dri/renderD128}"
SUNSHINE_USER="${SUNSHINE_USER:-admin}"
SUNSHINE_PASS="${SUNSHINE_PASS:-admin}"
RENDER_WIDTH="${RENDER_WIDTH:-1920}"
RENDER_HEIGHT="${RENDER_HEIGHT:-1080}"
REFRESH_RATE="${REFRESH_RATE:-120}"
STEAM_ARGS="${STEAM_ARGS:--tenfoot}"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"

# AMD GPU render node for VA-API encoding
RENDER_NODE="${RENDER_NODE:-/dev/dri/renderD128}"

echo "[entrypoint] === CachyOS Headless Steam ==="
echo "[entrypoint] User: ${CONTAINER_USER} (${PUID}:${PGID})"
echo "[entrypoint] Sunshine: ${ENABLE_SUNSHINE} | Steam: ${ENABLE_STEAM}"
echo "[entrypoint] Render node: ${RENDER_NODE}"
echo "[entrypoint] Capture mode: gamescope wlr (AMD GPU DMA-BUF via wlr-screencopy)"

# ── 1. Configure timezone and locale ──────────────────────────
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
echo "${TZ}" > /etc/timezone 2>/dev/null || true
echo "[entrypoint] Timezone set to ${TZ}"

# ── 2. Set up runtime directory and permissions ────────────────
export XDG_RUNTIME_DIR="/run/user/${PUID}"
mkdir -p "${XDG_RUNTIME_DIR}"
chown "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}" 2>/dev/null || true
chmod 0700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true

mkdir -p "${XDG_RUNTIME_DIR}/pipewire"
chown "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}/pipewire" 2>/dev/null || true

mkdir -p "${XDG_RUNTIME_DIR}/pulse"
chown "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}/pulse" 2>/dev/null || true

mkdir -p "${XDG_RUNTIME_DIR}/dbus-1"
chown "${PUID}:${PGID}" "${XDG_RUNTIME_DIR}/dbus-1" 2>/dev/null || true

chown -R "${PUID}:${PGID}" "/home/${CONTAINER_USER}" 2>/dev/null || true

# ── 2a. Ensure game library directory exists ──────────────────
GAMES_DIR="/home/${CONTAINER_USER}/games"
mkdir -p "${GAMES_DIR}/steamapps"
chown -R "${PUID}:${PGID}" "${GAMES_DIR}" 2>/dev/null || true
echo "[entrypoint] Game library directory: ${GAMES_DIR}"

# ── 2b. Device permissions ────────────────────────────────────
if [ -c /dev/uinput ]; then
    chmod 0660 /dev/uinput 2>/dev/null || true
    chgrp input /dev/uinput 2>/dev/null || true
    echo "[entrypoint] /dev/uinput permissions set for Sunshine input injection"
fi

# ── 2b. Generate machine-id for D-Bus ────────────────────────
# Persist machine-id across container rebuilds to avoid breaking
# Sunshine pairings (machine-id is part of the pairing identity).
# Store in gamer home (named volume) so it survives rebuilds.
MACHINE_ID_FILE="/home/gamer/.machine-id"
if [ -f "${MACHINE_ID_FILE}" ]; then
    echo "[entrypoint] Restoring persisted machine-id..."
    cp "${MACHINE_ID_FILE}" /etc/machine-id
else
    echo "[entrypoint] Generating new /etc/machine-id for D-Bus..."
    rm -f /etc/machine-id /var/lib/dbus/machine-id
    dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || \
        tr -dc 'a-f0-9' </dev/urandom | head -c 32 > /etc/machine-id
    cp /etc/machine-id "${MACHINE_ID_FILE}"
fi
mkdir -p /var/lib/dbus
cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

# ── 3. Start D-Bus ───────────────────────────────────────────
echo "[entrypoint] Starting D-Bus..."
DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
export DBUS_SESSION_BUS_ADDRESS

# Session bus
sudo -u "${CONTAINER_USER}" env \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    HOME="/home/${CONTAINER_USER}" \
    dbus-daemon --session --address="${DBUS_SESSION_BUS_ADDRESS}" --nofork >/tmp/dbus-session.log 2>&1 &
DBUS_PID=$!
PIDS+=("$DBUS_PID")
echo "[entrypoint]   D-Bus session bus PID: ${DBUS_PID}"

# System bus
mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
    dbus-daemon --system --fork 2>/dev/null || \
        echo "[entrypoint]   WARNING: D-Bus system bus failed"
    echo "[entrypoint]   D-Bus system bus started"
fi

sleep 1
if [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
    echo "[entrypoint]   D-Bus session bus ready"
else
    echo "[entrypoint]   WARNING: D-Bus session bus socket not found"
fi

# ── 4. Verify GPU render node ─────────────────────────────
if [ ! -c "${RENDER_NODE}" ]; then
    echo "[entrypoint] WARNING: Render node ${RENDER_NODE} not found!"
    echo "[entrypoint] Available render nodes:"
    ls -la /dev/dri/renderD* 2>/dev/null || echo "  (none)"
fi

# ── 5. Copy home-template configs ────────────────────────────
if [ -d /home/template ]; then
    cp -a /home/template/. "/home/${CONTAINER_USER}/" 2>/dev/null || true
    chown -R "${PUID}:${PGID}" "/home/${CONTAINER_USER}" 2>/dev/null || true
    echo "[entrypoint] Home template configs copied"
fi

# ── 6. Generate Sunshine config from env vars ─────────────────
SUNSHINE_CONF="/etc/sunshine/sunshine.conf"
SUNSHINE_USER_CONF="/home/${CONTAINER_USER}/.config/sunshine/sunshine.conf"
if [ -f "${SUNSHINE_CONF}" ]; then
    echo "[entrypoint] Applying runtime Sunshine configuration"
    sed -i "s|^encoder = .*|encoder = ${SUNSHINE_ENCODER}|" "${SUNSHINE_CONF}" 2>/dev/null || true
    sed -i "s|^adapter_name = .*|adapter_name = ${SUNSHINE_ADAPTER}|" "${SUNSHINE_CONF}" 2>/dev/null || true
    mkdir -p "$(dirname "${SUNSHINE_USER_CONF}")"
    cp "${SUNSHINE_CONF}" "${SUNSHINE_USER_CONF}"
    chown "${PUID}:${PGID}" "${SUNSHINE_USER_CONF}"
fi

# ── 6b. Ensure Sunshine apps.json has correct output + command ────
# Sunshine regenerates apps.json from /usr/share/sunshine/apps.json on first run,
# which has empty commands and wrong output names (HDMI-A-3).
# Fix: merge correct values into whatever apps.json Sunshine generated.
SUNSHINE_APPS="/home/${CONTAINER_USER}/.config/sunshine/apps.json"
SUNSHINE_APPS_SYSTEM="/usr/share/sunshine/apps.json"

# Copy our system defaults (with correct output=Virtual-1 and commands) if user config doesn't exist yet
if [ ! -f "${SUNSHINE_APPS}" ]; then
    mkdir -p "$(dirname "${SUNSHINE_APPS}")"
    cp "${SUNSHINE_APPS_SYSTEM}" "${SUNSHINE_APPS}"
    chown "${PUID}:${PGID}" "${SUNSHINE_APPS}"
    echo "[entrypoint] Created apps.json from system defaults"
fi

# Force-fix output and command fields in existing apps.json (survives upgrades)
# With gamescope, output is auto-detected via wlr-screencopy — no hardcoded name needed.
python3 -c "
import json, sys
with open('${SUNSHINE_APPS}', 'r') as f:
    d = json.load(f)
changed = False
for app in d.get('apps', []):
    # Clear output: gamescope auto-detects — no hardcoded connector name
    if app.get('output', '') not in ('',):
        app['output'] = ''
        changed = True
    # Fix Steam command
    if 'Steam' in app.get('name', '') and app.get('command', '') == '':
        app['command'] = 'steam -tenfoot'
        changed = True
    # Fix Desktop command (gamescope standalone mode)
    if app.get('name', '') == 'Desktop' and app.get('command', '') == '':
        app['command'] = 'steam -bigpicture'
        changed = True
if changed:
    with open('${SUNSHINE_APPS}', 'w') as f:
        json.dump(d, f, indent=2)
    print('[entrypoint] Fixed apps.json: corrected output/command fields')
else:
    print('[entrypoint] apps.json: output/command fields OK')
" 2>/dev/null || echo "[entrypoint] WARNING: Could not fix apps.json"
chown "${PUID}:${PGID}" "${SUNSHINE_APPS}" 2>/dev/null || true

# ── 7. Set Sunshine credentials (first-run only) ──────────────
SUNSHINE_CREDS_DIR="/home/${CONTAINER_USER}/.config/sunshine"
mkdir -p "${SUNSHINE_CREDS_DIR}"
chown -R "${PUID}:${PGID}" "${SUNSHINE_CREDS_DIR}" 2>/dev/null || true
CRED_FILE="${SUNSHINE_CREDS_DIR}/credentials.json"
if [ "${ENABLE_SUNSHINE}" = "true" ] && [ ! -f "${CRED_FILE}" ]; then
    if command -v sunshine &> /dev/null; then
        sunshine --creds "${SUNSHINE_USER}" "${SUNSHINE_PASS}" 2>/dev/null || true
        echo "[entrypoint] Sunshine credentials created for '${SUNSHINE_USER}'"
    fi
fi

# ── 8. Configure PipeWire ─────────────────────────────────────
PIPEWIRE_CONF_DIR="/home/${CONTAINER_USER}/.config/pipewire/pipewire.conf.d"
mkdir -p "${PIPEWIRE_CONF_DIR}"
QUANTUM=$(echo "${PIPEWIRE_LATENCY}" | cut -d/ -f1)
RATE=$(echo "${PIPEWIRE_LATENCY}" | cut -d/ -f2)

cat > "${PIPEWIRE_CONF_DIR}/99-latency.conf" <<PWEOF
context.properties = {
    default.clock.quantum = ${QUANTUM}
    default.clock.rate = ${RATE}
}
PWEOF

cat > "${PIPEWIRE_CONF_DIR}/10-sunshine-null-sink.conf" <<PWEOF
context.modules = [
    {
        name = libpipewire-module-loopback
        args = {
            "capture.props" = {
                "node.name" = "sunshine-null"
                "media.class" = "Audio/Sink"
                "audio.position" = [ "FL" "FR" ]
                "node.description" = "Sunshine Null Sink"
                "monitor.channel-volumes" = true
            }
            "playback.props" = {
                "node.name" = "sunshine-null-monitor"
                "media.class" = "Audio/Source"
                "audio.position" = [ "FL" "FR" ]
                "node.description" = "Sunshine Monitor"
                "monitor.channel-volumes" = true
            }
        }
    }
]
PWEOF

chown -R "${PUID}:${PGID}" "/home/${CONTAINER_USER}/.config" 2>/dev/null || true
echo "[entrypoint] PipeWire configured: latency=${QUANTUM}/${RATE}, null-sink=sunshine-null"

# ── 9. Start PipeWire ──────────────────────────────────────
echo "[entrypoint] Starting PipeWire..."
sudo -u "${CONTAINER_USER}" env \
    XDG_RUNTIME_DIR="/run/user/${PUID}" \
    XDG_SESSION_TYPE=wayland \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
    PIPEWIRE_RUNTIME_DIR="/run/user/${PUID}/pipewire" \
    HOME="/home/${CONTAINER_USER}" \
    pipewire </dev/null >/tmp/pipewire.log 2>&1 &
PIPEWIRE_PID=$!
PIDS+=("$PIPEWIRE_PID")
echo "[entrypoint]   PipeWire PID: ${PIPEWIRE_PID}"
sleep 2

sudo -u "${CONTAINER_USER}" env \
    XDG_RUNTIME_DIR="/run/user/${PUID}" \
    HOME="/home/${CONTAINER_USER}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
    PIPEWIRE_RUNTIME_DIR="/run/user/${PUID}/pipewire" \
    pipewire-pulse </dev/null >/tmp/pipewire-pulse.log 2>&1 &
PIPEWIRE_PULSE_PID=$!
PIDS+=("$PIPEWIRE_PULSE_PID")
echo "[entrypoint]   PipeWire-Pulse PID: ${PIPEWIRE_PULSE_PID}"
sleep 1

echo "[entrypoint] PipeWire started"

# ── 10. Start seatd (DRM seat manager) ────────────────────────
# Not strictly needed for headless backend, but gamescope/games may need it
# for DRM render node access. Keep for compatibility.
seatd -g video &
SEATD_PID=$!
PIDS+=("$SEATD_PID")
echo "[entrypoint] seatd started (PID: ${SEATD_PID}, group: video)"
sleep 1

# ── 10b. Start Sway (headless backend + GPU rendering) ──────────
# Uses WLR_BACKEND=headless — creates a virtual compositor output without
# a physical monitor. Sway renders on the AMD GPU (auto-detected GLES2/Vulkan),
# allocates DMA-BUFs. wlr-screencopy returns real GPU pixel data — no
# pixman/SHM dead end.
#
# ⚠️ Host kernel parameter: amdgpu.virtual_display=desc:1920x1080 is REQUIRED.
#    Without it, wlroots can't match DRM and Vulkan devices, falling back to
#    software rendering (llvmpipe). Verify with: cat /proc/cmdline | grep virtual
#
# Key env vars:
#   WLR_BACKEND=headless: no DRM/CRTC needed
#   WLR_RENDERER: unset = auto-detect (Vulkan/GLES2 on AMD GPU)
echo "[entrypoint] Starting Sway headless+GPU (${RENDER_WIDTH}x${RENDER_HEIGHT}@${REFRESH_RATE}Hz)..."
echo "[entrypoint]   Backend: headless (no physical monitor needed — uses amdgpu.virtual_display)"
echo "[entrypoint]   Renderer: auto-detect (Vulkan/GLES2 on AMD GPU)"
echo "[entrypoint]   wlr-screencopy: returns GPU DMA-BUFs for Sunshine"

SWAY_ENV="
XDG_RUNTIME_DIR=/run/user/${PUID}
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=sway
XDG_SESSION_DESKTOP=sway
XDG_SESSION_CLASS=user
HOME=/home/${CONTAINER_USER}
DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}
PIPEWIRE_RUNTIME_DIR=/run/user/${PUID}/pipewire
LANG=${LANG}
WLR_BACKEND=headless
WLR_LIBINPUT_NO_DEVICES=1
SWAYSOCK=/run/user/${PUID}/sway-ipc.sock
"

# Update sway config with desired resolution
SWAY_CONF="/etc/sway/config"
if [ -f "${SWAY_CONF}" ]; then
    sed -i "s/mode [0-9x]*@[0-9]*Hz/mode ${RENDER_WIDTH}x${RENDER_HEIGHT}@${REFRESH_RATE}Hz/" "${SWAY_CONF}" 2>/dev/null || true
fi

sudo -u "${CONTAINER_USER}" env ${SWAY_ENV} \
    sway \
    -c /etc/sway/config \
    </dev/null >/tmp/sway.log 2>&1 &
SWAY_PID=$!
PIDS+=("$SWAY_PID")
echo "[entrypoint]   Sway PID: ${SWAY_PID}"

# ── 11. Wait for display to be ready ────────────────────────────
RETRIES=0
MAX_RETRIES=20
echo "[entrypoint] Waiting for display to be ready..."
while [ ${RETRIES} -lt ${MAX_RETRIES} ]; do
    if [ -S "/run/user/${PUID}/sway-ipc.sock" ]; then
        echo "[entrypoint] Display is ready!"
        export WAYLAND_DISPLAY=wayland-1
        echo "[entrypoint]   Using ${WAYLAND_DISPLAY}"
        break
    fi

    if [ -n "${SWAY_PID:-}" ]; then
        if ! kill -0 "${SWAY_PID}" 2>/dev/null; then
            echo "[entrypoint] WARNING: Sway process died! Log:"
            tail -30 /tmp/sway.log 2>/dev/null || echo "  (no log)"
            break
        fi
    fi

    RETRIES=$((RETRIES + 1))
    echo "[entrypoint]   ... waiting (${RETRIES}/${MAX_RETRIES})"
    sleep 1
done
if [ ${RETRIES} -ge ${MAX_RETRIES} ]; then
    echo "[entrypoint] WARNING: Display not ready after ${MAX_RETRIES}s — proceeding anyway"
    tail -30 /tmp/sway.log 2>/dev/null || echo "  (no log)"
fi

# ── 12. Start Steam ───────────────────────────────────────────
if [ "${ENABLE_STEAM}" = "true" ]; then
    echo "[entrypoint] Starting Steam on display ${WAYLAND_DISPLAY}..."

    steam_is_alive() {
        for comm in /proc/[0-9]*/comm; do
            if [ "$(cat "$comm" 2>/dev/null)" = "steam" ]; then
                return 0
            fi
        done
        return 1
    }

    STEAM_RETRIES=0
    STEAM_MAX_RETRIES=5
    while [ ${STEAM_RETRIES} -lt ${STEAM_MAX_RETRIES} ]; do
        if [ ${STEAM_RETRIES} -gt 0 ]; then
            for pid_dir in /proc/[0-9]*; do
                if [ "$(cat "$pid_dir/comm" 2>/dev/null)" = "steam" ]; then
                    kill "$(basename "$pid_dir")" 2>/dev/null || true
                fi
            done
            sleep 2
        fi

        sudo -u "${CONTAINER_USER}" env \
            XDG_RUNTIME_DIR="/run/user/${PUID}" \
            XDG_SESSION_TYPE=wayland \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
            DISPLAY=:0 \
            HOME="/home/${CONTAINER_USER}" \
            DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
            PIPEWIRE_RUNTIME_DIR="/run/user/${PUID}/pipewire" \
            ENABLE_GAMESCOPE_WSI=1 \
            LANG="${LANG}" \
            STEAM_USE_DYNAMIC_VK=1 \
            steam ${STEAM_ARGS} \
            </dev/null >>/tmp/steam.log 2>&1 &
        STEAM_PID=$!
        PIDS+=("$STEAM_PID")
        echo "[entrypoint]   Steam launched (attempt $((STEAM_RETRIES+1))/${STEAM_MAX_RETRIES}), PID: ${STEAM_PID}"

        sleep 15

        STEAM_STABLE=0
        STEAM_DEAD_COUNT=0
        while [ ${STEAM_STABLE} -lt 30 ] && [ ${STEAM_DEAD_COUNT} -lt 5 ]; do
            if steam_is_alive; then
                STEAM_DEAD_COUNT=0
            else
                STEAM_DEAD_COUNT=$((STEAM_DEAD_COUNT + 1))
            fi
            sleep 2
            STEAM_STABLE=$((STEAM_STABLE + 2))
        done

        if [ ${STEAM_DEAD_COUNT} -eq 0 ]; then
            echo "[entrypoint]   Steam is running and stable"
            break
        else
            STEAM_RETRIES=$((STEAM_RETRIES + 1))
            echo "[entrypoint]   Steam exited, retrying in 15s... (${STEAM_RETRIES}/${STEAM_MAX_RETRIES})"
            sleep 15
        fi
    done
    if [ ${STEAM_RETRIES} -eq ${STEAM_MAX_RETRIES} ]; then
        echo "[entrypoint] WARNING: Steam failed to start after ${STEAM_MAX_RETRIES} attempts"
        tail -20 /tmp/steam.log 2>/dev/null || echo "  (no log)"
    fi
fi

# ── 13. Start Sunshine ────────────────────────────────────────
# gamescope's wlr-screencopy exposes AMD GPU DMA-BUFs to Sunshine.
# No SHM buffers — real pixel data from Vulkan render target.
# Auto-restart in keepalive loop (step 14).
if [ "${ENABLE_SUNSHINE}" = "true" ]; then
    echo "[entrypoint] Starting Sunshine (capture=wlr, encoder=${SUNSHINE_ENCODER})..."
    sudo -u "${CONTAINER_USER}" env \
        XDG_RUNTIME_DIR="/run/user/${PUID}" \
        XDG_SESSION_TYPE=wayland \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
        DISPLAY=:0 \
        HOME="/home/${CONTAINER_USER}" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
        PIPEWIRE_RUNTIME_DIR="/run/user/${PUID}/pipewire" \
        sunshine </dev/null 2>&1 \
        | grep -v "Gtk-CRITICAL" \
        >/tmp/sunshine.log &
    SUNSHINE_PID=$!
    PIDS+=("$SUNSHINE_PID")
    sleep 2
fi

# ── 14. Keep container alive ───────────────────────────────────
echo ""
echo "[entrypoint] ╔════════════════════════════════════════════════╗"
echo "[entrypoint] ║  CachyOS Headless Steam — Running              ║"
echo "[entrypoint] ║  Sunshine Web UI:  https://localhost:47990        ║"
echo "[entrypoint] ║  Moonlight:        Pair with Sunshine for stream  ║"
echo "[entrypoint] ║  Capture mode:     wlr (headless+GPU DMA-BUF, VA-API)   ║"
echo "[entrypoint] ╚══════════════════════════════════════════════════╝"
echo ""
echo "[entrypoint] Tracked PIDs: ${PIDS[*]}"

while true; do
    sleep 30
    if [ -n "${SWAY_PID:-}" ] && ! kill -0 "${SWAY_PID}" 2>/dev/null; then
        echo "[entrypoint] WARNING: Sway process (${SWAY_PID:-unset}) is not running"
    fi
    # Auto-restart Sunshine if it crashes (with throttle to prevent crash loops)
    if [ "${ENABLE_SUNSHINE}" = "true" ]; then
        if [ -n "${SUNSHINE_PID:-}" ] && ! kill -0 "${SUNSHINE_PID}" 2>/dev/null; then
            NOW=$(date +%s)
            LAST_RESTART="${LAST_SUNSHINE_RESTART:-0}"
            ELAPSED=$((NOW - LAST_RESTART))
            if [ "${ELAPSED}" -lt 10 ]; then
                echo "[entrypoint] Sunshine crashed within ${ELAPSED}s of last restart, waiting 60s before retry..."
                sleep 60
            fi
            echo "[entrypoint] Sunshine (PID ${SUNSHINE_PID}) died, restarting..."
            sudo -u "${CONTAINER_USER}" env \
                XDG_RUNTIME_DIR="/run/user/${PUID}" \
                XDG_SESSION_TYPE=wayland \
                WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
                DISPLAY=:0 \
                HOME="/home/${CONTAINER_USER}" \
                DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
                PIPEWIRE_RUNTIME_DIR="/run/user/${PUID}/pipewire" \
                sunshine </dev/null 2>&1 \
                | grep -v "Gtk-CRITICAL" \
                >/tmp/sunshine.log &
            SUNSHINE_PID=$!
            LAST_SUNSHINE_RESTART=$(date +%s)
            echo "[entrypoint] Sunshine restarted as PID ${SUNSHINE_PID}"
        fi
    fi
done