#!/usr/bin/env python3
"""
Create dummy uinput devices BEFORE Sway starts so libinput finds them.

Sway with WLR_BACKENDS=headless,libinput requires at least one libinput device
at startup or it fails. Sunshine creates real uinput devices later (Mouse
passthrough, Keyboard passthrough), but those appear AFTER Sway starts.

This script creates placeholder mouse + keyboard devices via /dev/uinput that
libinput picks up during initial scan. Sunshine's real devices coexist beside them.

Uses the legacy write(uinput_user_dev) API — proven compatible with all kernels.
"""

import os
import sys
import fcntl
import struct
import time

# ── ioctl number computation ──
def _IO(t, nr):
    return ((0) << 30) | (ord(t) << 8) | ((nr) << 0) | ((0) << 16)

def _IOW(t, nr, size):
    return ((1) << 30) | (ord(t) << 8) | ((nr) << 0) | ((size) << 16)

def _IOR(t, nr, size):
    return ((2) << 30) | (ord(t) << 8) | ((nr) << 0) | ((size) << 16)

IOC_SIZE = struct.calcsize("i")

UI_DEV_CREATE  = _IO("U", 1)
UI_DEV_DESTROY = _IO("U", 2)
UI_SET_EVBIT   = _IOW("U", 100, IOC_SIZE)
UI_SET_KEYBIT  = _IOW("U", 101, IOC_SIZE)
UI_SET_RELBIT  = _IOW("U", 102, IOC_SIZE)
UI_SET_ABSBIT  = _IOW("U", 103, IOC_SIZE)

# ── event codes ──
EV_KEY = 0x01
EV_REL = 0x02

REL_X     = 0x00
REL_Y     = 0x01
REL_WHEEL = 0x08

BTN_LEFT   = 0x110
BTN_RIGHT  = 0x111
BTN_MIDDLE = 0x112

ABS_MAX = 63


def _make_uinput_user_dev(name):
    """Build the legacy 1116-byte uinput_user_dev struct."""
    name_bytes = name.encode("utf-8") + b"\0" * (80 - len(name))  # 80 total
    id_buf = struct.pack("HHHH", 0x03, 0x1234, 0x5678, 1)  # 8 bytes
    ff     = struct.pack("I", 0)                              # 4 bytes

    zeros = struct.pack(f"<{ABS_MAX+1}i", *([0]  * (ABS_MAX + 1)))  # 256 each
    negs  = struct.pack(f"<{ABS_MAX+1}i", *([-1] * (ABS_MAX + 1)))

    return name_bytes + id_buf + ff + negs + zeros + zeros + zeros


def create_dummy_device(name, setup_fn):
    """Create a uinput device and return the open fd."""
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    setup_fn(fd)
    dev_buf = _make_uinput_user_dev(name)
    os.write(fd, dev_buf)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def setup_mouse(fd):
    """Configure uinput bits for a relative mouse."""
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_WHEEL)


def setup_keyboard(fd):
    """Configure uinput bits for a keyboard."""
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for key in range(1, 128):  # KEY_ESC through most standard keys
        fcntl.ioctl(fd, UI_SET_KEYBIT, key)


def main():
    created = []

    # ── Dummy Mouse (relative) ──
    try:
        fd = create_dummy_device("Dummy Mouse", setup_mouse)
        created.append(("mouse", fd))
        print(f"[dummy-uinput] Created Dummy Mouse (fd={fd})")
    except Exception as e:
        print(f"[dummy-uinput] Failed to create mouse: {e}", file=sys.stderr)

    # ── Dummy Keyboard ──
    try:
        fd = create_dummy_device("Dummy Keyboard", setup_keyboard)
        created.append(("keyboard", fd))
        print(f"[dummy-uinput] Created Dummy Keyboard (fd={fd})")
    except Exception as e:
        print(f"[dummy-uinput] Failed to create keyboard: {e}", file=sys.stderr)

    if not created:
        print("[dummy-uinput] No dummy devices created — bailing!", file=sys.stderr)
        sys.exit(1)

    print(f"[dummy-uinput] {len(created)} dummy device(s) created. Holding FDs open.")

    # Keep FDs open so devices persist
    try:
        while True:
            time.sleep(10)
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        for name, fd in created:
            try:
                fcntl.ioctl(fd, UI_DEV_DESTROY)
                os.close(fd)
            except Exception:
                pass


if __name__ == "__main__":
    main()