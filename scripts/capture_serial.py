#!/usr/bin/env python3
"""Capture Analogue Pocket serial console output from its USB-C debug port.

Usage:
  capture_serial.py [port] [baud]

Defaults: /dev/ttyUSB0 at 115200 baud (typical for openFPGA core debug UARTs).

Writes a timestamped text log to build/serial-capture-<ts>.log and the raw
bytes to build/serial-capture-<ts>.raw alongside it. Ctrl+C or SIGTERM stops
it cleanly.
"""
import os
import signal
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200


def main() -> None:
    ts = time.strftime("%Y%m%d-%H%M%S")
    outdir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build")
    os.makedirs(outdir, exist_ok=True)
    log_path = os.path.join(outdir, f"serial-capture-{ts}.log")
    raw_path = os.path.join(outdir, f"serial-capture-{ts}.raw")

    ser = serial.Serial(PORT, BAUD, timeout=0.5)
    state = {"running": True}

    def stop(signum, frame):
        state["running"] = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"capturing {PORT} @ {BAUD} -> {log_path}", flush=True)
    with open(log_path, "ab") as log, open(raw_path, "wb") as raw:
        while state["running"]:
            try:
                data = ser.read(4096)
            except serial.SerialException as e:
                # transient: another reader had the port, or a glitch
                print(f"warn: {e}", flush=True)
                time.sleep(1.0)
                continue
            if not data:
                continue
            stamp = time.strftime("%H:%M:%S", time.localtime())
            log.write(f"[{stamp}] {len(data):5d}B  ".encode())
            log.write(data)
            log.write(b"\n")
            log.flush()
            raw.write(data)
            raw.flush()
            sys.stdout.buffer.write(data)
            sys.stdout.flush()

    ser.close()
    print(f"\nstopped. logs: {log_path}\n          {raw_path}", flush=True)


if __name__ == "__main__":
    main()
