#!/usr/bin/env python3
"""Build the music bench's stimulus and expectation table from the image.

Three files in <out>:
  blob.hex   the audio blob, one byte per line - the bench serves it at AUDIO_BASE
  idx.hex    the image's index region (0x1000 upward), the RAM the resolver and the tracker share
  expect.txt one line per mixer command the RTL must issue, in order, SEVEN integers per line so the bench
             can read it with one fscanf regardless of the event kind:
               kind ch f1 f2 f3 f4 f5   (kind 0 = volume-only, 1 = play, 2 = stop, 3 = marker; unused = 0)
             A fixed layout rather than text: a bench that parses four different line shapes has four ways to
             mis-parse, and a mis-parsed expectation looks exactly like a broken design.
  info.txt   module, delay, numOrder, first-note tick - for the bench's banner

The inc in P is derived exactly as the RTL derives it: freq = 7159092/(period*2), inc = (freq<<8)/48000,
both integer divisions. The oracle computes the same two divisions, so a mismatch here would be an RTL bug,
not a rounding difference.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_tracker


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--blob", default="build/aw-audio.bin")
    ap.add_argument("--index", default="build/aw-audio.json")
    ap.add_argument("--res", type=int, default=7)
    ap.add_argument("--delay", type=int, default=0)
    ap.add_argument("--pos", type=int, default=0)
    ap.add_argument("--ticks", type=int, default=1100)
    ap.add_argument("--audio-base", type=lambda s: int(s, 0), default=0x2F0000)
    ap.add_argument("--image", default="build/aw-all-audio.bin")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    blob = open(args.blob, "rb").read()
    import json
    index = {e["res"]: e for e in json.load(open(args.index))["entries"]}

    mod = ref_tracker.Module(args.res, blob[index[args.res]["offset"]:
                                            index[args.res]["offset"] + index[args.res]["len"]],
                             index, blob, memset=False)

    with open(os.path.join(args.out, "blob.hex"), "w") as fh:
        for b in blob:
            fh.write("%02x\n" % b)

    # the index region exactly as aw_audio_idx stores it: the image's bytes from 0x1000
    img = open(args.image, "rb").read() if args.image else None
    cnt = blob and index
    with open(os.path.join(args.out, "idx.hex"), "w") as fh:
        if img:
            n = 4 + img[0x1001] * 16
            for b in img[0x1000:0x1000 + n]:
                fh.write("%02x\n" % b)
        else:
            fh.write("%02x\n" % 0x41)

    tr = ref_tracker.Tracker(mod, args.pos, args.delay)
    lines = []
    first_play = None
    ticks_run = 0
    for t in range(args.ticks):
        evs = tr.tick()
        ticks_run = t + 1
        for ev in evs:
            if ev[0] == "VOL":
                lines.append("0 %d %d 0 0 0 0" % (ev[1], ev[2]))
            elif ev[0] == "PLAY":
                _, ch, freq, vol, res, length, loop_pos, loop_len = ev
                inc = (freq << 8) // 48000
                e = index[res]
                base = args.audio_base + e["offset"] + e["pcm_off"]
                lines.append("1 %d %d %d %d %d %d" % (ch, inc, length, loop_pos, loop_len, base))
                if first_play is None:
                    first_play = t
            elif ev[0] == "STOP":
                lines.append("2 %d 0 0 0 0 0" % ev[1])
            elif ev[0] == "MARK":
                lines.append("3 %d %d 0 0 0 0" % (ev[1], ev[2]))
            elif ev[0] == "STOPALL":
                for ch in range(4):
                    lines.append("2 %d 0 0 0 0 0" % ch)
        if tr.finished:
            break

    with open(os.path.join(args.out, "expect.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")

    with open(os.path.join(args.out, "info.txt"), "w") as fh:
        fh.write("res %d\nticks %d\n%d\n" % (args.res, ticks_run, first_play if first_play is not None else -1))

    print("music scenario: module %d, %d ticks, %d commands, first PLAY at tick %s, tick %d ms"
          % (args.res, ticks_run, len(lines), first_play, tr.delay_ms))


if __name__ == "__main__":
    main()
