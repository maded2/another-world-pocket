#!/bin/bash
# Install build 1040a as a FRESH core identity (Eddie Chan.AW 1040).
#
# 1040a asks the question the black first launch left open: **is the 2 MiB in the chip the
# 2 MiB that was sent?** 1038a on hardware was the first animated picture, and its report had
# a shape nothing in the design could explain - first launch after power-on black
# (F=fa00 a full window scanned, L=0 every pixel black, Y climbing ~9x too fast: a VM
# executing something that was not the game), quit and relaunch fine. The upload's own
# counters said complete: 524,284 matched writes for a 2,097,136-byte file, C0 trailer, P=0004.
# Those counters count *addresses in range*, not data committed, and the only two real
# read-backs in the whole design were word 0 and the trailer. Everything in between had never
# been looked at as a whole.
#
# So aw_rom now does a whole-pack census: the write side accumulates every 16-bit word it
# commits (sum, xor, four quarters) and records the high-water address; once the upload is in,
# one read-only sweep goes back over exactly that range through the self-test's sequencer and
# accumulates again. Equal means the chip holds the file. It costs ~126 ms with the VM still in
# reset, once per power-on, with a stall watchdog and a budget so a diagnostic can never
# become the reason the core does not boot. Reported on the CHK line as
#
#   Z<census> <qmism> <read-sum>/<written-sum>
#
#   '.' written == read, and both equal the file   -> the 2 MiB is intact, look elsewhere
#   '!' mismatch, with <qmism> naming the quarter(s) that differ
#   'T' the sweep stopped making progress and gave up        'P' not run yet (the sweep needs ~126 ms)
#
# What it found while being written, and what 1040a also fixes: the acceptance signal
# `wr_taken = wr_req & wr_ready` was shared by the two bus masters. The self-test forces
# wr_req for its own probe write while the loader's drain sits in D_RUN; the drain saw
# wr_taken, advanced, and consumed a word whose address and data never reached the chip -
# three 16-bit words lost every probe round (5,520 words = 11,040 bytes apart, matching the
# 444 us ST_PERIOD exactly). Six bytes of the pack per probe round, in a bench that had been
# passing 510 checks. Each master now takes its own acceptance (d_taken / st_taken), and
# tb_rom's census proves the whole pack arrives; the same live byte-check in tb_soc went from
# 9 errors on the 1038a netlist - a cascade reading 5a, the model's power-up pattern, i.e. a
# region nobody had written - to none.
#
# Also in this build, two things that were waiting behind it:
#   - ST_WAIT now times out. The sequencer is shared, so a probe whose readback never arrived
#     did not just lose a probe: st_active gates the producer, so the ROM path was starved for
#     the rest of the power cycle. A probe unanswered in ~0.7 ms is a failed probe.
#   - The PSRAM request flag is registered. Unregistered, the stream FIFO's occupancy compare
#     (synchronised pointer -> grey-to-binary -> subtract -> compare) sat in front of the
#     controller's chip-facing output registers and build 1039a failed STA by -0.385 ns on it.
#     One flop ends that comparison beside the FIFO; FETCH_HEADROOM (7 words) against at most
#     two reads in flight pays for the cycle of staleness.
#
# Two more things this tree fixed after the first build, both found by `make check-build`
# rather than by simulation: the quarter index was `addr[CEN_QSHIFT+1 +: 2]`, which selects bits
# [20:19] of a 20-bit word address, so quarters 2 and 3 of the census could never accumulate
# (the fitter said `cw_q[2][*] - Stuck at GND`, and `tb_rom` now fails if any quarter is still
# zero after a clean sweep — putting the `+1` back makes it fail, as it must); and the sweep
# registers carried the die-select bit they can never reach.
#
# Expected bitstream (built 2026-10-31 10:26, Quartus 22.1std.2, all corners positive:
# psram setup +1.217 ns slow-85C, worst anywhere +0.126 ns, 4,775 ALMs / 26%):
#
#   build/aw/bitstream.rbf_r   sha256 888b1c056d70ec4aac7492c1524561e1a038adc8fac694b4da9b5987daf68d03
#
# If the sha this script prints is not that, the tree moved after the build: rebuild and re-run
# the gate rather than installing a bitstream you cannot name.

# ---------------------------------------------------------------------------
# WHAT TO LOOK FOR ON THE WIRE  (part1.bin; scripts/capture_serial.py before launching)
#
#   AW 1040a up
#   C0:000000005d2501008f260000d3ae0300 <match>/<all> Da5a5 Ba55a Na5a5 R0000 P0004
#       V<frames> F<de/frame> L<lit/frame> Y<rom bytes> X<status> Z.<q> <sum_r>/<sum_w>
#
# The two numbers at the end are the whole point, and they are known in advance: the census
# sums little-endian 16-bit words over exactly the range the upload wrote (0xffff8 words for
# every part file), so for part1.bin both sides should read
#
#   Z.0 dd744c92/dd744c92
#
#   dd744c92   sum of the 1,048,568 16-bit words of part1.bin (python3: sum(struct.unpack
#              ('<1048568H', open('part1.bin','rb').read())) & 0xffffffff)
#   part0 3d05a6cb  part1 dd744c92  part2 cc836d51  part3 06e27bde
#   part4 f0f9552e  part5 9cace960  part6 fccf3bab  part7 7213f501
#
# Reading it:
#   Z.0 dd744c92/dd744c92   the chip holds the file. The black first launch is NOT the upload,
#                           and the search stays on the boot/VM side.
#   Z!1 <a>/<b>             mismatch in quarter 1 of the pack; <a> read, <b> written. The
#                           quarter is address bits [19:18] of the word index, so it names a
#                           range directly: quarter q covers words [q*0x40000, (q+1)*0x40000) -
#                           256 Ki words, 512 KiB each, quarter 0 = bytes 0x00000-0x7ffff.
#   Z.0 <a>/<b> with a != b and the file matching <b>   the writes never all committed - the
#                           1039a class of bug, still alive on silicon.
#   Z.0 <a>/<b> with the file matching <cw> only        the chip is losing data after the
#                           write (refresh/timing), which no write-side counter can see.
#   ZT                      the sweep stalled: the read path is the suspect, not the pack.
#   ZP forever              the census never armed (no upload completed -> look at C/S fields).
# ---------------------------------------------------------------------------

set -u

CARD=""
for m in /media/*/*; do
    [ -d "$m/Cores" ] && { CARD="$m"; break; }
done
[ -n "$CARD" ] || { echo "no Pocket SD card found under /media"; exit 1; }
echo "card: $CARD"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NEWBS="$REPO/build/aw/bitstream.rbf_r"
[ -f "$NEWBS" ] || { echo "missing fresh bitstream: $NEWBS (run the Quartus build first)"; exit 1; }

NEWSHA=$(sha256sum < "$NEWBS" | cut -d' ' -f1)
echo "new bitstream sha: $NEWSHA"
case "$NEWSHA" in
    2e47de15*) echo "ERROR: build/aw/bitstream.rbf_r is the buggy 1026a/1027 bitstream"; exit 1 ;;
    e0253e0d*) echo "ERROR: build/aw/bitstream.rbf_r is still 1028b - rebuild first"; exit 1 ;;
    96ac5f82*) echo "ERROR: build/aw/bitstream.rbf_r is still 1029a - rebuild first"; exit 1 ;;
    dc97747b*) echo "ERROR: build/aw/bitstream.rbf_r is still 1030a (broken self-test capture) - rebuild first"; exit 1 ;;
    85b2e26e*) echo "ERROR: build/aw/bitstream.rbf_r is still 1031a (address-echo reads) - rebuild first"; exit 1 ;;
    961af5f6*) echo "ERROR: build/aw/bitstream.rbf_r is still 1032a (seven-cycle reads) - rebuild first"; exit 1 ;;
    1b355fb4*) echo "ERROR: build/aw/bitstream.rbf_r is still 1033a (three-probe matrix) - rebuild first"; exit 1 ;;
    4d821411*) echo "ERROR: build/aw/bitstream.rbf_r is still 1034a (control-signal search, byte enables still wrong on reads) - rebuild first"; exit 1 ;;
    cab279d6*) echo "ERROR: build/aw/bitstream.rbf_r is still 1035a, which stores every"
                echo "       32-bit entry byte-reversed"; exit 1 ;;
    212c477e*) echo "ERROR: build/aw/bitstream.rbf_r is still 1036a (no video counters)"; exit 1 ;;
    139d08ee*) echo "ERROR: build/aw/bitstream.rbf_r is still 1037a, which decodes the palette as rgb565"; exit 1 ;;
    0694cdae*) echo "ERROR: build/aw/bitstream.rbf_r is still 1038a - it has no census, so it"
                echo "       cannot answer the question this install is asking"; exit 1 ;;
    b7f1364a*) echo "ERROR: build/aw/bitstream.rbf_r is still 1039a, which FAILS STA by"
                echo "       -0.385 ns on the psram clock; do not put it on a card"; exit 1 ;;
esac

# Metadata and the loader come from the repo, which is where they are written; the identity
# below is patched into the copy after it lands.
SRC="$REPO/cores/aw"
for f in core.json data.json audio.json input.json interact.json variants.json \
         video.json info.txt loader.bin; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" \
                          "(loader.bin is built by: make loader)"; exit 1; }
done
echo "source: $SRC"

DST="$CARD/Cores/Eddie Chan.AW 1040"
if [ -e "$DST" ]; then
    echo "$DST already exists - removing first"
    rm -rf "$DST"
fi
mkdir -p "$DST"
cp -v "$SRC"/core.json "$SRC"/loader.bin "$SRC"/data.json \
      "$SRC"/audio.json "$SRC"/input.json "$SRC"/interact.json "$SRC"/variants.json \
      "$SRC"/video.json "$SRC"/info.txt "$DST"/
cp -v "$NEWBS" "$DST/bitstream.rbf_r"

python3 - "$DST/core.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
md = d["core"]["metadata"]
md["shortname"] = "AW 1040"
md["version"] = "1.0.0"
md["date_release"] = "2026-10-31"
md["description"] = ("Another World - build 1040a: whole-pack census (every 16-bit word of the "
                     "upload summed as it is committed, then read back and summed again), so the "
                     "CHK line answers 'is the 2 MiB in the chip the 2 MiB that was sent': "
                     "Z.0 <sum_r>/<sum_w>, and for part1.bin both are dd744c92. Also fixes the "
                     "shared write-acceptance that lost six pack bytes per self-test probe round, "
                     "and a hung self-test probe that starved the ROM path for the whole power "
                     "cycle. Expect C0:0003aed30000268f0001255d00000000 D=a5a5 B=a55a N=a5a5 "
                     "R=0000 P=0004 and Z.0 dd744c92/dd744c92.")
json.dump(d, open(p, "w"), indent=4)
print("core.json updated: shortname=%r version=%s" % (md["shortname"], md["version"]))
EOF

# Remove every other diagnostic identity so the menu has exactly one AW entry; archive each
# bitstream first (these folders have been the only surviving copy of a measured build more
# than once - build/ overwrites it next compile).
for d in "$CARD/Cores/Eddie Chan.AW "*; do
    [ -d "$d" ] || continue
    [ "$d" = "$DST" ] && continue
    if [ -f "$d/bitstream.rbf_r" ]; then
        mkdir -p "$REPO/build/bitstreams"
        tag=$(basename "$d" | tr ' ' '_')
        cp "$d/bitstream.rbf_r" "$REPO/build/bitstreams/$tag.rbf_r"
        echo "archived  $d bitstream -> build/bitstreams/$tag.rbf_r"
    fi
    echo "removing old identity: $d"
    rm -rf "$d"
done

# Fail here, not on the Pocket: the launch path is built from author.shortname.
python3 - "$DST/core.json" "$(basename "$DST")" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
md = d["core"]["metadata"]
want = "%s.%s" % (md["author"], md["shortname"])
if want != sys.argv[2]:
    sys.exit("FATAL: folder %r is not author.shortname %r - the OS would launch %r and fail"
             % (sys.argv[2], want, want))
print("identity verified: folder == %r" % want)
EOF

echo
echo "=== verify new folder ==="
ls -la "$DST"
echo -n "bitstream sha: "; sha256sum < "$DST/bitstream.rbf_r" | cut -c1-16

# The packs are game content and must be on the card or the host has nothing to load ("Total
# loadsize is 0", 2026-10-14). The layout the OS reads is Assets/anotherworld/common/partN.bin -
# a check that only globbed Assets/anotherworld/*.bin warned on a correctly provisioned card,
# and a warning that is always on stops being read, so both locations are looked at.
PACKS="$(ls "$CARD"/Assets/anotherworld/common/*.bin "$CARD"/Assets/anotherworld/*.bin 2>/dev/null)"
if [ -z "$PACKS" ]; then
    echo "WARNING: no partN.bin under $CARD/Assets/anotherworld[/common] - the data slot will be"
    echo "         empty and the core sits on the white blink block. Copy them with:"
    echo "           mkdir -p '$CARD/Assets/anotherworld/common' &&"
    echo "           cp ports/another-world/packs/part*.bin '$CARD/Assets/anotherworld/common/'"
else
    echo "packs on card: $(echo "$PACKS" | wc -l) file(s), including"
    echo "$PACKS" | grep -o 'part[0-9]*\.bin' | sort -u | tr '\n' ' '; echo
fi

# re-clear the five catalog caches so the fresh core is picked up (KB-056)
TS=$(date +%Y%m%d-%H%M%S)
BK="$REPO/build/sd/system-backup-$TS"
if [ -d "$CARD/System" ]; then
    mkdir -p "$BK" && cp -a "$CARD/System/." "$BK/" && echo "backed up /System -> $BK"
    for f in core_viewby_platform.bin corelist_cache.bin cores_cache.bin \
             platform_viewby_category.bin platforms_cache.bin; do
        [ -f "$CARD/System/$f" ] && rm -v "$CARD/System/$f"
    done
fi
sync
echo
echo "DONE. Eject, put the card back in the Pocket, boot, and launch 'AW 1040'."
echo "Start a UART capture BEFORE launching: python3 scripts/capture_serial.py /dev/ttyUSB1"
echo "Expect 'AW 1040a up', then the CHK line ending  Z.0 dd744c92/dd744c92  for part1.bin."
echo "Watch the first launch after power-on in particular - the census is the reason this build"
echo "exists, and a relaunch that works while the first fails is the thing it is measuring."
