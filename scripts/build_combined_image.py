#!/usr/bin/env python3
"""Build one paged image holding all eight AW packs, and prove it is byte-exact.

Why this exists, and why the test matters more than the builder: the naive combine is eight
packs concatenated = 16 MiB, and this core can only address 8 MiB of cellular PSRAM (22-bit word
address, bit 21 = die select). But the packs are 78.7% identical at the same offsets and 50-68% of
each body is zeros, so at 32 KiB granularity all eight are 92 distinct non-zero frames plus one
zero frame. A frame pool plus a 64-entry page table per part therefore holds the whole game in
about 2.9 MiB while each part's 2 MiB VIEW stays byte-identical to the file the core reads today.
That is the property everything else rests on: if the view is byte-exact, the trailer at 0x1fffe0,
the bench's byte oracles and resume_from_start = ~c_start[20] & (acc_cnt < 64) all keep working
untouched, because the VM never learns there was ever a pool.

See docs/another-world/single-image-plan.md.

Usage
  scripts/build_combined_image.py                 build build/aw-all.bin and verify it
  scripts/build_combined_image.py --verify [file] verify an existing image
  scripts/build_combined_image.py --selftest      prove the verifier can fail
  scripts/build_combined_image.py --report        per-part page->frame map and sharing counts

Exit status is non-zero if anything fails, including a verify that found nothing wrong with a
deliberately corrupted image. A check that cannot fail is not a check: that is how the part1
byte-compare ran "green" for weeks while comparing zero bytes (22'h1F_FFFF against a 2 MiB image).
"""

import argparse
import hashlib
import os
import struct
import sys

PACK_DIR = "ports/another-world/packs"
OUT = "build/aw-all.bin"

MAGIC = b"AWP1"
VERSION = 1
PAGE_SHIFT = 15                 # 32 KiB pages; measured granularity that makes the parts share
PAGE = 1 << PAGE_SHIFT
VIEW_BYTES = 0x1FFFF0           # one pack = 2 MiB - 16; the VM's whole addressable view
PAGES = (VIEW_BYTES + PAGE - 1) // PAGE          # 64; the last page is short by 16 bytes

# The directory occupies PHYSICAL PAGE 0 and frames are numbered by physical page from 1.
# Both halves of that are hardware decisions, not tidiness:
#   * Page-aligned, so the core's map is a CONCATENATION - psram_word = {page[7:0], word[13:0]} -
#     rather than concatenation-plus-a-constant. Worst slack in this core is +0.135 ns and the
#     cram0 address path is where build 1039a lost 4 paths at -0.385 ns, so nothing extra goes
#     between p_addr and the chip. It also costs 32 KiB of image, which is nothing next to the
#     13 MiB this scheme saves.
#   * Numbered from 1, so page 0 (the directory) can never be named by the concatenation. A
#     corrupted table entry can then point at garbage, but not at the directory itself.
HEADER_BYTES = PAGE
FRAMES_BASE = PAGE
MAX_POOL_PAGE = 127             # pool lives on die 0. {page[7:0], word[13:0]} puts bit 21 = page
                                # bit 7 = the chip's die select, so pages 128..255 are DIE 1, which
                                # is where the self-test probe and census scratch go. Keeping the
                                # pool below 128 means no access ever crosses dies by accident.
MAX_FRAMES = MAX_POOL_PAGE      # 93 today; hitting 127 means the game outgrew one die and the
                                # plan, not this constant, has to change.
PART_COUNT = 8

HDR = struct.Struct("<4sHHHHIIIII")  # magic ver frames pshift parts | view_bytes frames_base
#                                      pool_bytes pool_wsum pool_wxor
PART_REC = struct.Struct("<64HIIII") # page table (u16 each) + view_wsum + view_wxor + body + rsvd


def word_sum(data: bytes) -> int:
    """Sum of little-endian uint16 words, mod 2**32.

    This is the convention the core uses: `cw_sum <= cw_sum + wr_wdata` in aw_rom.v over the
    16-bit words it commits. Verified against the documented expectation - part1.bin sums to
    dd744c92 here, which is what hardware-bringup.md says the Z field must read.
    """
    n = len(data) // 2
    return sum(struct.unpack("<%dH" % n, data[: n * 2])) & 0xFFFFFFFF


def word_xor(data: bytes) -> int:
    n = len(data) // 2
    x = 0
    for (w,) in struct.iter_unpack("<H", data[: n * 2]):
        x ^= w
    return x & 0xFFFFFFFF


def frame_of(page_bytes: bytes) -> bytes:
    """A frame is always exactly one page, zero-padded on the tail.

    Page 63 is short by 16 bytes because a pack is 2 MiB - 16. Those 16 bytes are past the end of
    the file and are never read - the trailer occupies 0x1fffe0..0x1fffef - so padding them with
    zeros is both harmless and canonical. Padding with anything else would invent spurious distinct
    frames and quietly inflate the pool.
    """
    if len(page_bytes) == PAGE:
        return page_bytes
    return page_bytes + bytes(PAGE - len(page_bytes))


def build(packs, out_path, part0_last=False, pad_to=0):
    pool = {}          # sha1 -> frame index
    frames = []        # frame index -> bytes
    tables = []        # part -> [frame index] * PAGES
    per_frame_uses = []

    for p in packs:
        assert len(p) == VIEW_BYTES, "unexpected pack size 0x%X" % len(p)
        table = []
        for k in range(PAGES):
            fr = frame_of(p[k * PAGE : (k + 1) * PAGE])
            h = hashlib.sha1(fr).digest()
            if h not in pool:
                pool[h] = len(frames)
                frames.append(fr)
                per_frame_uses.append(0)
            per_frame_uses[pool[h]] += 1
            table.append(pool[h] + 1)      # PHYSICAL page: pool index 0 is page 1, page 0 is the
                                           # directory, so the core can never address the header
        tables.append(table)

    if pad_to:
        # Filler frames, unreferenced by any part's table. Two uses, and the second is the real one:
        # a zero frame changes no declared sum, so a file padded with them keeps the SAME pool_wsum /
        # pool_wxor as the unpadded build, and:
        #   * with --part0-last the pool is padded up to a target size and then part 0's frames are
        #     swept to the end, which makes "renders" mean "the framework delivered the WHOLE file"
        #     at that size. Bisecting the size at which that stops is a direct measurement of the
        #     dataslot upload limit, and it needs nothing but the screen.
        #   * zeros are also the honest filler: the pool sum is the same whether or not the tail
        #     arrived, so a truncated upload cannot be mistaken for a bad declaration.
        need = (pad_to - HEADER_BYTES + PAGE - 1) // PAGE
        while len(frames) < need:
            frames.append(bytes(PAGE))
            per_frame_uses.append(0)

    if part0_last:
        # Put every frame part 0 references at the END of the pool, and point part 0's table there.
        #
        # Why the file layout would ever be reordered for a test: to ask the POCKET a question it can
        # answer without a UART. Same total size, same declared sums, same parts - only part 0's data
        # moves to the last pages of the file. Launch it and look at the screen:
        #   renders part 0  -> the framework delivered the WHOLE file, tail included
        #   black/broken    -> the upload stopped before the end, and part 0's frames are what fell off
        # Comparing that against the normal layout (part 0 at the front) separates "the framework will
        # not carry 2.94 MiB" from "the core mishandles the bytes", which is the entire question #15
        # was opened for and the one thing no simulation of our own chip can answer: the bench IS the
        # host. Frame indices are physical pool pages (index 0 = page 1), so the permutation has to
        # rewrite both the layout and every table entry that names it.
        # FRAME INDICES, not page numbers: the tables hold physical page = frame index + 1 (page 0 is
        # the directory). The first version tested frame indices against the page-number set, so the
        # off-by-one made the membership test miss almost everything and part 0 stayed spread across
        # the whole pool - a probe that looked right in the header summary and would have answered the
        # wrong question. Verified below by asserting part 0 really does end up at the tail.
        p0 = {v - 1 for v in tables[0]}
        order = ([i for i in range(len(frames)) if i not in p0]
                 + [i for i in range(len(frames)) if i in p0])
        assert all(order.index(i) >= len(frames) - len(p0) for i in p0), "part 0 did not move to the tail"
        remap = {old: new for new, old in enumerate(order)}
        frames = [frames[o] for o in order]
        per_frame_uses = [per_frame_uses[o] for o in order]
        tables = [[remap[v - 1] + 1 for v in t] for t in tables]

    if len(frames) > MAX_FRAMES:
        raise SystemExit("pool is %d frames, limit is %d: the pool must stay on die 0 (pages 1..127) "
                         "because page bit 7 is the chip's die select, and die 1 is the self-test's "
                         "space. Grow the page size, or revisit the plan - do not just raise this."
                         % (len(frames), MAX_FRAMES))
    assert FRAMES_BASE % PAGE == 0, "frames must start on a page boundary or the core needs an adder"
    assert FRAMES_BASE == PAGE, "directory is exactly physical page 0"

    # frames are stored from byte FRAMES_BASE (= page 1); page 0 is the directory block
    pool_bytes = len(frames) * PAGE
    pool_data = b"".join(frames)
    # The directory lives at the FRONT, in a fixed 2 KiB block, so the core can find it without
    # knowing the file size - it is the first thing the upload delivers. Frames start after it.
    per_frame_sums = [word_sum(f) for f in frames]

    blob = bytearray(FRAMES_BASE + pool_bytes)
    # header
    HDR.pack_into(blob, 0, MAGIC, VERSION, len(frames), PAGE_SHIFT, len(packs),
                  VIEW_BYTES, FRAMES_BASE, pool_bytes,
                  word_sum(pool_data), word_xor(pool_data))
    # per-part records, then per-frame sums, inside the fixed header block
    off = HDR.size
    part_sums = []
    for i, (p, table) in enumerate(zip(packs, tables)):
        for fi in table:
            assert 1 <= fi <= MAX_POOL_PAGE, "page table value %d escapes the die-0 pool" % fi
        view_sum, view_xor = word_sum(p), word_xor(p)
        part_sums.append((view_sum, view_xor))
        PART_REC.pack_into(blob, off, *table, view_sum, view_xor, len(p), 0)
        off += PART_REC.size
    for s in per_frame_sums:
        struct.pack_into("<I", blob, off, s)
        off += 4
    if off > HEADER_BYTES:
        raise SystemExit("directory needs %d bytes but the fixed header block is %d"
                         % (off, HEADER_BYTES))
    blob[FRAMES_BASE:] = pool_data

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "wb") as fh:
        fh.write(blob)
    return blob, frames, tables, per_frame_uses, part_sums


def parse(blob):
    if len(blob) < HDR.size:
        raise SystemExit("image too small for a header")
    magic, ver, nframes, pshift, nparts, view_bytes, frames_base, pool_bytes, pw, px = \
        HDR.unpack_from(blob, 0)
    errs = []
    if magic != MAGIC:
        errs.append("bad magic %r (expected %r)" % (magic, MAGIC))
    if ver != VERSION:
        errs.append("unsupported version %d (this tool writes %d)" % (ver, VERSION))
    if pshift != PAGE_SHIFT:
        errs.append("page_shift is %d, this core/tool agree on %d" % (pshift, PAGE_SHIFT))
    if nframes > MAX_FRAMES:
        errs.append("%d frames exceeds the 8-bit table limit %d" % (nframes, MAX_FRAMES))
    if frames_base != FRAMES_BASE:
        errs.append("frames_base 0x%X != expected 0x%X" % (frames_base, FRAMES_BASE))
    if frames_base % PAGE or frames_base // PAGE != 1:
        errs.append("frames_base is not physical page 1, so the core's address concatenation "
                    "would need an adder")
    if frames_base + pool_bytes > len(blob):
        errs.append("pool 0x%X bytes at 0x%X runs past end of file 0x%X"
                    % (pool_bytes, frames_base, len(blob)))
    parts = []
    off = HDR.size
    for _ in range(nparts):
        vals = PART_REC.unpack_from(blob, off)
        parts.append({"table": list(vals[:64]), "view_sum": vals[64],
                      "view_xor": vals[65], "body": vals[66]})
        off += PART_REC.size
    fsums = []
    for _ in range(nframes):
        fsums.append(struct.unpack_from("<I", blob, off)[0])
        off += 4
    # Table sanity, after the tables exist. Page 0 is the directory and pages >= 128 are die 1,
    # where the self-test probe lives; the core's address is a bare concatenation and would follow
    # either one happily, so the tool has to be the one that says no.
    if any(t == 0 for p in parts for t in p["table"]):
        errs.append("a page table names physical page 0 (the directory block)")
    if any(t > MAX_POOL_PAGE for p in parts for t in p["table"]):
        errs.append("a frame page is >= %d, which lands on die 1 (self-test space)"
                    % MAX_POOL_PAGE)
    return dict(nframes=nframes, nparts=nparts, view_bytes=view_bytes,
                frames_base=frames_base, pool_bytes=pool_bytes, pool_sum=pw, pool_xor=px,
                parts=parts, frame_sums=fsums, errs=errs, dir_end=off)


def reassemble(img, blob, part):
    """The part's 2 MiB view, straight out of the pool through its page table."""
    out = bytearray()
    for k in range(PAGES):
        fi = img["parts"][part]["table"][k]      # physical page
        if fi == 0:
            raise SystemExit("part %d page %d names physical page 0 (the directory)" % (part, k))
        if fi - 1 >= img["nframes"]:
            raise SystemExit("part %d page %d names page %d, pool has %d frames"
                             % (part, k, fi, img["nframes"]))
        s = img["frames_base"] + (fi - 1) * PAGE
        out += blob[s : s + PAGE]
    return bytes(out[: img["view_bytes"]])


def verify(image_path, packs, quiet=False):
    with open(image_path, "rb") as fh:
        blob = fh.read()
    img = parse(blob)
    errs = list(img["errs"])
    if img["nparts"] != len(packs):
        errs.append("directory holds %d parts, expected %d" % (img["nparts"], len(packs)))
    pool = blob[img["frames_base"] : img["frames_base"] + img["pool_bytes"]]
    if word_sum(pool) != img["pool_sum"]:
        errs.append("pool word sum is %08x, directory says %08x"
                    % (word_sum(pool), img["pool_sum"]))
    if word_xor(pool) != img["pool_xor"]:
        errs.append("pool word xor is %08x, directory says %08x"
                    % (word_xor(pool), img["pool_xor"]))
    # The core's pool sum covers every page it was given except page 0 - it does not read pool_bytes.
    # So the declared sum and the measured sum describe the same bytes ONLY while the pool is a whole
    # number of pages starting at frames_base and nothing follows it in the file. That is what
    # "nframes x PAGE" states, and what the per-frame padding above guarantees. If a future builder
    # packs frames tighter, moves frames_base, or appends anything after the pool, the two sums stop
    # meaning the same thing and every image reads bad on hardware while being perfectly good - so it
    # fails here, in Python, with a sentence about it, rather than on a Pocket.
    if img["pool_bytes"] != img["nframes"] * PAGE:
        errs.append("pool_bytes %d != nframes %d x PAGE %d: the core sums pool_bytes/2 words from page 1,"
                    " so it would measure a different range than this sum covers"
                    % (img["pool_bytes"], img["nframes"], PAGE))
    if img["pool_bytes"] % 2:
        errs.append("pool_bytes %d is odd; the core sums 16-bit words" % img["pool_bytes"])
    # Die 0 is 2^21 PSRAM words = 4 MiB bytes, and pages 128..255 are die 1 (page bit 7 is the die
    # select). A pool that runs off the end of die 0 would be silently read from the wrong chip.
    if img["frames_base"] + img["pool_bytes"] > 2 * 0x200000:
        errs.append("pool ends at byte 0x%X, past die 0 (0x%X bytes): the census cannot reach it"
                    % (img["frames_base"] + img["pool_bytes"], 2 * 0x200000))
    for i, s in enumerate(img["frame_sums"]):
        f = pool[i * PAGE : (i + 1) * PAGE]
        if len(f) != PAGE:
            errs.append("frame %d is short (%d bytes)" % (i, len(f)))
        elif word_sum(f) != s:
            errs.append("frame %d word sum %08x != directory %08x" % (i, word_sum(f), s))
    rows = []
    for part, p in enumerate(packs[: img["nparts"]]):
        view = reassemble(img, blob, part)
        if view != p:
            bad = next((j for j in range(min(len(view), len(p))) if view[j] != p[j]), -1)
            errs.append("part %d view differs at byte 0x%X (page %d): image %02x, pack %02x"
                        % (part, bad, bad // PAGE if bad >= 0 else -1,
                           view[bad] if bad >= 0 else -1, p[bad] if bad >= 0 else -1))
        rec = img["parts"][part]
        if rec["view_sum"] != word_sum(p):
            errs.append("part %d directory view_sum %08x != pack sum %08x"
                        % (part, rec["view_sum"], word_sum(p)))
        rows.append((part, len(set(rec["table"])), rec["view_sum"]))
    if not quiet:
        print("image      : %s  (%d bytes = %.3f MiB)"
              % (image_path, len(blob), len(blob) / 2.0 ** 20))
        print("frames     : %d x %d KiB = %.3f MiB pool, ending at byte 0x%X"
              % (img["nframes"], PAGE // 1024, img["pool_bytes"] / 2.0 ** 20,
                 img["frames_base"] + img["pool_bytes"]))
        print("pool sums  : wsum %08x  wxor %08x   <- what a census over the pool must read"
              % (img["pool_sum"], img["pool_xor"]))
        print("per part   : frames used, and that part's OWN view word sum (the old per-pack Z)")
        for part, nf, vs in rows:
            print("   part%d   %3d frames   %08x" % (part, nf, vs))
        print("self-test  : keep the probe word above byte 0x%X"
              % (img["frames_base"] + img["pool_bytes"]))
    return errs


def selftest(packs):
    """The verifier must reject a corrupted image. If this passes silently, nothing is checked."""
    import tempfile
    blob, frames, tables, _, _ = build(packs, os.path.join(tempfile.mkdtemp(), "t.bin"))
    cases = []

    b = bytearray(blob)                      # 1: one page-table entry redirected
    img = parse(bytes(b))
    rec = img["parts"][1]
    b1 = bytearray(blob)
    off = HDR.size + 1 * PART_REC.size       # part 1's record
    bad_frame = rec["table"][3] + 1             # a different, still-plausible physical page
    struct.pack_into("<H", b1, off + 3 * 2, bad_frame)
    cases.append(("page table entry redirected", bytes(b1)))

    b2 = bytearray(blob)                     # 2: one byte of pool data flipped
    b2[img["frames_base"] + 7 * PAGE + 5] ^= 0x01
    cases.append(("one pool byte flipped", bytes(b2)))

    b3 = bytearray(blob)                     # 3: a trailer word of a frame changed
    last = img["frames_base"] + (img["nframes"] - 1) * PAGE + PAGE - 4
    b3[last] ^= 0xFF
    cases.append(("frame tail byte flipped", bytes(b3)))

    b4 = bytearray(blob)                     # 4: magic mangled
    b4[1] ^= 0x01
    cases.append(("bad magic", bytes(b4)))

    b5 = bytearray(blob)                     # 5: a table entry aimed at the directory page
    struct.pack_into("<H", b5, HDR.size + 2 * PART_REC.size + 5 * 2, 0)
    cases.append(("table entry aimed at page 0", bytes(b5)))

    ok = True
    tmp = tempfile.mkdtemp()
    for name, data in cases:
        p = os.path.join(tmp, "corrupt.bin")
        with open(p, "wb") as fh:
            fh.write(data)
        try:
            errs = verify(p, packs, quiet=True)
        except SystemExit as e:
            errs = ["exited: %s" % e]
        if errs:
            print("  %-26s -> correctly rejected: %s" % (name, errs[0][:96]))
        else:
            print("  %-26s -> NOT DETECTED - the verifier is decorative" % name)
            ok = False
    return ok


def report(packs):
    blob, frames, tables, uses, _ = build(packs, "/tmp/_aw_report.bin")
    print("page size %d KiB, view %d pages, pool %d frames" % (PAGE // 1024, PAGES, len(frames)))
    hist = {}
    for u in uses:
        hist[u] = hist.get(u, 0) + 1
    print("frames by how many pages use them:", dict(sorted(hist.items())))
    print("frames used by all %d parts: %d" % (len(packs), hist.get(len(packs), 0)))
    for i, t in enumerate(tables):
        uniq = sorted(set(t))
        print("  part%d: %2d distinct frames %s" % (i, len(uniq), uniq))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", nargs="?", const=OUT, metavar="IMAGE")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("-o", "--out", default=OUT)
    ap.add_argument("--parts", type=int, default=PART_COUNT,
                    help="only the first N parts (a small paged image proves the FORMAT works "
                         "on hardware independently of the file being 2.94 MiB)")
    ap.add_argument("--pad-to", type=int, default=0, metavar="BYTES",
                    help="pad the pool with zero frames up to this total file size")
    ap.add_argument("--part0-last", action="store_true",
                    help="move part 0's frames to the end of the file (same size, same sums) so a "
                         "launch answers 'did the tail arrive?' from the screen alone")
    a = ap.parse_args()

    packs = []
    for i in range(a.parts):
        p = os.path.join(PACK_DIR, "part%d.bin" % i)
        with open(p, "rb") as fh:
            packs.append(fh.read())

    if a.report:
        report(packs)
        return 0

    if a.verify:
        errs = verify(a.verify, packs)
        if errs:
            print("\nFAIL")
            for e in errs:
                print("  -", e)
            return 1
        print("\nOK: every part's view is byte-identical to its pack")
        return 0

    blob, frames, tables, uses, _ = build(packs, a.out, part0_last=a.part0_last,
                                          pad_to=a.pad_to)
    print("wrote %s: %d bytes (%.3f MiB), %d frames, %d parts"
          % (a.out, len(blob), len(blob) / 2.0 ** 20, len(frames), len(packs)))
    print("      vs %d separate packs = %.2f MiB, or %.2f MiB uploaded per load today"
          % (len(packs), len(packs) * VIEW_BYTES / 2.0 ** 20, VIEW_BYTES / 2.0 ** 20))
    errs = verify(a.out, packs)
    if errs:
        print("FAIL")
        for e in errs:
            print("  -", e)
        return 1
    print("verify: OK - all %d views byte-identical to their packs" % len(packs))
    if a.selftest:
        print("\nselftest (the verifier must reject damage):")
        if not selftest(packs):
            return 1
        print("selftest: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
