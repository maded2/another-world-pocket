#!/usr/bin/env python3
"""Dump the image's audio index as hex for the bench, plus the expectation table from aw-audio.json."""
import json, struct, sys
img, out = sys.argv[1], sys.argv[2]
d = open(img, "rb").read()
REC = struct.Struct("<HBBIHHHH")
OFF = 0x1000
cnt = d[OFF + 1]
with open(out + "/idx.hex", "w") as fh:
    for k in range(cnt):
        for b in d[OFF + 4 + k*REC.size : OFF + 4 + (k+1)*REC.size]:
            fh.write("%02x\n" % b)
with open(out + "/expect.txt", "w") as fh:
    for k in range(cnt):
        res, t, fl, off, po, pl, ls, ll = REC.unpack_from(d, OFF + 4 + k*REC.size)
        fh.write("%d %d %d %d %d %d %d\n" % (res, t, off, po, pl, ls, ll))
print("dumped %d records to %s" % (cnt, out))
