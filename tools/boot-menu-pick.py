#!/usr/bin/env python3
# Reboot the Nano and pick extlinux menu entry N over serial (rollback test).
#   tools/boot-menu-pick.py N [HOST]   (1 = default, 2 = newest generation, ...)
import subprocess, sys, time, serial
choice = sys.argv[1]
HOST = sys.argv[2] if len(sys.argv) > 2 else "sirhc@unicomplex"
import os
s = serial.Serial(os.environ.get("NANO_SERIAL", "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5734003039-if00"), 115200, timeout=0.2)
s.reset_input_buffer()
subprocess.Popen(["ssh", HOST, "sudo systemctl reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.time(); buf = b""
while time.time() - t0 < 300:
    buf += s.read(4096)
    if b"Enter choice:" in buf:
        s.write(choice.encode() + b"\r")
        print(f"{time.time()-t0:.1f}s: menu seen, sent {choice}")
        break
else:
    sys.exit("no menu")
buf = b""
while time.time() - t0 < 320:
    buf += s.read(4096)
    if b"Starting kernel" in buf:
        break
for l in buf.decode("utf-8", "replace").splitlines():
    if "Retrieving file" in l or "append:" in l or "Starting kernel" in l or l.strip()[:2].isdigit():
        print("   ", l.strip()[:150])
