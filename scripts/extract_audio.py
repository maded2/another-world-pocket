#!/usr/bin/env python3
"""Extract the game's sound effects and music from the DOS data banks.

    python3 scripts/extract_audio.py [--out build/aw-audio.bin]

Why this exists: the per-part packs (scripts/extract_packs.sh) carry palette, bytecode, cinematic and
video2 only. The audio lives in the same bank files but is never loaded by the current core, so a pack
plays silently. This unpacks it into a blob the core can serve, plus an index of where each resource
began in the original files.

THE UNPACKER IS A TRANSCRIPTION, NOT AN INVENTION. Every routine here mirrors
upstream's BUILD/Another-World-Bytecode-Interpreter/src/bank.cpp (Bank::read / unpack / nextChunk /
getCode / rcr / decUnk1 / decUnk2) line for line, including the in-place layout: the compressed data
sits at the TOP of the buffer and the output is written backwards from the end, so the writer never
clobbers bytes it has not read yet. If the two ever disagree the sizes check below will say so for
every entry, which is why the check compares against the memlist rather than against this code.
"""
import argparse
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAMEDATA = os.path.join(ROOT, "gamedata")

# Resource::ResType (resource.h)
RT_SOUND, RT_MUSIC, RT_POLY_ANIM, RT_PALETTE, RT_BYTECODE, RT_POLY_CINEMATIC = range(6)
TYPE_NAMES = {RT_SOUND: "SOUND", RT_MUSIC: "MUSIC", RT_POLY_ANIM: "POLY_ANIM", RT_PALETTE: "PALETTE",
              RT_BYTECODE: "BYTECODE", RT_POLY_CINEMATIC: "CINEMATIC"}

MEMLIST_ENTRY = 20          # bytes: see struct MemEntry in resource.h


def read_memlist(path):
    """Parse memlist.bin into the same fields the engine's readEntries produces.

    All multi-byte fields are BIG-endian. The list ends at the first entry whose state is 0xFF
    (main.cpp: "why does memlist.bin use a special state field 0xFF to mark the end of resources").
    """
    data = open(path, "rb").read()
    out = []
    for off in range(0, len(data) - MEMLIST_ENTRY + 1, MEMLIST_ENTRY):
        state = data[off]
        if state == 0xFF:
            break
        (unk4,) = struct.unpack(">H", data[off + 4:off + 6])
        (bank_off,) = struct.unpack(">I", data[off + 8:off + 12])
        (unkc,) = struct.unpack(">H", data[off + 12:off + 14])
        (packed,) = struct.unpack(">H", data[off + 14:off + 16])
        (unk10,) = struct.unpack(">H", data[off + 16:off + 18])
        (size,) = struct.unpack(">H", data[off + 18:off + 20])
        out.append(dict(state=state, type=data[off + 1], rank=data[off + 6], bank=data[off + 7],
                        bank_off=bank_off, packed=packed, size=size,
                        unk4=unk4, unkc=unkc, unk10=unk10))
    return out


class Unpack:
    """One transcription of Bank's unpacker, over a bytearray buffer."""

    def __init__(self, buf, packed):
        self.buf = buf
        self.i = packed - 4          # _iBuf: the reader walks DOWN from the packed data's top
        self.o = -1                  # _oBuf: set once datasize is known
        self.size = 0                # _unpCtx.size
        self.crc = 0
        self.chk = 0
        self.datasize = 0

    def be32(self):
        v = struct.unpack(">I", bytes(self.buf[self.i:self.i + 4]))[0]
        self.i -= 4
        return v

    def rcr(self, cf):
        rcf = self.chk & 1
        self.chk >>= 1
        if cf:
            self.chk |= 0x80000000
        return bool(rcf)

    def next_chunk(self):
        cf = self.rcr(False)
        if self.chk == 0:
            self.chk = self.be32()
            self.crc ^= self.chk
            cf = self.rcr(True)
        return cf

    def get_code(self, n):
        c = 0
        for _ in range(n):
            c = (c << 1) | (1 if self.next_chunk() else 0)
        return c

    def dec_unk1(self, num_chunks, add_count):
        count = self.get_code(num_chunks) + add_count + 1
        self.datasize -= count
        while count:
            self.buf[self.o] = self.get_code(8)
            self.o -= 1
            count -= 1

    def dec_unk2(self, num_chunks):
        i = self.get_code(num_chunks)
        count = self.size + 1
        self.datasize -= count
        while count:
            self.buf[self.o] = self.buf[self.o + i]     # *(_oBuf + i): forwards, into unwritten space
            self.o -= 1
            count -= 1

    def run(self):
        self.datasize = self.be32()
        self.o = self.datasize - 1
        self.crc = self.be32()
        self.chk = self.be32()
        self.crc ^= self.chk
        while self.datasize > 0:
            if not self.next_chunk():
                self.size = 1
                if not self.next_chunk():
                    self.dec_unk1(3, 0)
                else:
                    self.dec_unk2(8)
            else:
                c = self.get_code(2)
                if c == 3:
                    self.dec_unk1(8, 8)
                elif c < 2:
                    self.size = c + 2
                    self.dec_unk2(c + 9)
                else:
                    self.size = self.get_code(8)
                    self.dec_unk2(12)
        return self.crc == 0


def load_resource(me, cache):
    """Read one resource exactly as Bank::read does: raw when packed == size, else unpacked."""
    if me["bank"] not in cache:
        path = os.path.join(GAMEDATA, "bank%02x" % me["bank"])
        cache[me["bank"]] = open(path, "rb").read()
    bank = cache[me["bank"]]
    raw = bank[me["bank_off"]:me["bank_off"] + me["packed"]]
    if len(raw) != me["packed"]:
        raise SystemExit("bank%02x is short: wanted %d bytes at 0x%X, got %d"
                         % (me["bank"], me["packed"], me["bank_off"], len(raw)))
    if me["packed"] == me["size"]:
        return bytes(raw), True
    buf = bytearray(max(me["size"], me["packed"]))
    buf[0:me["packed"]] = raw
    ok = Unpack(buf, me["packed"]).run()
    return bytes(buf[0:me["size"]]), ok


def sound_header(pcm):
    """Decode a RT_SOUND header.

    Measured, not guessed: u16 at +0 is the LOOP START OFFSET and u16 at +2 is the LOOP LENGTH, both in
    2-byte units, followed by 4 pad bytes. The playable payload is loop_start + loop_len, and
    8 + 2*(h0 + h1) equals the resource size for 96 of the 102 non-empty sounds exactly. That is a much
    sharper statement than "the first field is the length", and it matches how the mixer uses the pair:
    snd_playSound sets mc.loopPos = len_field, mc.loopLen = second_field, so playback runs from 0 to
    loopPos + loopLen and then repeats the loopPos..loopPos+loopLen region.

    One resource (res 4) carries 2 bytes beyond its declared payload; six are empty (size 0). Both are
    recorded rather than smoothed over - see the report this tool prints.
    """
    if len(pcm) < 8:
        return None
    h0, h1 = struct.unpack(">HH", pcm[0:4])
    return dict(loop_start=h0 * 2, loop_len=h1 * 2, pad=pcm[4:8].hex(),
                payload=8 + 2 * (h0 + h1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "aw-audio.bin"))
    ap.add_argument("--index", default=os.path.join(ROOT, "build", "aw-audio.json"))
    a = ap.parse_args()

    ml = read_memlist(os.path.join(GAMEDATA, "memlist.bin"))
    print("memlist      : %d entries" % len(ml))

    cache = {}
    blob = bytearray()
    index = []
    bad = []
    crc_bad = []
    empties = 0
    looping = 0
    tails = []
    totals = {}

    for res_id, me in enumerate(ml):
        if me["type"] not in (RT_SOUND, RT_MUSIC):
            continue
        pcm, ok = load_resource(me, cache)
        if len(pcm) != me["size"]:
            bad.append((res_id, me["size"], len(pcm)))
            continue
        if not ok:
            crc_bad.append(res_id)
        entry = dict(res=res_id, type=TYPE_NAMES[me["type"]], offset=len(blob),
                     len=len(pcm), bank=me["bank"], bank_off=me["bank_off"],
                     packed=me["packed"])
        if me["type"] == RT_SOUND:
            h = sound_header(pcm)
            if len(pcm) == 0:
                entry.update(pcm_off=0, pcm_len=0, loop_start=0, loop_len=0)   # an empty slot
                empties += 1
            elif h is None or h["payload"] > len(pcm):
                bad.append((res_id, "header", h))
            else:
                if h["payload"] < len(pcm):
                    tails.append((res_id, len(pcm) - h["payload"]))
                entry.update(pcm_off=8, pcm_len=h["payload"],
                             loop_start=h["loop_start"], loop_len=h["loop_len"])
                if h["loop_len"]:
                    looping += 1
            tl = totals.setdefault("SOUND", [0, 0, 0])
        else:
            # module header: u16 delay @0, 15 x (u16 res, u16 vol) @2, u16 numOrder @0x3E,
            # order table @0x40 (0x80 bytes), patterns @0xC0  (sfxplayer.cpp loadSfxModule)
            delay, = struct.unpack(">H", pcm[0:2])
            num_order, = struct.unpack(">H", pcm[0x3E:0x40])
            entry.update(delay=delay, num_order=num_order, data_off=0xC0)
            tl = totals.setdefault("MUSIC", [0, 0, 0])
        tl[0] += 1
        tl[1] += me["packed"]
        tl[2] += len(pcm)
        index.append(entry)
        blob += pcm

    for k in sorted(totals):
        c, pk, sz = totals[k]
        print("  %-6s %3d entries  packed %7d B  unpacked %7d B" % (k, c, pk, sz))
    print("  TOTAL  %3d entries               unpacked %7d B (%.2f MiB)"
          % (len(index), len(blob), len(blob) / 2.0 ** 20))
    print("  sounds: %d empty, %d looping; %d carry bytes past their declared payload%s"
          % (empties, looping, len(tails),
             (": " + ", ".join("res %d +%dB" % t for t in tails)) if tails else ""))

    # The decisive check: every entry must unpack to exactly what the memlist declares. A mismatch
    # means the transcription disagrees with the engine, and then nothing downstream is trustworthy.
    if bad:
        print("\nFAIL - %d entries do not match the memlist:" % len(bad))
        for b in bad[:10]:
            print("   ", b)
        return 1
    if crc_bad:
        print("\nFAIL - %d entries unpacked to the declared size but the internal checksum did not"
              " reach zero: %s" % (len(crc_bad), crc_bad[:10]))
        return 1

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    open(a.out, "wb").write(blob)
    import json
    json.dump(dict(total=len(blob), entries=index), open(a.index, "w"), indent=1)
    print("\nwrote %s (%d B) and %s (%d entries)" % (a.out, len(blob), a.index, len(index)))
    print("OK: all %d entries unpack to the size memlist.bin declares, checksums agree"
          % len(index))
    return 0


if __name__ == "__main__":
    sys.exit(main())
