#!/bin/bash
# Install the PAGED core as its own identity (Eddie Chan.AW 1044) and put the combined image on the
# card next to the eight single-part packs. AW 1042 is left exactly as it is: it is the only bitstream
# that has ever been proven on this hardware, and every claim about the paged build is measured
# against it.
#
# WHAT THIS RUN ANSWERS (task #15) - one question, and it is a question about the FRAMEWORK, not
# about our RTL: does the Pocket upload a dataslot file bigger than 2 MiB at all?
#
#   The whole eight-parts-in-one-load design rests on it. build/aw-all.bin is 3,080,192 bytes
#   (2.938 MiB): a 32 KiB directory page, then 93 pool pages. Nothing above 2 MiB has ever been
#   uploaded by anything - the window was widened to 4 MiB in 16fe39d and tb_dir +HIGH has written
#   above the old boundary in simulation since e171977, but the framework's behaviour is not
#   something a simulation of our own chip can tell us.
#
#   So this is a probe, and it is built to report even when it fails:
#
#   * If the whole file arrives, the census sums the pool and compares it against the sums the image
#     DECLARES in its header (pool_bytes words from page 1; aw-all.bin declares pool_bytes = 3,047,424
#     and wsum 9ca26b21 / wxor be39). pool_ok then reads 1 and the CHK line shows `G05 E00`.
#   * If the framework stops early, the directory page still arrives (it is at byte 0x8000, far below
#     any plausible limit), so the table installs, the core boots, and pool_ok reads 0: `G01`. The
#     `Z` field's quarter mask then says which quarter of the swept range disagrees, which puts the
#     cutoff inside a 1 MiB band instead of leaving it as a rumour.
#   * If the framework refuses the file outright (will not select it, or selects something else), the
#     sweep finds no AWP1 magic: `G00 E40`, which is what every plain 2 MiB pack has always shown.
#
#   A truncated upload does NOT brick anything. The table is valid, the boot trailer check passes
#   through the map, and part 0 plays - with garbage in whatever pages never arrived. That is a
#   wrong picture, not a hung one, and "what does the screen do" is part of what to report.
#
# Identity is the bitstream hash, verified below and again on the card after the copy. The banner
# says "AW 1044a" because dbg_console derives it from BUILD_ID; that string has lied for two releases
# before, so it is a convenience and not a proof.
#
set -u

# Set from the build that this probe is: sha256 of build/aw/bitstream.rbf_r. An installer that
# installs whatever happens to be in build/ is how 1026a got reported as 1028b.
EXPECT_SHA="${EXPECT_SHA:-a786f317510af3aa}"

CARD=""
for m in /media/*/*; do
    [ -d "$m/Cores" ] && { CARD="$m"; break; }
done
if [ -z "$CARD" ]; then
    echo "FATAL: no Pocket SD card found (looked for a /media/*/*/Cores directory)." >&2
    echo "       Nothing was written. Mount the card and re-run." >&2
    exit 1
fi
echo "card: $CARD"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/cores/aw"
BS="$REPO/build/aw/bitstream.rbf_r"
IMG="$REPO/build/aw-all.bin"

[ -f "$BS" ]  || { echo "FATAL: no bitstream at $BS - run: make build CORE_DIR=cores/aw"; exit 1; }
[ -f "$IMG" ] || { echo "FATAL: no combined image at $IMG - run: python3 scripts/build_combined_image.py -o build/aw-all.bin --packs ..."; exit 1; }

case "$EXPECT_SHA" in
    REPLACE_*) echo "NOTE: EXPECT_SHA is unset, so this installer cannot tell the paged build from"
               echo "      anything else sitting in build/aw. Pass EXPECT_SHA=<sha256 prefix>." ;;
esac

BSHA=$(sha256sum < "$BS" | cut -d' ' -f1)
echo "bitstream: $BSHA"
if [ "${EXPECT_SHA}" != "REPLACE_WITH_BUILD_SHA" ]; then
    case "$BSHA" in
        "${EXPECT_SHA}"*) ;;
        *) echo "FATAL: build/aw/bitstream.rbf_r is $BSHA, expected ${EXPECT_SHA}* - refusing to install" >&2
           echo "       something other than the audited build this probe was written for." >&2; exit 1 ;;
    esac
fi
# The two bitstreams that must never end up on a card under this name, by hash, because the folder
# label is not what runs on the hardware.
case "$BSHA" in
    579746d3*) echo "FATAL: that IS 1042 (the control). This installer would overwrite the control with itself." >&2; exit 1 ;;
    888b1c05*) echo "FATAL: that is 1040a (sheared text)." >&2; exit 1 ;;
    5b7ab7d5*) echo "FATAL: that is 1041a (intro freezes at ~10 s)." >&2; exit 1 ;;
    72be08bd*) echo "FATAL: that is the pre-census-default paged build (sweeps 2 MiB, certifies no pool)." >&2; exit 1 ;;
    b7e4190f*) echo "FATAL: that is the all-parts build with the dead ent_bad mask." >&2; exit 1 ;;
esac

ISHA=$(sha256sum < "$IMG" | cut -d' ' -f1)
ISIZE=$(stat -c%s "$IMG")
echo "image    : $ISHA  ($ISIZE bytes = $(python3 -c "print('%.3f' % ($ISIZE/2.0**20))") MiB)"
[ "$ISIZE" -eq 3080192 ] || echo "NOTE: image is $ISIZE bytes, not the 3,080,192 this probe was sized for."

DST="$CARD/Cores/Eddie Chan.AW 1044"
if [ -e "$DST" ]; then
    echo "FATAL: $DST already exists. Remove it deliberately (it may be the identity something else"
    echo "       was reported against); this script will not overwrite a core folder." >&2
    exit 1
fi
mkdir -p "$DST" || { echo "FATAL: could not create $DST (read-only mount?)"; exit 1; }

# The core folder: the JSONs and loader from the repo, the freshly built bitstream. Same file set as
# 1042, checked after the copy rather than assumed.
FILES="audio.json core.json data.json info.txt input.json interact.json loader.bin variants.json video.json"
for f in $FILES; do
    [ -f "$SRC/$f" ] || { echo "FATAL: $SRC/$f missing - the core folder would not boot"; exit 1; }
    cp "$SRC/$f" "$DST/$f" || { echo "FATAL: copy of $f failed"; exit 1; }
done
cp "$BS" "$DST/bitstream.rbf_r" || { echo "FATAL: bitstream copy failed"; exit 1; }

# Describe what this build is, in the OSD, the way 1042's installer did. Short name and description
# only - the framework reads core.json for the dataslot and the bitstream name, and silently ignores
# a description that is a lie, so it is written for the human.
python3 - "$DST/core.json" <<'PY'
import json, sys, datetime
p = sys.argv[1]
d = json.load(open(p))
m = d["core"]["metadata"]
m["shortname"] = "AW 1044"
m["description"] = (
    "Another World - paged build 1044a probe. One dataslot file can now carry every part: a 32 KiB "
    "directory page holds eight 64-entry page tables, and the VM's 2 MiB view is assembled from a "
    "pool of 93 frames on die 0. The part is selected by an address write before the VM's first byte "
    "and is a level the read path indexes, not an event to catch. The core checks the pool against "
    "the sums the image declares (pool_bytes words from page 1) and says what it found on UART: G "
    "is the part and its state (bit0 a table is installed, bit2 the pool matches what was declared), "
    "E is why a directory was refused. WHAT THIS ONE IS FOR: the file is 2.94 MiB, larger than any "
    "dataslot upload this port has ever attempted. If G reads 05 and E 00 the whole file arrived; "
    "01 means the directory arrived and the pool did not add up, and Z's quarter mask says where. "
    "AW 1042 is left on this card as the control and is the build to compare any picture against."
)
m["version"] = "1.0.0"
m["date_release"] = datetime.date.today().isoformat()
json.dump(d, open(p, "w"), indent=4)
print("core.json: shortname=%s version=%s" % (m["shortname"], m["version"]))
PY

# The probe file itself, next to the single-part packs. Named so it cannot be confused with a part:
# the OSD list is the interface, and "part8.bin" would be a lie about what it is.
ADF="$CARD/Assets/anotherworld/common"
[ -d "$ADF" ] || { echo "FATAL: $ADF does not exist - where does this card's platform look for files?"; exit 1; }
if [ -e "$ADF/aw-all.bin" ]; then echo "NOTE: overwriting $ADF/aw-all.bin"; fi
cp "$IMG" "$ADF/aw-all.bin" || { echo "FATAL: image copy failed"; exit 1; }

sync
echo
echo "verifying what is actually on the card (sha256, read back):"
fail=0
for f in $FILES; do
    a=$(sha256sum < "$SRC/$f" | cut -d' ' -f1); b=$(sha256sum < "$DST/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  ok   $f" || { echo "  FAIL $f  card=$b repo=$a"; fail=1; }
done
a="$BSHA";                    b=$(sha256sum < "$DST/bitstream.rbf_r" | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  ok   bitstream.rbf_r  $b" || { echo "  FAIL bitstream  card=$b repo=$a"; fail=1; }
a="$ISHA";                    b=$(sha256sum < "$ADF/aw-all.bin" | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  ok   aw-all.bin       $b" || { echo "  FAIL aw-all.bin card=$b repo=$a"; fail=1; }
[ -e "$CARD/Cores/Eddie Chan.AW 1042/bitstream.rbf_r" ] \
    && echo "  ok   control AW 1042 still installed: $(sha256sum < "$CARD/Cores/Eddie Chan.AW 1042/bitstream.rbf_r" | cut -c1-16)" \
    || { echo "  FAIL the 1042 control is GONE from the card"; fail=1; }
[ "$fail" -eq 0 ] || { echo "NOT INSTALLED cleanly - do not launch it as if it were."; exit 1; }

cat <<'DONE'

DONE. Eject, put the card back in the Pocket, boot.

Start a UART capture BEFORE launching:
    python3 scripts/capture_serial.py /dev/ttyUSB1
Every launch prints a CHK line; the two fields this probe exists for are at the end:
    ... Z<flag><quarter> <read_sum>/<written_sum> G<part><flags> E<code>

RUN 1 - the probe.  Launch "AW 1044", and when the OSD asks for a file pick  aw-all.bin
                    (2.94 MiB). Read the line, then look at the screen.

  G05 E00   whole file arrived. pool_ok=1 means the 93 pool pages in the chip add up to what the
            image declares (wsum 9ca26b21, wxor be39) - #15 is answered YES and the single-image
            plan stands. The picture is part 0's intro.
  G01 E00   the directory arrived and the pool does NOT add up. Most likely the framework stopped
            early. Note Z's quarter nibble (which quarter of the swept range disagrees) and the two
            sums - that localises the cutoff to a 1 MiB band, and the read sum can be compared
            against the image's own prefix sums offline.
  G00 E40   no AWP1 magic: the framework did not deliver this file (would not select it, or picked
            another). That is also a complete answer to #15 and the plan stops here.

  Whatever G says, also answer: does it boot at all, is there a picture, and is the picture part 0's
  intro rather than noise? A truncated pool gives wrong pixels in the pages that never arrived, not a
  hung device - so a black screen with G01 is a different bug from a partly-wrong picture with G01.

RUN 2 - the control on the same core.  Launch "AW 1044" with  part0.bin  (2 MiB).
  Expect G00 E40 (a plain pack is not an error - identity map, no directory) and a normal intro. This
  separates "the paged core is broken" from "the bigger file did not arrive": if run 1 shows a broken
  picture and run 2 does too, the core is the problem, not the upload.

RUN 3 - the known-good control.  Launch "AW 1042" with part0.bin and confirm it still draws straight
  text and plays past a minute. If the control has changed behaviour, the card or the framework
  changed under us and today's readings mean nothing until that is re-established.

Report all three, with the CHK lines. A new symptom is as valuable as a pass: if G05 arrives but the
picture is wrong, the page table and the bytes disagree somewhere, and the bench can be aimed at it.
DONE
