#!/bin/bash
# Install build 1041a as a FRESH core identity (Eddie Chan.AW 1041).
#
# 1041a exists because of one sentence from the hardware run of 1040a: the text renders, but
# **every pixel line of it is offset to the left**. That is a strange complaint and it turned
# out to be exactly right, to the pixel.
#
# The chain, all of it measured (see docs/another-world/port-log.md, "the text shear"):
#
#  - op_drawString writes a text strip straight into a page: one byte off the ROM stream is one
#    destination pixel, 320 bytes to a row, and it holds mem.in_ready for the WHOLE strip (up to
#    200 rows = 64,000 bytes) while advancing pix_waddr once per byte.
#  - aw_rom's reader, when it could not hand over the next word, did `c_addr <= c_start`: back to
#    the address the acceptance began, handing out again bytes the VM had already consumed.
#  - Nothing tells the VM. It keeps counting, so every re-served byte shifted the strip.
#  - On the copy-protection screen the tb sees 405 restarts, each after EXACTLY 158 bytes: the
#    64-word stream FIFO plus the pipeline drains, because a PSRAM word costs ~140 ns while the
#    VM eats two bytes every ~80 ns. The 200-row strip therefore became the same 158-byte
#    pattern repeated - and 320 mod 158 = 4, so each row began four pixels further along the
#    pattern than the row above it. A leftward shear of ~4 px per line. That is the report.
#
# The fix is that the restart resumes at the word containing c_addr, the next byte the consumer
# has NOT been given. Nothing is repeated; a restart now costs ~140 ns and nothing else. The
# same recovery was silently re-feeding the boot check's shift register from the trailer start,
# which is one reason the trailer could fail to validate however well the chip answered.
#
# Why this was invisible for so long: the byte-exactness check in tb_soc reset its index on
# `u_rom.rewind`, mirroring the design instead of the consumer, so a repeated byte always
# "matched". It now keeps running across restarts, which is how the VM sees the stream, and a
# second oracle compares every text pixel's byte against the pack byte at src+k. On part0 after
# the fix: 405 restarts, 0 wrong bytes, 63,999 strip writes with drift=0 value=0 content=0 -
# every text pixel came from the correct pack byte. Before, the strip was 158 bytes on repeat.
#
# Carried from 1040a unchanged: the whole-pack census (the Z field), the per-master write
# acceptance, the self-test timeout, and the registered PSRAM request that closed STA.
#
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
    888b1c05*) echo "ERROR: build/aw/bitstream.rbf_r is still 1040a, which restarts a stalled
                echo "       stream at c_start and re-serves bytes the VM already consumed - that
                echo "       is the text shear. Rebuild first."; exit 1 ;;
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

DST="$CARD/Cores/Eddie Chan.AW 1041"
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
md["shortname"] = "AW 1041"
md["version"] = "1.0.0"
md["date_release"] = "2026-10-31"
md["description"] = ("Another World - build 1041a: fixes the sheared text. The ROM reader's
                     restart on a stalled word went back to the address the acceptance BEGAN and
                     re-handed-out bytes the VM had already consumed; op_drawString holds the
                     request for a whole 320-byte-per-row strip and keeps its own pixel pointer,
                     so the strip came out as the same 158-byte pattern repeated, each row
                     starting 320 mod 158 = 4 pixels further along it than the row above. The
                     restart now resumes at the word containing the next undelivered byte. Also
                     carries 1040a's whole-pack census, so the CHK line still answers
                     'is the 2 MiB in the chip the 2 MiB that was sent': Z.0 <sum_r>/<sum_w>,
                     and dd744c92 for part1.bin.")
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
echo "DONE. Eject, put the card back in the Pocket, boot, and launch 'AW 1041'."
echo "Start a UART capture BEFORE launching: python3 scripts/capture_serial.py /dev/ttyUSB1"
echo "Expect 'AW 1041a up', then the CHK line ending  Z.0 dd744c92/dd744c92  for part1.bin."
echo "The measurement this build asks for is on the SCREEN, not the wire: is the text straight?"
echo "Look at any dialog or full-screen caption and say whether the lines are still sheared. If"
echo "the shear is gone but the text is broken in a new way, that is still the answer - the"
echo "stream is now provably byte-exact in simulation, so what is left is elsewhere."
