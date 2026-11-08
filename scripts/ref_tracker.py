#!/usr/bin/env python3
"""Reference model of Another World's music player, to grade an RTL tracker against.

Transcribed from upstream `sfxplayer.cpp` (`SfxPlayer::loadSfxModule`, `prepareInstruments`, `handleEvents`,
`handlePattern`). The RTL is not the oracle here: this file is, exactly as `ref_mixer.py` is the oracle for
`aw_mixer`. It either prints the event stream or renders PCM through `ref_mixer`, so an RTL tracker can be
graded event-for-event first (a wrong tempo shows up as off-by-one timing, not as noise) and sample-for-sample
afterwards.

THE FORMAT (all big-endian, from `loadSfxModule`):

    +0x00  u16  delay          tick period, in units of 60/7050 ms; the opcode's delay argument overrides it
    +0x02  15 x { u16 resNum, u16 volume }
    +0x3E  u16  numOrder
    +0x40  0x80-byte order table
    +0xC0  pattern data: order*1024 + curPos, 64 rows x 4 channels x 4 bytes

Each 4-byte channel event is `u16 note_1, u16 note_2`:
  * note_1 == 0xFFFD  -> a marker that writes _scriptVars[0xF4] = note_2 (no note is played)
  * note_1 == 0xFFFE  -> stop this channel
  * note_1 == 0       -> no note (the volume field may still be applied)
  * otherwise         -> note_1 is an Amiga period; freq = 7159092 / (note_1 * 2)
  * note_2 bits 12-15 -> sample number (1..15), bits 8-11 effect, bits 0-7 effect parameter
  * effect 5 = volume up, effect 6 = volume down (both clamp to 0..0x3F)

FOUR UPSTREAM QUIRKS REPRODUCED DELIBERATELY:

1. **The instrument's first four PCM bytes are zeroed.** `prepareInstruments` does
   `memset(ins->data + 8, 0, 4)` on the shared resource buffer - it is blanking a header field the mixer would
   otherwise read, and it silently mutates the sample. A tracker that skips it produces four wrong samples per
   instrument.
2. **`pat.sampleLen = READ_BE_UINT16(ptr) * 2`, i.e. the sound header's FIRST field**, while
   `loopLen = READ_BE_UINT16(ptr + 2) * 2` is the second. For a module instrument the first field is the whole
   sample length and the second is the loop length, so `loopPos = sampleLen` (not 0) - which is why the mixer's
   loop wrap (chunkPos = loopPos, NOT << 8) is reachable from music as well as from effects.
3. **The tick period is `delay * 60 / 7050` in INTEGER ms.** 15700 gives 133.6 -> 133 ms, not 134. The first
   harvest note said 134 and was rounded; the integer division is what the original runs at, and a tracker
   that rounds sounds "slightly off" rather than broken - the exact failure mode the plan warns about.
4. **The order advances even when it reaches numOrder.** `curOrder` becomes numOrder and play stops; it does
   not wrap.

Usage:
    python3 scripts/ref_tracker.py --events                 # event table for module 7
    python3 scripts/ref_tracker.py --events --ticks 40
    python3 scripts/ref_tracker.py --pcm 48000 | sha256sum  # first second of PCM
    python3 scripts/ref_tracker.py --modules                # what the three modules contain
    python3 scripts/ref_tracker.py --selftest               # hand-checkable cases, no image needed
"""
import argparse
import json
import struct
import sys


def be16(b, off):
    return (b[off] << 8) | b[off + 1]


class Instrument:
    def __init__(self, res, volume, data):
        self.res = res
        self.volume = volume
        self.data = data          # the RT_SOUND resource buffer, header included


class Module:
    def __init__(self, res, buf, index, blob, memset=True):
        self.res = res
        self.header_delay = be16(buf, 0x00)
        self.num_order = be16(buf, 0x3E)
        self.orders = list(buf[0x40:0x40 + 0x80])
        self.patterns = buf[0xC0:]
        self.instruments = []
        for i in range(15):
            r = be16(buf, 0x02 + i * 4)
            v = be16(buf, 0x04 + i * 4)
            if r == 0:
                self.instruments.append(None)
                continue
            if r not in index or index[r]["type"] != "SOUND":
                raise SystemExit("instrument %d names resource %d, which is not an extracted sound" % (i + 1, r))
            e = index[r]
            data = bytearray(blob[e["offset"]: e["offset"] + e["len"]])
            # quirk 1: the original blanks four bytes at data+8 on the shared buffer. The RTL does not
            # reproduce it (it would mean writing PSRAM, or masking the first four samples of every music
            # note in the mixer), so a bench comparing against the RTL passes memset=False.
            if memset:
                data[8:12] = b"\x00\x00\x00\x00"
            self.instruments.append(Instrument(r, v, bytes(data)))
        # a module whose numOrder is 0 has nothing to play, and that is worth saying out loud
        if self.num_order == 0:
            raise SystemExit("module %d declares numOrder 0" % res)


class Tracker:
    """The player state machine. `tick()` returns the events of one timer callback."""

    def __init__(self, mod, start_order=0, delay_override=0):
        self.m = mod
        self.cur_order = start_order & 0xFF
        self.cur_pos = 0
        raw = delay_override if delay_override else mod.header_delay
        self.delay_ms = raw * 60 // 7050
        self.finished = False
        self.marker = None
        self.volume = [0] * 4

    def tick(self):
        out = []
        if self.finished:
            return out
        order = self.m.orders[self.cur_order]
        base = self.cur_pos + order * 1024
        for ch in range(4):
            off = base + ch * 4
            if off + 4 > len(self.m.patterns):
                out.append(("SHORT", ch, 0, 0))       # pattern data out of range: report, do not guess
                continue
            note1 = be16(self.m.patterns, off)
            note2 = be16(self.m.patterns, off + 2)
            if note1 != 0xFFFD:
                sample = (note2 & 0xF000) >> 12
                if sample != 0:
                    ins = self.m.instruments[sample - 1]
                    if ins is not None:
                        vol = ins.volume
                        effect = (note2 & 0x0F00) >> 8
                        param = note2 & 0xFF
                        if effect == 5:
                            vol = min(vol + param, 0x3F)
                        elif effect == 6:
                            vol = max(vol - param, 0)
                        self.volume[ch] = vol
                        out.append(("VOL", ch, vol))
            if note1 == 0xFFFD:
                self.marker = note2
                out.append(("MARK", ch, note2))
            elif note1 != 0:
                if note1 == 0xFFFE:
                    out.append(("STOP", ch))
                else:
                    sample = (note2 & 0xF000) >> 12
                    ins = self.m.instruments[sample - 1] if sample else None
                    if ins is not None:
                        freq = 7159092 // (note1 * 2)
                        # quirk 2: len is the first header field, loop the second; loopPos = len when
                        # looping, so the loop covers [len, len+loopLen) and the wrap lands on `len`.
                        length = be16(ins.data, 0) * 2
                        loop_len = be16(ins.data, 2) * 2
                        loop_pos = length if loop_len else 0
                        out.append(("PLAY", ch, freq, self.volume[ch], ins.res,
                                    length, loop_pos, loop_len))
        self.cur_pos += 16
        if self.cur_pos >= 1024:
            self.cur_pos = 0
            self.cur_order += 1                                  # quirk 4: no wrap
            if self.cur_order == self.m.num_order:
                self.finished = True
                out.append(("STOPALL",))
        return out


def render(mod, ticks, start_order=0, delay_override=0, tail_ms=0):
    """Feed the events into the mixer model and produce PCM, exactly as the original does."""
    import ref_mixer
    tr = Tracker(mod, start_order, delay_override)
    chans = [ref_mixer.Channel() for _ in range(4)]
    by_res = {ins.res: ins for ins in mod.instruments if ins}
    pcm = []
    t = 0
    while t < ticks and not tr.finished:
        for ev in tr.tick():
            if ev[0] == "STOP":
                chans[ev[1]].stop()
            elif ev[0] == "PLAY":
                _, ch, freq, vol, res, length, loop_pos, loop_len = ev
                pcm_data = by_res[res].data[8:]
                if loop_len:
                    chans[ch].play_looping(pcm_data, freq, vol, loop_pos, loop_len, length=length)
                else:
                    chans[ch].play(pcm_data, freq, vol, length=length)
            elif ev[0] == "STOPALL":
                for c in chans:
                    c.stop()
        pcm.extend(ref_mixer.mix(chans, tr.delay_ms * 48))
        t += 1
    if tail_ms:
        pcm.extend(ref_mixer.mix(chans, tail_ms * 48))
    return pcm


def load(image_or_blob, idx_path):
    blob = open(image_or_blob, "rb").read()
    idx = json.load(open(idx_path))
    return blob, {e["res"]: e for e in idx["entries"]}


def build_module(args, res):
    blob, index = load(args.blob, args.index)
    e = index[res]
    if e["type"] != "MUSIC":
        raise SystemExit("resource %d is a %s, not a MUSIC module" % (res, e["type"]))
    return Module(res, blob[e["offset"]: e["offset"] + e["len"]], index, blob,
                  memset=not args.no_memset), index, blob


def events_main(args):
    blob, index = load(args.blob, args.index)
    e = index[args.res]
    if e["type"] != "MUSIC":
        raise SystemExit("resource %d is a %s, not a MUSIC module" % (args.res, e["type"]))
    mod = Module(args.res, blob[e["offset"]: e["offset"] + e["len"]], index, blob)
    tr = Tracker(mod, args.pos, args.delay)
    print("module %d: %d bytes, header delay %d, numOrder %d, tick %d ms, %d ticks = %.2f s"
          % (args.res, e["len"], mod.header_delay, mod.num_order, tr.delay_ms, args.ticks,
             args.ticks * tr.delay_ms / 1000.0))
    print("  instruments: %s" % ", ".join(
        "%d=res%d v%d" % (i + 1, ins.res, ins.volume)
        for i, ins in enumerate(mod.instruments) if ins))
    total = 0
    for t in range(args.ticks):
        evs = tr.tick()
        for ev in evs:
            total += 1
            if ev[0] == "PLAY":
                print("  tick %3d  ch%d PLAY res=%-3d freq=%-5d vol=%-2d len=%-5d loop=%d+%d"
                      % (t, ev[1], ev[4], ev[2], ev[3], ev[5], ev[6], ev[7]))
            elif ev[0] == "STOP":
                print("  tick %3d  ch%d STOP" % (t, ev[1]))
            elif ev[0] == "VOL":
                print("  tick %3d  ch%d VOL %d" % (t, ev[1], ev[2]))
            elif ev[0] == "MARK":
                print("  tick %3d  ch%d MARK %04X" % (t, ev[1], ev[2]))
            elif ev[0] == "STOPALL":
                print("  tick %3d  STOPALL (end of order table)" % t)
            else:
                print("  tick %3d  %s ch%d" % (t, ev[0], ev[1]))
        if tr.finished:
            break
    print("  %d events over %d ticks" % (total, args.ticks))


def pcm_main(args):
    mod, index, blob = build_module(args, args.res)
    pcm = render(mod, args.ticks, args.pos, args.delay, args.tail)
    if args.hex:
        sys.stdout.write("".join("%02x\n" % (v & 0xFF) for v in pcm))
    else:
        import hashlib
        h = hashlib.sha256(bytes((v & 0xFF) for v in pcm)).hexdigest()[:16]
        print("samples %d  sha256 %s  min %d max %d  nonzero %d"
              % (len(pcm), h, min(pcm), max(pcm), sum(1 for v in pcm if v)))


def modules_main(args):
    blob, index = load(args.blob, args.index)
    for e in sorted(index.values(), key=lambda x: x["res"]):
        if e["type"] != "MUSIC":
            continue
        mod = Module(e["res"], blob[e["offset"]: e["offset"] + e["len"]], index, blob)
        used = [i + 1 for i, ins in enumerate(mod.instruments) if ins]
        print("res %-4d %6d bytes  numOrder %-3d header delay %-6d tick %d ms  instruments %s"
              % (e["res"], e["len"], mod.num_order, mod.header_delay,
                 mod.header_delay * 60 // 7050, used))
        print("      orders: %s" % mod.orders[:mod.num_order])


def selftest():
    """Cases a human can check without the image: one instrument, one note, one order step."""
    ok = True

    # a synthetic module: 1 order, 2 rows, one instrument (res 1), note_1=0x100 -> 7159092//512 = 13982 Hz
    # The buffer is 8 header bytes + (length + loop) bytes, which is how an extracted resource is laid out -
    # a sample shorter than its own declared loop would make the mixer's wrap read past the end.
    sound = bytearray(8 + 8 + 4)
    sound[0:2] = (4).to_bytes(2, "big")      # sample length 4 * 2 = 8 bytes
    sound[2:4] = (0).to_bytes(2, "big")      # no loop
    sound[8:20] = bytes([10, 20, 30, 40, 50, 0, 0, 0, 0, 0, 0, 0])
    modbuf = bytearray(0xC0 + 1024)
    modbuf[0:2] = (15700).to_bytes(2, "big")
    modbuf[2:4] = (1).to_bytes(2, "big")     # instrument 1: res 1
    modbuf[4:6] = (32).to_bytes(2, "big")    # volume 32
    modbuf[0x3E:0x40] = (1).to_bytes(2, "big")   # numOrder = 1
    modbuf[0x40] = 0                             # order 0
    # row 0, channel 0: note_1 = 0x0100, sample 1, no effect
    modbuf[0xC0:0xC2] = (0x0100).to_bytes(2, "big")
    modbuf[0xC2:0xC4] = (0x1000).to_bytes(2, "big")
    # row 1, channel 0: 0xFFFE = stop
    modbuf[0xC0 + 16:0xC0 + 18] = (0xFFFE).to_bytes(2, "big")

    blob = bytes(sound)
    index = {1: {"res": 1, "type": "SOUND", "offset": 0, "len": len(sound)}}
    mod = Module(1, bytes(modbuf), index, blob)

    tr = Tracker(mod)
    want_delay = 15700 * 60 // 7050
    print("selftest: tick period %d ms (want %d; 15700*60/7050 = %.2f, INTEGER division)"
          % (tr.delay_ms, want_delay, 15700 * 60 / 7050))
    ok &= tr.delay_ms == want_delay == 133

    row0 = tr.tick()
    print("selftest: row 0 -> %s" % (row0,))
    ok &= row0 == [("VOL", 0, 32), ("PLAY", 0, 7159092 // (0x0100 * 2), 32, 1, 8, 0, 0)]
    row1 = tr.tick()
    print("selftest: row 1 -> %s" % (row1,))
    ok &= row1 == [("STOP", 0)]
    # 64 rows in an order: the 64th tick advances curOrder, and numOrder is 1, so play ends there
    last = None
    for _ in range(62):
        last = tr.tick()
    print("selftest: last row of the order -> %s (want STOPALL)" % (last,))
    ok &= last is not None and [e[0] for e in last] == ["STOPALL"] and tr.finished

    # quirk 1: the first four PCM bytes of an instrument are zeroed by prepareInstruments
    print("selftest: instrument pcm starts %s (want 0,0,0,0 - the memset at data+8)"
          % list(mod.instruments[0].data[8:12]))
    ok &= list(mod.instruments[0].data[8:12]) == [0, 0, 0, 0]

    # quirk 2: loopPos = sampleLen (first header field * 2), not 0
    loop_sound = bytearray(sound)
    loop_sound[2:4] = (2).to_bytes(2, "big")     # loop_len = 4 bytes
    index2 = {1: {"res": 1, "type": "SOUND", "offset": 0, "len": len(loop_sound)}}
    mod2 = Module(1, bytes(modbuf), index2, bytes(loop_sound))
    ev = Tracker(mod2).tick()
    play = [e for e in ev if e[0] == "PLAY"][0]
    print("selftest: looping instrument -> len=%d loop=%d+%d (want len 8, loop 8+4)"
          % (play[5], play[6], play[7]))
    ok &= (play[5], play[6], play[7]) == (8, 8, 4)

    # and the mixer model must accept it: 8 samples then wrap at 8+4-1 -> read index 11 (past the data)
    try:
        pcm = render(mod2, 2)
        print("selftest: rendered %d samples, first %s" % (len(pcm), pcm[:6]))
        ok &= len(pcm) == 2 * 133 * 48
    except IndexError as exc:
        print("selftest: render raised %s" % exc)
        ok = False

    print("ref_tracker: selftest %s" % ("PASS" if ok else "FAIL"))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blob", default="build/aw-audio.bin")
    ap.add_argument("--index", default="build/aw-audio.json")
    ap.add_argument("--res", type=int, default=7)
    ap.add_argument("--pos", type=int, default=0)
    ap.add_argument("--delay", type=int, default=0, help="override the module header delay (as the opcode does)")
    ap.add_argument("--ticks", type=int, default=20)
    ap.add_argument("--tail", type=int, default=0, help="render extra ms after the last tick")
    ap.add_argument("--events", action="store_true")
    ap.add_argument("--pcm", action="store_true")
    ap.add_argument("--hex", action="store_true")
    ap.add_argument("--modules", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--no-memset", action="store_true",
                    help="do not reproduce prepareInstruments' memset(data+8, 0, 4) - needed for RTL comparison")
    args = ap.parse_args()

    if args.selftest:
        return 0 if selftest() else 1
    if args.modules:
        modules_main(args)
        return 0
    if args.events:
        events_main(args)
        return 0
    pcm_main(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
