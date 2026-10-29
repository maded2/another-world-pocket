#!/bin/bash
# Install diagnostic build 1037a as a FRESH core identity (Eddie Chan.AW 1037).

# 1037a = instrumentation, no functional change. 1036a booted clean on hardware:
#   C0:0003aed30000268f0001255d00000000 ... D=a5a5 B=a55a N=a5a5 R=0000 P=0004
# with the CHK field identical every second (the check ran once and stopped, which is how
# rom_ready is known to have risen) - the pack in the chip is the pack in the file. The
# panel stayed BLACK, so the question moved to the render side, and everything under it
# now reports success on silicon. The CHK line grows five fields to answer it directly:
#   V<frames> F<de pulses in the last complete frame> L<non-black pixels in that frame>
#   Y<ROM bytes streamed to the VM> X<status bits>
# X = {0, saw_hs, saw_vs, inmenu, design_run, video_sel, suppress, rom_ready}.
# Reading the line:
#   V=0, saw_vs=0            the SoC's video generator is not running (clock/reset).
#   V>0, F=0                 it scans no active pixels at all.
#   V>0, F=fa00, L=0         it scans a full 320x200 window of black - pages/palette.
#   V>0, F=fa00, L>0         the picture is being produced: then it is the mux/scaler.
#   Y stuck at ~0            the VM is not fetching: held off or stuck, not a display fault.
#
# 1036a was the upload byte order. 1035a proved the chip: D=a5a5 B=a55a N=a5a5 on hardware,
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
                echo "       32-bit entry byte-reversed - rebuild before installing 1037a"
                exit 1 ;;
    212c477e*) echo "ERROR: build/aw/bitstream.rbf_r is still 1036a (no video counters) -"
                echo "       rebuild before installing 1037a"; exit 1 ;;
esac

# Metadata and the loader come from the repo, which is where they are written - earlier
# installers copied them out of whatever the previous card folder happened to be, which
# made the candidate list something to bump every build. 1037's list was written before
# 1036 was on a card and the install stopped with "no source folder", so the indirection
# is gone: cores/aw/*.json is the source of truth and the identity below is patched into
# it after copying.
SRC="$REPO/cores/aw"
for f in core.json data.json audio.json input.json interact.json variants.json \
         video.json info.txt loader.bin; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" \
                          "(loader.bin is built by: make loader)"; exit 1; }
done
echo "source: $SRC"

DST="$CARD/Cores/Eddie Chan.AW 1037"
if [ -e "$DST" ]; then
    echo "$DST already exists - removing first"
    rm -rf "$DST"
fi
mkdir -p "$DST"
cp -v "$SRC"/core.json "$SRC"/loader.bin "$SRC"/data.json \
      "$SRC"/audio.json "$SRC"/input.json "$SRC"/interact.json "$SRC"/variants.json \
      "$SRC"/video.json "$SRC"/info.txt "$DST"/
cp -v "$NEWBS" "$DST/bitstream.rbf_r"

# new identity in core.json: shortname + version + date so no cached entry can match
python3 - "$DST/core.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
md = d["core"]["metadata"]
md["shortname"] = "AW 1037"
md["version"] = "1.0.0"
md["date_release"] = "2026-10-29"
md["description"] = ("Another World - diagnostic build 1037a: video/VM counters on the CHK "
                     "line (V frames, F de per frame with fa00 = a full 320x200 window, "
                     "L non-black per frame, Y ROM bytes streamed to the VM, X status bits "
                     "{0,saw_hs,saw_vs,inmenu,design_run,video_sel,suppress,rom_ready}). "
                     "part1.bin should give C0:0003aed30000268f0001255d00000000 with "
                     "D=a5a5 B=a55a N=a5a5 R=0000 P=0004 and V counting up.")
json.dump(d, open(p, "w"), indent=4)
print("core.json updated: shortname=%r version=%s" % (md["shortname"], md["version"]))
EOF

# Remove every other diagnostic identity, so the menu has exactly one AW entry - two
# entries is a mislaunch waiting to happen, and a launch of the wrong one reads as a
# failed experiment. Archive each bitstream first: these folders have been the only
# surviving copy of a measured build more than once (build/ overwrites it next compile).
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

# Fail here, not on the Pocket: the launch path is built from author.shortname, so a
# core.json that did not get patched does not merely look wrong in the OSD, it never
# loads at all (that is how this install script's own bug shipped a dead core once).
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
echo "DONE. Eject, put the card back in the Pocket, boot, and launch 'AW 1037'."
echo "Start a UART capture BEFORE launching: python3 scripts/capture_serial.py /dev/ttyUSB1"
echo "Expect: 'AW 1037a up', then C0:000000005d2501008f260000d3ae0300 ... D=a5a5 B=a55a"
echo "N=a5a5 R=0000 P=0004 V<frames> F<de/frame> L<lit/frame> Y<rom bytes> X<status>."
