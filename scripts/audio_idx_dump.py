#!/usr/bin/env python3
"""Dump the image's audio index as hex for the bench, plus the expectation table from aw-audio.json."""
import json, struct, sys
img, out = sys.argv[1], sys.argv[2]
d = open(img, "rb").read()
REC = struct.Struct("<HBBIHHHH")
OFF = 0x1000
cnt = d[OFF + 1]
# The WHOLE region from OFF, header included: the RTL indexes this RAM as idx[addr - 0x1000], so idx[0] must
# be the tag and idx[1] the count. Writing only the records put record 0's first byte where the count belongs,
# so the DUT read count=0 and reported every id as not-found - a bench/data mismatch that looked exactly like
# a broken lookup.
with open(out + "/idx.hex", "w") as fh:
    for b in d[OFF : OFF + 4 + cnt * REC.size]:
        fh.write("%02x\n" % b)
with open(out + "/expect.txt", "w") as fh:
    for k in range(cnt):
        res, t, fl, off, po, pl, ls, ll = REC.unpack_from(d, OFF + 4 + k*REC.size)
        fh.write("%d %d %d %d %d %d %d\n" % (res, t, off, po, pl, ls, ll))
print("dumped %d records to %s" % (cnt, out))
