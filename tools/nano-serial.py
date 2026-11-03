#!/usr/bin/env python3
"""Serial-console helper for the Jetson Nano debug UART.

  nano-serial.py log  SECONDS [LOGFILE]       capture console output
  nano-serial.py uboot [-f SECS] [CMD ...]    wait for U-Boot autoboot, stop it,
                                              run CMDs, print output; with -f keep
                                              logging SECS afterwards (e.g. after
                                              a `boot` command)
  nano-serial.py send  LINE [SECONDS]         send one line, print reply

Power-cycle/reboot the board yourself (or via ssh) before `uboot`.
Every byte read is also appended to logs/serial-<date>.log.
"""
import datetime
import os
import sys
import time

import serial

DEV = os.environ.get(
    "NANO_SERIAL", "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5734003039-if00"
)
LOGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "logs")


def open_port():
    os.makedirs(LOGDIR, exist_ok=True)
    log = open(
        os.path.join(LOGDIR, f"serial-{datetime.date.today()}.log"), "ab", buffering=0
    )
    return serial.Serial(DEV, 115200, timeout=0.2), log


def pump(s, log, seconds, until=None, echo=True):
    """Read for `seconds` (or until `until` bytes appear). Returns data."""
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        chunk = s.read(4096)
        if chunk:
            log.write(chunk)
            buf += chunk
            if echo:
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
            if until and until in buf:
                break
    return buf


def run_uboot(s, log, cmds):
    print(">>> waiting for U-Boot autoboot prompt (reboot the board now)")
    buf = pump(s, log, float(os.environ.get("NANO_WAIT", 600)), until=b"Hit any key to stop autoboot")
    if b"Hit any key" not in buf:
        sys.exit("!!! never saw the autoboot prompt")
    for _ in range(5):
        s.write(b" ")
        time.sleep(0.05)
    pump(s, log, 1.5)
    for cmd in cmds:
        s.write(cmd.encode() + b"\r")
        pump(s, log, 3)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    s, log = open_port()
    mode = sys.argv[1]
    if mode == "log":
        secs = float(sys.argv[2])
        out = sys.argv[3] if len(sys.argv) > 3 else None
        data = pump(s, log, secs)
        if out:
            open(out, "ab").write(data)
    elif mode == "uboot":
        args = sys.argv[2:]
        follow = 0
        if args[:1] == ["-f"]:
            follow, args = float(args[1]), args[2:]
        run_uboot(s, log, args)
        pump(s, log, follow)
    elif mode == "send":
        s.write(sys.argv[2].encode() + b"\r")
        pump(s, log, float(sys.argv[3]) if len(sys.argv) > 3 else 3)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
