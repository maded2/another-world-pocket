#!/bin/bash
# Install diagnostic build 1035a as a FRESH core identity (Eddie Chan.AW 1035).
#
# 1035a = the byte-enable fix. Nine builds of "every read returns the address we just
# drove" and the answer came from reading agg23's known-good Pocket PSRAM driver
# (analogue-pocket-utils ip/mem/psram.sv) against ours: UB#/LB# are OUTPUT ENABLES on
# this part. The reference asserts both for READS, held from the ADV# edge to the
# capture; we asserted them only for writes, so the chip spent every read in output
# deselect driving nothing, and a floating DQ keeps the last thing driven on it - the
# address. Hence T=f000 on every probe, both dies, every timing (1030-1033).
#
# Also in this build, from the same comparison:
#   * reads run twelve sequence cycles, not seven. Seven sampled 63 ns after ADV# AT THE
#     CHIP once this fabric's 7.4 ns clock-to-pin and the capture's setup are counted -
#     against a 70 ns datasheet maximum. Twelve gives ~117 ns of window and OE# low
#     ~86 ns (the reference, proven on this board, gets ~60 ns). The earlier note that
#     the reference "samples at ~75 ns" misread its state machine: it samples thirty
#     cycles (225 ns) after ADV#, and that bad number is what made seven look safe.
#   * aw_rom: a stale prefetch no longer blocks the stream FIFO's pop (it locked the read
#     path at twelve cycles per word), and the prefill gate now looks at who is actually
#     asking (host_rdy) instead of the VM's in_ready with the boot check exempt - the
#     exemption meant the trailer check rewound forever and rom_ready never rose.
#   * the cram0 set_max_delay bounds in core_constraints.sdc now match registers at all
#     (get_pins + the wrong hierarchy root meant TimeQuest dropped them in EVERY build,
#     332049), and the SDC now fails loudly if that collection is ever empty again.
#
# CHK line (same format as 1034, one field's meaning changed):
#   C<err>:<32 hex trailer> <wr_match>/<wr_all> S<status> D<d> B<b> N<n> R<r> P<p>
#   expected on a working chip:  D=a5a5  B=a55a  N=a5a5  R=a5a5  P=<pack word 0>
#     D : scratch round-trip, normal operation (a5a5 = the byte-enable fix works)
#     B : SAME word written again with only the LOW byte enabled -> a55a proves both
#         byte lanes and that the write mask masks (the loader needs that for every
#         upload entry that straddles a word boundary; probe A's a5a5 cannot show it)
#     N : the other physical die (normal "die 0" accesses assert CE1#)
#     R : CRE high instead of low
#     P : pack word 0 read back through the chip - 0004 for part1.bin = the upload
#         committed to PSRAM
#   A field that instead reads back its own address (f000 at D/B/N) means the part still
#   is not driving DQ. a5a5/a55a everywhere with a red screen means the chip path is fine
#   and what is left is above the controller.
#
# Expected bitstream (build/aw/bitstream.rbf_r from a clean build of this tree):
#   sha256 cab279d61af3a2df5ca6e72b12b855e77c5292b81486a6a74e26583a4ee51d64
# Quartus is not bit-reproducible across a re-run of the same source, so this is a
# "know what you are about to flash" note, not a gate - but if what installs is not
# that file, say so before blaming the card.
#
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
    cab279d6*) : ;;
    *) echo "note: this bitstream is not the cab279d6... build recorded for 1035a -"
       echo "      fine if the tree changed since, worth knowing before you flash" ;;
esac

# source for the JSON/loader files: prefer the newest diagnostic identity
SRC=""
for cand in "$CARD/Cores/Eddie Chan.AW 1034" "$CARD/Cores/Eddie Chan.AW 1033" \
            "$CARD/Cores/Eddie Chan.AW 1032" "$CARD/Cores/Eddie Chan.AW 1031" \
            "$CARD/Cores/Eddie Chan.AW 1030" "$CARD/Cores/Eddie Chan.AW 1029" \
            "$CARD/Cores/Eddie Chan.AW 1028" "$CARD/Cores/Eddie Chan.AW 1027" \
            "$CARD/Cores/Eddie Chan.Another World"; do
    [ -f "$cand/core.json" ] && { SRC="$cand"; break; }
done
[ -n "$SRC" ] || { echo "no source core folder found on card (need AW 1034/1033/1032/... or Another World)"; exit 1; }
echo "source: $SRC"

DST="$CARD/Cores/Eddie Chan.AW 1035"
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
md["shortname"] = "AW 1035"
md["version"] = "1.0.0"
md["date_release"] = "2026-10-29"
md["description"] = ("Another World - diagnostic build 1035a (PSRAM byte enables asserted on reads, "
                     "twelve-cycle reads: 'C<err>:<trailer hex> <wr_match>/<wr_all> S<status> "
                     "D<d> B<b> N<n> R<r> P<p>' - expect D=a5a5 B=a55a N=a5a5 R=a5a5 P=<pack0>. "
                     "Same core as Eddie Chan.Another World.")
json.dump(d, open(p, "w"), indent=4)
print("core.json updated: shortname='AW 1035' version=1.0.0")
EOF

# remove the previous diagnostic identity so the menu has exactly one AW entry
OLD="$CARD/Cores/Eddie Chan.AW 1034"
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
echo "DONE. Eject, put the card back in the Pocket, boot, and launch 'AW 1035'."
echo "Start a UART capture BEFORE launching: python3 scripts/capture_serial.py /dev/ttyUSB1"
echo "Expect: 'AW 1035a up', then CHK lines with D=a5a5 B=a55a N=a5a5 R=a5a5 P=<pack0>,"
echo "and rom_ready -> the idle screen switching to the game."
