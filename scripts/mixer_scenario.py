#!/usr/bin/env python3
"""Generate the mixer bench scenario and the reference output, so RTL and oracle cannot disagree on input.

Writes into an output directory:
  samples.hex   the byte RAM the RTL reads (one 8-bit value per line)
  cmds.txt      one command per line: tick ch freq vol len looppos looplen base
  expect.hex    the reference output samples, one per line, signed decimal
  crc.txt       a checksum of expect.hex, for a quick eyeball

--perturb flips one expected sample, which the comparison MUST reject: a bit-exact bench that cannot fail
is decoration, and this project has already shipped one check that could not fail (a sha comparison against
a file the installer rewrites).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref_mixer as R

TICKS = 64
BASE_SIZE = 64
BASE0, BASE1 = 0, BASE_SIZE          # two waveforms in the same byte RAM




def waveforms():
    """Two 64-byte blocks at BASE0 and BASE1, with both signs so interpolation and truncation-toward-zero
    are exercised. Each block must be at least as long as its logical sample plus one byte, because the
    reader may fetch p2 = p1 + 1 just past the declared length."""
    ramp = (0, 10, -10, 100, -100, 127, -128, 40, -40, 0, 20, -20, 60, -60, 90, -90)
    w0 = [R.s8(v) for v in ramp * 4]                       # 64 bytes
    w1 = [R.s8(v) for v in (-128, 127, -127, 126, -64, 64, -32, 32) * 8]   # 64 bytes
    return bytes([v & 0xFF for v in (w0 + w1)])


def scenario():
    """(tick, ch, freqidx, vol, len, looppos, looplen, base) - the same list drives both sides."""
    w0_len, w1_len = 16, 16
    return [
        (0,  0, 20, 63, w0_len, 0,  0,  BASE0),   # single channel, plays once, rate 20
        (0,  1, 1,  45, w1_len, 4,  4,  BASE1),   # looping channel at rate 1
        (8,  2, 20, 32, w0_len, 0,  0,  BASE0),   # a third channel joins later
        (24, 3, 34, 10, w1_len, 0,  0,  BASE1),   # fourth channel, high rate index
        (40, 2, 0,  0,  0,      0,  0,  0),       # vol 0 -> STOP channel 2
        (48, 1, 0,  0,  0,      0,  0,  0),       # stop the looping channel
    ]


def build(outdir, perturb=False):
    os.makedirs(outdir, exist_ok=True)
    wf = waveforms()
    with open(os.path.join(outdir, "samples.hex"), "w") as fh:
        for b in wf:
            fh.write("%02x\n" % b)
    cmds = scenario()
    with open(os.path.join(outdir, "cmds.txt"), "w") as fh:
        for c in cmds:
            fh.write("%d %d %d %d %d %d %d %d\n" % c)

    chans = [R.Channel() for _ in range(4)]
    out = []
    for t in range(TICKS):
        for (ct, ch, freq, vol, ln, lp, ll, base) in cmds:
            if ct != t:
                continue
            if vol == 0:
                chans[ch].stop()
            else:
                data = wf[base:]                     # the whole RAM from the base: reads may run past len
                if ll:
                    chans[ch].play_looping(data, R.FREQ_TABLE[freq], vol, lp, ll, length=ln)
                else:
                    chans[ch].play(data, R.FREQ_TABLE[freq], vol, length=ln)
        out.append(R.mix(chans, 1)[0])

    if perturb:
        out[-1] = R.s8(out[-1] + 1)
    with open(os.path.join(outdir, "expect.hex"), "w") as fh:
        for v in out:
            fh.write("%d\n" % v)
    with open(os.path.join(outdir, "crc.txt"), "w") as fh:
        fh.write("ticks=%d sum=%d\n" % (len(out), sum(out)))
    return out


if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "build/mixer-scn"
    p = "--perturb" in sys.argv
    o = build(d, p)
    print("scenario -> %s  (%d ticks, sum %d%s)" % (d, len(o), sum(o), ", PERTURBED" if p else ""))
