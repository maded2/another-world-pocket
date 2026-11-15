#!/usr/bin/env python3
"""Stamp a core's core.json with the build it is being packaged with.

    scripts/stamp_release.py cores/aw/core.json build/aw/bitstream.rbf_r [--version 1.0.0]

Why: the metadata said `0.1.0 / 2026-10-08` while the bitstream in the same folder was a
different build - the same class of lie as the console banner that announced "AW 1041a up" for
three releases, and it costs a hardware round trip to notice. The version comes from
RELEASE_VERSION (default 1.0.0) and the date from the BITSTREAM's mtime, because the date that
matters is the one the artifact was built on, not the day someone typed a JSON file.
"""
import argparse
import datetime
import json
import os


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("core_json")
    ap.add_argument("bitstream")
    ap.add_argument("--version", default=os.environ.get("RELEASE_VERSION", "1.0.0"))
    a = ap.parse_args()

    d = json.load(open(a.core_json))
    m = d["core"]["metadata"]
    m["version"] = a.version
    m["date_release"] = datetime.date.fromtimestamp(os.path.getmtime(a.bitstream)).isoformat()
    with open(a.core_json, "w") as fh:
        json.dump(d, fh, indent=4)
        fh.write("\n")
    print("package: stamped version %s, date %s (%s)"
          % (m["version"], m["date_release"], os.path.basename(a.bitstream)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
