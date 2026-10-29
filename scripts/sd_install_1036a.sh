#!/bin/bash
# Install diagnostic build 1036a as a FRESH core identity (Eddie Chan.AW 1036).

# 1036a = the upload byte order. 1035a proved the chip: D=a5a5 B=a55a N=a5a5 on hardware,
# the first real read-back from this PSRAM in nine builds. What was left was C1
# (ERR_TRAILER) and it was ours: the APF bridge carries the byte destined for the LOWEST
# address in the MOST significant byte of the 32-bit write (this core declares
# bridge_endian_little = 0, the template default, and data_loader.sv in
# analogue-pocket-utils - tested with that same declaration - maps bridge_wr_data
# 32'hAABBCCDD at address C to C<-AA, D<-BB, E<-CC, F<-DD). aw_rom took the payload
# little-endian, so every 32-bit entry was stored with its four bytes reversed. Measured
# on 1035a, exactly as that predicts:
#   P=e700    pack word 0 of part1.bin, whose file bytes are 04 00 -> little-endian 0x0004,
#             and 0xe700 is the reversed entry's first half;
#           offs_ok failed on off3=0xd3ae0300, which is the correct 0x0003aed3 written backwards;
#           D/B/N were green throughout because a round trip through a consistent wrong order
#           looks perfect - only the comparison against the FILE can see it.
# The benches had been feeding the design the order it assumed, which is why 510 checks
# passed a corrupt pack; they now model the wire (and reverting the design turn makes
# tb_write fail with 506 errors, so the guard is real).

# CHK line (same format as 1035):
#   C<err>:<32 hex trailer> <wr_match>/<wr_all> S<status> D<d> B<b> N<n> R<r> P<p>
#   expected on a working system:  C0000? no - err digit 0, trailer of part1 in file order,
#   D=a5a5  B=a55a  N=a5a5  R=0000 (CRE high mutes the part, as it should)  P=0004
#   For part1.bin the 32 hex digits should read 000000005d2501008f260000d3ae0300 - the
#   segoffsets 0, 0x1255d, 0x268f, 0x3aed3 with the first byte read at the top, and P=0004.
#   If C stays 1 with P=0004 the trailer path has a different problem; if the chip fields go
#   back to reading their own address, the card is running an older bitstream.

# Expected bitstream (build/aw/bitstream.rbf_r from a clean build of this tree):
#   see the sha printed at install time; 1035a was cab279d61af3a2df... and must NOT be
#   what installs here.

# Folder name = EXACTLY author.shortname from core.json (space preserved): the
# OS builds the launch path from the metadata, so a space-less name indexes but
# fails to launch. Also re-clears the five /System catalog caches (KB-056).
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

# sanity: the new bitstream must actually differ from every previous diagnostic
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
esac
case "$NEWSHA" in
    cab279d6*) echo "ERROR: build/aw/bitstream.rbf_r is still 1035a, which stores every"
                echo "       32-bit entry byte-reversed - rebuild before installing 1036a"
                exit 1 ;;
esac

# source for the JSON/loader files: prefer the newest diagnostic identity
SRC=""
for cand in "$CARD/Cores/Eddie Chan.AW 1035" "$CARD/Cores/Eddie Chan.AW 1034" \
            "$CARD/Cores/Eddie Chan.AW 1032" "$CARD/Cores/Eddie Chan.AW 1031" \
            "$CARD/Cores/Eddie Chan.AW 1030" "$CARD/Cores/Eddie Chan.AW 1029" \
            "$CARD/Cores/Eddie Chan.AW 1028" "$CARD/Cores/Eddie Chan.AW 1027" \
            "$CARD/Cores/Eddie Chan.Another World"; do
    [ -f "$cand/core.json" ] && { SRC="$cand"; break; }
done
[ -n "$SRC" ] || { echo "no source core folder found on card (need AW 1035/1034/1033/... or Another World)"; exit 1; }
echo "source: $SRC"

DST="$CARD/Cores/Eddie Chan.AW 1036"
if [ -e "$DST" ]; then
    echo "$DST already exists - removing first"
    rm -rf "$DST"
fi
mkdir -p "$DST"
cp -v "$SRC"/core.json "$SRC"/loader.bin "$SRC"/data.json \
      "$SRC"/audio.json "$SRC"/input.json "$SRC"/interact.json "$SRC"/variants.json \
      "$SRC"/video.json "$SRC"/info.txt "$DST"/ 2>/dev/null
cp -v "$NEWBS" "$DST/bitstream.rbf_r"

# new identity in core.json: shortname + version + date so no cached entry can match
python3 - "$DST/core.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
md = d["core"]["metadata"]
md["shortname"] = "AW 1036"
md["version"] = "1.0.0"
md["date_release"] = "2026-10-29"
md["description"] = ("Another World - diagnostic build 1036a (upload byte order fixed: the APF "
                     "wire carries the lowest-address byte at [31:24]; reads are byte-enabled and "
                     "twelve cycles). CHK: 'C<err>:<trailer hex> <wr_match>/<wr_all> S<status> "
                     "D<d> B<b> N<n> R<r> P<p>' - part1.bin should give "
                     "C0:000000005d2501008f260000d3ae0300 ... D=a5a5 B=a55a N=a5a5 R=0000 P=0004. "
                     "Same core as Eddie Chan.Another World.")
json.dump(d, open(p, "w"), indent=4)
print("core.json updated: shortname='AW 1035' version=1.0.0")
EOF

# remove the previous diagnostic identity so the menu has exactly one AW entry
OLD="$CARD/Cores/Eddie Chan.AW 1035"
[ -d "$OLD" ] && { echo "removing old identity: $OLD"; rm -rf "$OLD"; }

echo
echo "=== verify new folder ==="
ls -la "$DST"
echo -n "bitstream sha: "; sha256sum < "$DST/bitstream.rbf_r" | cut -c1-16

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
echo "DONE. Eject, put the card back in the Pocket, boot, and launch 'AW 1036'."
echo "Start a UART capture BEFORE launching: python3 scripts/capture_serial.py /dev/ttyUSB1"
echo "Expect: 'AW 1036a up', then C0:000000005d2501008f260000d3ae0300 ... D=a5a5 B=a55a"
echo "N=a5a5 R=0000 P=0004 for part1.bin, and rom_ready -> the idle grid switching to the game."
