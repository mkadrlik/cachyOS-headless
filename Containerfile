# SPDX-License-Identifier: MIT
# CachyOS Headless Steam — Container Image
# Arch-derivative base + Sway + Steam + Sunshine (Moonlight streaming)
#
# Display: Sway headless+GPU (WLR_BACKEND=headless)
# Host requires amdgpu.virtual_display kernel parameter for GPU rendering
# Without it, wlroots falls back to software rendering (llvmpipe)
# Audio: PipeWire + null-sink isolation
# Streaming: Sunshine wlr capture + VA-API hardware encoding on AMD
#
# Why CachyOS instead of Bazzite:
#   Bazzite is an immutable Fedora Atomic image — rpm-ostree for installs,
#   systemd as PID 1, /usr read-only. Heavy, slow builds, hard to debug.
#   CachyOS is a standard Arch derivative — pacman, lean base, full control.
#
# Why WLR_BACKEND=headless instead of vkms+pixman:
#   headless backend creates a virtual compositor output with no physical
#   monitor. Sway renders on the AMD GPU via auto-detected GLES2/Vulkan,
#   allocates DMA-BUFs. wlr-screencopy returns real GPU pixel data for
#   VA-API encode. No pixman, no SHM dead end, no vkms, no HDMI dummy plug.
#   ⚠️ Host MUST set amdgpu.virtual_display=desc:1920x1080 kernel parameter
#      for proper DRM/Vulkan device matching — otherwise software rendering.

FROM docker.io/cachyos/cachyos:latest

# Build arguments
ARG PUID=1000
ARG PGID=1000
ARG CONTAINER_USER=gamer

# ── Layer 1: Core packages ─────────────────────────────────────
# pacman cache must be fresh for a container build
RUN pacman -Sy --noconfirm --needed \
    # ── Display server ──
    sway \
    swaybg \
    xorg-xwayland \
    seatd \
    # ── GPU drivers (AMD) ──
    mesa \
    lib32-mesa \
    vulkan-radeon \
    lib32-vulkan-radeon \
    vulkan-icd-loader \
    lib32-vulkan-icd-loader \
    libva \
    libva-utils \
    # ── Audio ──
    pipewire \
    pipewire-pulse \
    wireplumber \
    pipewire-audio \
    lib32-pipewire \
    lib32-libpulse \
    # ── D-Bus ──
    dbus \
    # ── Sunshine ──
    sunshine \
    # ── Steam ──
    steam \
    # ── Input ──
    libinput \
    # ── On-screen keyboard (for phone/tablet Moonlight streaming) ──
    # squeekboard removed — only works with Sway's input system
    # ── Utilities ──
    sudo \
    util-linux \
    pciutils \
    curl \
    ttf-font \
    && pacman -Scc --noconfirm

# ── Layer 2: Create user ────────────────────────────────────────
RUN groupadd -g "${PGID}" "${CONTAINER_USER}" 2>/dev/null || true && \
    useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash -c "Headless Gaming" "${CONTAINER_USER}" 2>/dev/null || true && \
    for grp in video audio input render uinput seat; do \
        groupadd -r "${grp}" 2>/dev/null || true; \
        usermod -aG "${grp}" "${CONTAINER_USER}"; \
    done && \
    mkdir -p "/run/user/${PUID}" && chown "${PUID}:${PGID}" "/run/user/${PUID}" && chmod 0700 "/run/user/${PUID}"

# ── Layer 3: Copy configs ──────────────────────────────────────
COPY system_files/ /
COPY home-template/ /home/template/

# ── Layer 4: Permissions + machine-id ──────────────────────────
RUN chmod +x /usr/local/bin/entrypoint.sh && \
    rm -f /etc/machine-id /var/lib/dbus/machine-id && \
    dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || \
    tr -dc 'a-f0-9' </dev/urandom | head -c 32 > /etc/machine-id && \
    mkdir -p /var/lib/dbus && \
    cp /etc/machine-id /var/lib/dbus/machine-id

# Expose Sunshine ports — all required for Moonlight connectivity
# 47984-47990 TCP+UDP: Streaming + web UI + discovery
# 47998-47999 UDP: Control stream
# 48000      UDP: Video/data stream
# 48010      TCP+UDP: RTSP handshake + gamestream data
EXPOSE 47984-47990 47998-48000 48010

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]