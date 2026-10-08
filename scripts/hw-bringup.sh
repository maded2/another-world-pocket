#!/usr/bin/env bash
# Hardware bring-up worksheet: prints the sequence from docs/another-world/hardware-bringup.md
# with blanks to fill in on the device. No rebuild, no simulation - it exists so the five answers
# that close the hardware questions get written down instead of remembered.
#
#   scripts/hw-bringup.sh            print the worksheet
#   scripts/hw-bringup.sh --save     also write it to build/hw-bringup-<date>.md
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD="${SD:-$ROOT/build/sd/aw}"
PACKS="$ROOT/ports/another-world/packs"

sheet() {
cat <<'EOS'
ANOTHER WORLD - POCKET BRING-UP WORKSHEET          date: ________   fw: ________
Full text and failure meanings: docs/another-world/hardware-bringup.md

SCREEN LEGEND (before rom_ready) - learn these, they turn a blank screen into an answer
  black, no sync .... core not running (layout / selection / platform id)
  white blink ....... alive, waiting for a pack
  RED  ERR_TRAILER .. offsets at len-16 are not a pack (wrong file, truncation, size)
  PURP ERR_OVERFLOW  bridge outran the chip (cram0 timing/contention)
  AMBR ERR_WAIT ..... chip never accepted anything (PSRAM clock/WAIT path)

1  APPEAR + SYNC
   core listed __  sync stable __  rolling/no-lock __
   -> proves: bitstream loads, PLL locks, video.json agrees with the pins

2  LOAD part1.bin (the intro) - TIME IT.  ***the number task #18 is gated on***
   seconds, file confirm -> first picture: ________ s   (=> ~________ KiB/s effective)
   aborted by timeout __ (declared 30000 ms)   screen colour if it failed: __________
   -> proves: bridge, 0180 data-slot path, cram0 writes at real rate, trailer boot check

3  INTRO PLAYS THROUGH
   reaches the end __  freezes at frame/time: ________  deterministic __
   colours look right vs build/sim/soc-frames __
   -> proves: sustained VM+loader coexistence on cram0, palette and page paths

4  INPUT  (bits per Analogue bus-communication docs; make sim-keys checks our mapping)
   d-pad left/right move hero __     d-pad up/down move hero __
   A fires __   B fires __
   START -> menu, hero does NOT move __      SELECT -> nothing in-game __
   (if d-pad does nothing or up fires, fix with -D AW_KEY_* ; do NOT touch the packing)

5  SOAK 15 min
   handheld: no drift __  no freeze __      docked: no drift __  no freeze __

6  DOCK + SUSPEND
   HDMI mirrors __   sleep claimed unsupported and OS restarts cleanly __
   wakes to a frozen frame __ (that would be wrong)

7  PART SWITCHING, SAME BITSTREAM
   part2 loads/plays __   part5 loads/plays __
   (part0.bin is the copy-protection screen: near-black by design, not a fault)

8  SAVE STATES
   OSD offers none __   anything attempted __

REPORT BACK (these five answers close or properly open tasks #18 and #29):
  a) part1 load seconds .......... ________
  b) colour on any failure ....... ________
  c) input table outcome ......... ________
  d) soak result ................. ________
  e) parts 2 and 5 on one core ... ________
EOS
}

echo "# what would be copied"
if [ -d "$SD" ]; then
    echo "# SD tree: $SD"
    find "$SD" -name 'bitstream.rbf_r' -printf '  bitstream %s bytes  %p\n' 2>/dev/null | head -2
else
    echo "# no $SD yet - run: make package CORE=aw" >&2
fi
if [ -d "$PACKS" ]; then
    echo "# packs (load part1.bin first; part0.bin is the protection screen)"
    (cd "$PACKS" && sha256sum part*.bin 2>/dev/null | cut -c1-12,66- | sed 's/^/  /')
fi
echo
if [ "${1:-}" = "--save" ]; then
    out="$ROOT/build/hw-bringup-$(date -u +%Y%m%d).md"
    mkdir -p "$ROOT/build"; sheet | tee "$out"
    echo "-> written $out"
else
    sheet
fi
