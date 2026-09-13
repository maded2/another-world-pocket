#!/usr/bin/env python3
"""Reverse the bit order of a Quartus RBF bitstream -> Analogue Pocket .rbf_r.

The Pocket loads its Cyclone V bitstream with the bits inside every byte
reversed. This is the step Analogue calls "Creating a reversed RBF" and it is
what every Pocket core ships as ``bitstream.rbf_r``.

Only the bit order *within each byte* is reversed - byte order and file length
are preserved, so the operation is its own inverse.

Verified against the reference bitstreams shipped in Analogue's
open-fpga/core-template (byte-for-byte identical output).

    reverse_bits.py input.rbf output.rbf_r
    reverse_bits.py --verify input.rbf output.rbf_r

Written for Python 3.5+ because the Quartus container (Debian 9) ships 3.5.
"""

import argparse
import hashlib
import sys
from pathlib import Path

# 256-entry table: byte -> byte with its 8 bits reversed.
REVERSE_TABLE = bytes(int("{:08b}".format(i)[::-1], 2) for i in range(256))

# Typical .rbf sizes (bytes) for Cyclone V devices seen on the Pocket.
# The exact size depends on the Quartus version (the same design is 787,952 B
# with Quartus 18.1 and 787,896 B with 22.1), so only a gross deviation is
# reported - it flags a wrong device or a mis-configured "Convert Programming
# File" step, not a version difference.
KNOWN_SIZES = {
    "5CEBA4F23C8": 787952,   # device used by open-fpga/core-template
}
TOLERANCE = 0.05   # 5 %


def reverse_bytes(data):
    """Return *data* with the bit order of every byte reversed."""
    return data.translate(REVERSE_TABLE)


def reverse_file(src, dst):
    """Reverse bits of file *src* into *dst*; return (size, sha256)."""
    data = src.read_bytes()
    if not data:
        raise ValueError("{} is empty - did Quartus produce a bitstream?".format(src))
    out = reverse_bytes(data)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(out)
    return len(out), hashlib.sha256(out).hexdigest()


def verify(src, dst):
    """Reversing the output again must reproduce the input byte for byte."""
    return reverse_bytes(dst.read_bytes()) == src.read_bytes()


def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", type=Path, help="Quartus .rbf (or .rbf_r) file")
    p.add_argument("output", type=Path, help="destination .rbf_r file")
    p.add_argument("--verify", action="store_true",
                   help="round-trip the result and fail if it differs from the input")
    p.add_argument("--device", default="5CEBA4F23C8",
                   help="device used for the size sanity check (default 5CEBA4F23C8)")
    opts = p.parse_args(argv)

    if not opts.input.is_file():
        print("error: {} not found".format(opts.input), file=sys.stderr)
        return 2

    if opts.input.name.endswith("rbf_r"):
        print("note: {} already looks reversed; this would un-reverse it".format(
            opts.input), file=sys.stderr)

    try:
        size, digest = reverse_file(opts.input, opts.output)
    except OSError as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 2

    print("reversed {} -> {}  ({:,} bytes, sha256 {}...)".format(
        opts.input, opts.output, size, digest[:12]))

    expected = KNOWN_SIZES.get(opts.device.upper())
    if expected and abs(size - expected) > expected * TOLERANCE:
        print("warning: {:,} bytes is far from the ~{:,} typical for {}; check the "
              "device and the 'Convert Programming File' settings (uncompressed "
              "RBF)".format(size, expected, opts.device), file=sys.stderr)

    if opts.verify:
        if verify(opts.input, opts.output):
            print("verify: OK (round-trip matches)")
            return 0
        print("error: round-trip verification FAILED", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
