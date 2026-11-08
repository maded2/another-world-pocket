#!/usr/bin/env python3
"""Prove the sample address formula against the image itself.

aw_audio_idx resolves a resource to {blob_off, pcm_off, pcm_len}. The fetch address for sample position p is
    AUDIO_BASE + blob_off + pcm_off + p
with AUDIO_BASE = frames_base + pool_bytes. This checks that formula by READING THE IMAGE at those addresses
and comparing against the extracted blob - so if the formula is wrong, it fails here instead of becoming an
adder in Verilog that faithfully computes the wrong thing.

It also checks the boundary the RTL will hit: the last resource's last byte must be inside the file.
"""
import json, struct, sys

img_path, blob_path, idx_path = sys.argv[1], sys.argv[2], sys.argv[3]
img = open(img_path, "rb").read()
blob = open(blob_path, "rb").read()
HDR = struct.Struct("<4sHHHHIIIII")
magic, ver, nframes, pshift, nparts, view_bytes, frames_base, pool_bytes, wsum, wxor = HDR.unpack_from(img, 0)
AUDIO_BASE = frames_base + pool_bytes
REC = struct.Struct("<HBBIHHHH")
OFF = 0x1000
cnt = img[OFF + 1]

print("image %d bytes, audio base 0x%X, %d records" % (len(img), AUDIO_BASE, cnt))

# The RTL carries AUDIO_BASE as a constant, so the image and the constant have to agree or every sample is
# fetched from the wrong place. Read it out of the source and fail on a mismatch; a remembered number is
# exactly the kind of thing that survives a layout change and then plays noise.
import os, re
rtl = sys.argv[4] if len(sys.argv) > 4 else "cores/aw/src/fpga/core/aw_audio_ch.v"
if os.path.exists(rtl):
    m = re.search(r"AUDIO_BASE\s*=\s*24'h([0-9A-Fa-f]+)", open(rtl).read())
    if not m:
        print("  FAIL: could not find AUDIO_BASE in %s" % rtl)
        sys.exit(1)
    rtl_base = int(m.group(1), 16)
    print("rtl AUDIO_BASE = 0x%X (%s)" % (rtl_base, rtl))
    if rtl_base != AUDIO_BASE:
        print("  FAIL: RTL AUDIO_BASE 0x%X != image 0x%X" % (rtl_base, AUDIO_BASE))
        sys.exit(1)
bad = 0
last_end = 0
for k in range(cnt):
    res, typ, fl, blob_off, pcm_off, pcm_len, ls, ll = REC.unpack_from(img, OFF + 4 + k * REC.size)
    if pcm_len == 0:
        continue
    start = AUDIO_BASE + blob_off + pcm_off
    end = start + pcm_len
    last_end = max(last_end, end)
    # three probes per resource: first, middle, last - enough to catch an offset error without comparing
    # 0.7 MiB twice, and the middle one catches a length error that first/last would miss
    for label, p in (("first", 0), ("middle", pcm_len // 2), ("last", pcm_len - 1)):
        a = start + p
        b = blob_off + pcm_off + p
        if a >= len(img):
            print("  FAIL res %d %s: address 0x%X past the image" % (res, label, a))
            bad += 1
        elif img[a] != blob[b]:
            print("  FAIL res %d %s: image[0x%X]=%02x blob[0x%X]=%02x" % (res, label, a, img[a], b, blob[b]))
            bad += 1
print("probes checked, %d mismatches" % bad)
print("highest audio byte used: 0x%X of 0x%X (slack %d bytes)" % (last_end, len(img), len(img) - last_end))
sys.exit(1 if bad else 0)
