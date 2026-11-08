#!/usr/bin/env python3
"""Aggregate the audio events harvested from simulation logs.

    python3 scripts/audio_events.py build/logs/soc-harvest-*.log

tb_soc prints one SNDEVT / MUSEVT line per event (not a sample: two sounds can fire inside one 10 ms
diagnostic interval, and a sampled monitor would report the later one twice). This turns those lines into
the requirement table the mixer and the tracker are built against.

RANGE CHECKS ARE PART OF THE TOOL, not a courtesy: the invalid byte scan of this same data produced resId
308 and freq 255 against 103 real sounds and a mixer assertion of freq < 40. Any value outside the legal
range means the decode is wrong, so it is reported as an error rather than quietly contributing to a table.
"""
import collections
import re
import sys

NUM_SOUNDS = 103        # RT_SOUND entries in memlist.bin
NUM_MEMLIST = 146
FREQ_LIMIT = 40         # vm.cpp: assert(freq < 40)
CHANNELS = 4

SND = re.compile(r"SNDEVT (\d+) res=(\d+) freq=(\d+) vol=(\d+) ch=(\d+) frame=(\d+)")
MUS = re.compile(r"MUSEVT (\d+) num=(\d+) delay=(\d+) pos=(\d+) frame=(\d+)")


def main(paths):
    sounds = collections.Counter()          # (res, freq, vol, ch) -> count
    music = collections.Counter()           # (num, delay, pos) -> count
    per_part = collections.defaultdict(lambda: [0, 0])
    used_res = set()
    stops = collections.Counter()
    stopped = set()
    used_mus = set()
    freqs, vols, chans = collections.Counter(), collections.Counter(), collections.Counter()
    bad = []

    for p in paths:
        tag = p.rsplit("/", 1)[-1]
        for line in open(p, errors="replace"):
            m = SND.search(line)
            if m:
                _, res, freq, vol, ch, _f = (int(x) for x in m.groups())
                per_part[tag][0] += 1
                if res >= NUM_MEMLIST or freq >= FREQ_LIMIT or ch >= CHANNELS:
                    bad.append((tag, "SNDEVT", res, freq, ch))
                    continue
                # vol == 0 is a STOP, not a silent play: vm.cpp snd_playSound does
                #     if (vol == 0) mixer->stopChannel(channel); else play...
                # The harvest shows it often (res=106 vol=0 on all four channels, res=48 vol=0 on three),
                # so a mixer that played these at zero volume would leave channels running forever and
                # the next sound on that channel would be mixed against a stale one.
                if vol == 0:
                    stops[ch] += 1
                    stopped.add(ch)
                    continue
                sounds[(res, freq, vol, ch)] += 1
                used_res.add(res)
                freqs[freq] += 1
                vols[vol] += 1
                chans[ch] += 1
                continue
            m = MUS.search(line)
            if m:
                _, num, delay, pos, _f = (int(x) for x in m.groups())
                per_part[tag][1] += 1
                if num >= NUM_MEMLIST:
                    bad.append((tag, "MUSEVT", num, delay, pos))
                    continue
                music[(num, delay, pos)] += 1
                if num:
                    used_mus.add(num)

    print("%-34s %8s %8s" % ("log", "sounds", "music"))
    for tag in sorted(per_part):
        print("%-34s %8d %8d" % (tag, per_part[tag][0], per_part[tag][1]))

    print("\nchannel stops (vol == 0, i.e. stopChannel): %d events, channels %s"
          % (sum(stops.values()), sorted(stopped)))
    print("\ndistinct sounds (res, freq, vol, ch): %d" % len(sounds))
    for (res, freq, vol, ch), n in sorted(sounds.items()):
        print("   res=%-3d freq=%-2d vol=%-2d ch=%d   x%d" % (res, freq, vol, ch, n))
    print("  distinct resources requested: %d of %d extracted" % (len(used_res), NUM_SOUNDS))
    print("  freq indices used: %s" % sorted(freqs))
    print("  volumes used      : %s" % sorted(vols))
    print("  channels used     : %s" % sorted(chans))

    print("\ndistinct music (num, delay, pos): %d" % len(music))
    for (num, delay, pos), n in sorted(music.items()):
        # sfxplayer.cpp does `_delay * 60 / 7050` in INTEGER ms, and 15700 gives 133 - not the 134 a rounded
        # float reports. The plan carried the rounded number for a day and the tracker had to be told
        # otherwise, so print what the original actually runs at.
        rate = "%d ms/event" % (delay * 60 // 7050) if num and delay else "-"
        print("   num=%-3d delay=%-6d pos=%-2d  x%d  %s" % (num, delay, pos, n, rate))
    print("  music modules actually started: %s  (RT_MUSIC entries are 7, 137, 138)" % sorted(used_mus))

    if bad:
        print("\nFAIL - %d events outside the legal ranges, so the decode is wrong:" % len(bad))
        for b in bad[:10]:
            print("   ", b)
        return 1
    print("\nOK - every harvested event is inside the legal ranges")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
