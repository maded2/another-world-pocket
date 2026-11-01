#!/bin/bash
# Install build 1042a as its own identity (Eddie Chan.AW 1042) WITHOUT deleting 1040/1041.
#
# Why this one keeps its predecessors on the card. The three of them are a controlled experiment
# about one wire, and the only instrument that can see the difference is the Pocket itself: in
# simulation the modelled PSRAM answers fast enough that part1 shows zero stream restarts, so all
# three deliver identical bytes and the bench calls them the same. Hardware disagrees:
#
#   1040 (888b1c05..) resumes a drained stream at the acceptance's FIRST byte.
#                 The 64-byte bytecode fill loop (vm.si:491) does
#                    data.addr = data.wenable ? (data.addr + 1) : 0
#                 so a gap resets the CONSUMER's write pointer to 0 and continuing at the top
#                 matches it: the intro PLAYS. op_drawString (vm.si:935) keeps pix_waddr across
#                 gaps, so re-serving it shifts every later row: the text is SHEARED ~4 px/row.
#   1041 (5b7ab7d5..) resumes at the next byte owed. drawString is happy: the text is STRAIGHT.
#                 The fill is not: its byte for base+0x2c lands at fill[0], the interpreter runs
#                 the tail of the buffer as opcodes, and the intro FREEZES at ~10 s, at the same
#                 place every launch (leds/opcode 0x80, page swaps stop).
#   1042 (this one)  picks per consumer. Bit 20 of the acceptance address says who is asking -
#                 drawString and the boot-header read set it (vm.si: `(1<<20) | ...`), a bytecode
#                 fill never does (segBytecode is off0, and the boot check requires off0 == 0) -
#                 so a fill restarts where its write pointer went (the top) and a strip continues
#                 at the next byte owed. Plus PREFILL_WORDS 32 -> 40 words, so a 63-byte fill has
#                 17 bytes it cannot run out of; that alone took part0's restarts from 405 to 326.
#
# tb_soc now decides this on the CONSUMER's landing addresses rather than on the wire: every byte
# the VM writes into its own 64-byte fill buffer is checked against the pack byte that belongs at
# that address. Same forced-gap stimulus for all three: 1042 = 0 shifted writes out of 102,114 and
# the page keeps swapping; 1041 = 121 of 282 shifted and never a swap; 1040 = coherent fills but
# 105 wrong bytes where the consumer really is positional.
#
# WHAT THIS BUILD IS FOR, on the screen: does the intro play past a minute, and are the captions
# straight? Both, or it is not fixed. See the card at the bottom of this script's output.
#
set -u

CARD=""
for m in /media/*/*; do
    [ -d "$m/Cores" ] && { CARD="$m"; break; }
done
if [ -z "$CARD" ]; then
    echo "FATAL: no Pocket SD card found (looked for a /media/*/*/Cores directory)." >&2
    echo "       Nothing was written. Insert the card and re-run - a 'successful' install into a" >&2
    echo "       stale mount point or a build/ staging tree is how a core gets reported shipped" >&2
    echo "       while it is still on the laptop." >&2
    exit 1
fi
echo "card: $CARD"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NEWBS="$REPO/build/aw/bitstream.rbf_r"
[ -f "$NEWBS" ] || { echo "FATAL: missing fresh bitstream $NEWBS - run: make build CORE_DIR=cores/aw"; exit 1; }

NEWSHA=$(sha256sum < "$NEWBS" | cut -d' ' -f1)
echo "new bitstream sha: $NEWSHA"
case "$NEWSHA" in
    888b1c05*) echo "FATAL: build/aw/bitstream.rbf_r is still 1040a (resume at c_start: sheared text). Rebuild."; exit 1 ;;
    5b7ab7d5*) echo "FATAL: build/aw/bitstream.rbf_r is still 1041a (resume at c_addr for everyone: intro freezes at ~10 s). Rebuild."; exit 1 ;;
    2e47de15*) echo "FATAL: build/aw/bitstream.rbf_r is the buggy 1026a/1027 bitstream"; exit 1 ;;
    e0253e0d*) echo "FATAL: build/aw/bitstream.rbf_r is still 1028b"; exit 1 ;;
    96ac5f82*) echo "FATAL: build/aw/bitstream.rbf_r is still 1029a"; exit 1 ;;
    dc97747b*) echo "FATAL: build/aw/bitstream.rbf_r is still 1030a"; exit 1 ;;
    85b2e26e*) echo "FATAL: build/aw/bitstream.rbf_r is still 1031a"; exit 1 ;;
esac

SRC="$REPO/cores/aw"
for f in core.json data.json audio.json input.json interact.json variants.json \
         video.json info.txt loader.bin; do
    [ -f "$SRC/$f" ] || { echo "FATAL: missing $SRC/$f (loader.bin is built by: make loader)"; exit 1; }
done
echo "source: $SRC"

# Archive the identities that are already on the card BEFORE touching anything. These folders
# have been the only surviving copy of a measured build more than once, and build/aw/ overwrites
# its bitstream on every compile.
mkdir -p "$REPO/build/bitstreams"
for d in "$CARD/Cores/Eddie Chan.AW "*; do
    [ -d "$d" ] || continue
    [ -f "$d/bitstream.rbf_r" ] || continue
    tag=$(basename "$d" | tr ' ' '_')
    cp "$d/bitstream.rbf_r" "$REPO/build/bitstreams/$tag.rbf_r"
    echo "archived  $(basename "$d") -> build/bitstreams/$tag.rbf_r ($(sha256sum < "$REPO/build/bitstreams/$tag.rbf_r" | cut -c1-8))"
done

DST="$CARD/Cores/Eddie Chan.AW 1042"
if [ -e "$DST" ]; then
    echo "$DST already exists - replacing it (its bitstream was archived above)"
    rm -rf "$DST"
fi
mkdir -p "$DST"
cp "$SRC"/core.json "$SRC"/loader.bin "$SRC"/data.json \
   "$SRC"/audio.json "$SRC"/input.json "$SRC"/interact.json "$SRC"/variants.json \
   "$SRC"/video.json "$SRC"/info.txt "$DST"/
cp "$NEWBS" "$DST/bitstream.rbf_r"
echo "installed into: $DST"

# Every block below ends `|| exit 1` because this script runs with `set -u` and NOT `set -e`:
# 1041a's first run printed DONE. after a failing python block, which is how a folder named
# Eddie Chan.AW 1041 ended up carrying the repo's shortname - folder != author.shortname is a core
# the Pocket cannot launch. A safety check that cannot stop the script is a print statement.
python3 - "$DST/core.json" <<'EOF' || { echo "FATAL: could not rewrite $DST/core.json"; exit 1; }
import json, sys
p = sys.argv[1]
d = json.load(open(p))
md = d["core"]["metadata"]
md["shortname"] = "AW 1042"
md["version"] = "1.0.0"
md["date_release"] = "2026-11-01"
md["description"] = ("Another World - build 1042a: a restarted ROM stream now resumes where "
                     "the consumer that is waiting actually is, instead of one address for "
                     "everybody. The bytecode fill loop (vm.si:491) resets its own write "
                     "pointer on any cycle without data_available, so continuing it at the "
                     "next byte owed lands every later byte shifted and the interpreter runs "
                     "ROM data as opcodes - the ~10 s intro freeze of 1041a. op_drawString "
                     "(vm.si:935) keeps its pixel pointer across gaps, so re-serving it is "
                     "what sheared the text in 1040a. Address bit 20 separates them exactly. "
                     "Also buffers 40 words before a held acceptance instead of the bare 32 a "
                     "63-byte fill needs, which took part0's stream restarts from 405 to 326. "
                     "Still carries 1040a's whole-pack census, so the CHK line answers 'is the "
                     "2 MiB in the chip the 2 MiB that was sent': Z.0 <sum_r>/<sum_w>, and "
                     "dd744c92 for part1.bin. Compare against 1040 and 1041, both of which are "
                     "left on this card on purpose.")

json.dump(d, open(p, "w"), indent=4)
print("core.json updated: shortname=%r version=%s" % (md["shortname"], md["version"]))
EOF

# Fail here, not on the Pocket: the launch path is built from author.shortname.
python3 - "$DST/core.json" "$(basename "$DST")" <<'EOF' || exit 1
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
echo "=== the comparison this card carries ==="
for d in "$CARD/Cores/Eddie Chan.AW "*; do
    [ -d "$d" ] || continue
    printf '  %-28s %s\n' "$(basename "$d")" "$(sha256sum < "$d/bitstream.rbf_r" | cut -c1-16)"
done

echo
echo "=== packs ==="
# The packs are game content or the host has nothing to load ("Total loadsize is 0", 2026-10-14).
# The layout the OS reads is Assets/anotherworld/common/partN.bin; the older note about this
# globbed Assets/anotherworld/*.bin only, and warned on a correctly provisioned card - a warning
# that is always on stops being read, so both locations are looked at.
PACKS="$(ls "$CARD"/Assets/anotherworld/common/*.bin "$CARD"/Assets/anotherworld/*.bin 2>/dev/null)"
if [ -z "$PACKS" ]; then
    echo "WARNING: no partN.bin under $CARD/Assets/anotherworld[/common] - the data slot will be"
    echo "         empty and the core sits on the white blink block. Copy them with:"
    echo "           mkdir -p '$CARD/Assets/anotherworld/common' &&"
    echo "           cp ports/another-world/packs/part*.bin '$CARD/Assets/anotherworld/common/'"
else
    echo "packs on card: $(echo "$PACKS" | wc -l) file(s):"
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

cat <<'HWTEST'

DONE. Eject, put the card back in the Pocket, boot.

Start a UART capture BEFORE launching:
    python3 scripts/capture_serial.py /dev/ttyUSB1
Expect "AW 1042a up" and then the CHK line ending  Z.0 dd744c92/dd744c92  for part1.bin
(Z. + both sums equal to the file = the 2 MiB in the chip is the 2 MiB that was sent; if that
is not true this run tells you nothing about the stream).

WHAT TO WATCH - two questions, and 1042a claims yes to both. Launch AW 1042 and leave it alone:

  1. DOES THE INTRO PLAY PAST A MINUTE?  1041a stopped at ~10 s, in the same place every launch,
     with the picture frozen while the video kept running. Run it twice: "same place every time"
     is the signature of a deterministic fill shift, not of a flaky card.
  2. IS ANY TEXT STRAIGHT?  1040a drew every caption with ~4 px of leftward shear per row. Any
     dialog or full-screen caption answers it. 1042a re-serves bytes only for a bytecode fill,
     which is the one consumer whose own pointer went back to zero, so the shear must be gone.

Then, for the record, launch 1040 and 1041 again and confirm they still do what the table in this
script's header says. If a predecessor behaves differently from its entry, the identity table is
wrong and this build's result is uninterpretable - re-derive it by bitstream hash, not by label.

HOW LONG TO WATCH: the freeze appeared at ~10 s, so 60 s of unbroken intro is 6x the margin. If
it survives a minute, drive the game (start, dpad, jump) for two more minutes: the copy
protection and the first gameplay segment use long op_drawString strips, which is where the shear
would show, and where the palette corner this build knowingly accepts would show as wrong colours
rather than as a stop.

A NEW symptom is as valuable as a fix. Wrong colours in one palette = the known corner. Straight
text that stops anyway = the freeze has a second cause and the fill oracle in tb_soc can be aimed
at it directly.
HWTEST
