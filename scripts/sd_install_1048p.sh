#!/bin/bash
# Install the 2-PART AUDIO PROBE as its own identity ("Eddie Chan.AW 1048").
#
# WHY THIS EXISTS. AW 1047 (the shipping audio build) shows a perfect picture on hardware and no sound.
# Two explanations fit that exactly, and they need different fixes:
#   (a) the audio chain is not running; or
#   (b) the 3.64 MiB dataslot did not arrive in full, so the audio section - which lives ABOVE the game
#       pool, starting at byte 0x2F0000 - is missing. The index the core copies out is at 0x1000 and would
#       still be intact, so lookups succeed, the mixer runs, and it reads bytes that are not there. 0xFF
#       fill as signed 8-bit through the volume divider is EXACTLY zero, so (b) is indistinguishable from
#       (a) by ear.
#
# This probe removes (b) from the experiment: 2 parts + the whole audio blob is 1.79 MiB, small enough that
# the framework and the loader's buffering cannot be the problem. Its audio section starts at 0x118000, so
# the bitstream carries that base instead of 0x2F0000 - a bitstream and an image are a pair.
#
# IF THIS ONE SOUNDS: the chain works and the shipping build's silence is an upload/packaging problem.
# IF IT IS STILL SILENT: the fault is in the core and the next step is telemetry, not another image.
set -u

# Set from the build that this probe is: sha256 of build/aw/bitstream.rbf_r. An installer that
# installs whatever happens to be in build/ is how 1026a got reported as 1028b.
EXPECT_SHA="${EXPECT_SHA:-5d4d47be0e199741}"

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
BS="$REPO/build/aw/bitstream-probe-0x118000.rbf_r"
IMG="$REPO/build/aw-small-audio.bin"

[ -f "$BS" ]  || { echo "FATAL: no bitstream at $BS - run: make build CORE_DIR=cores/aw"; exit 1; }
[ -f "$IMG" ] || { echo "FATAL: no combined image at $IMG - run: python3 scripts/build_combined_image.py -o build/aw-small-audio.bin --packs ..."; exit 1; }

case "$EXPECT_SHA" in
    REPLACE_*) echo "NOTE: EXPECT_SHA is unset, so this installer cannot tell the AUDIO build from"
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
[ "$ISIZE" -eq 1880092 ] || echo "NOTE: image is $ISIZE bytes, not the 1,880,092 this probe was sized for."

DST="$CARD/Cores/Eddie Chan.AW 1048"
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
#
# Note what this does to the verification at the bottom: core.json is the ONE file this installer
# edits, so a hash against the repo copy can only ever disagree - which is exactly what the first run
# of this script reported, as "NOT INSTALLED cleanly", on a card that had every byte of every file in
# place. A check that cannot pass is not a check; the fields that decide whether this core boots are
# validated by name instead, further down.
python3 - "$DST/core.json" <<'PY'
import json, sys, datetime
p = sys.argv[1]
d = json.load(open(p))
m = d["core"]["metadata"]
m["shortname"] = "AW 1048"
m["description"] = (
    "Another World - paged build 1045a. Fixes the black screen that 1044a showed with a combined "
    "image: the boot sweep used to arm when the TRAILER WORD was written (0x1FFFE0), which is the end "
    "of a 2 MiB pack but only two thirds of the way into a 2.94 MiB image, so a two-million-word "
    "census started mid-upload, took the PSRAM from the loader, and the upload overflowed - the "
    "console said C2 (ERR_OVERFLOW) with Y00000000 and the VM never received a byte. The sweep now "
    "arms only on the framework's own dataslot-complete command, with the queue quiet. One dataslot "
    "file can carry every part: a 32 KiB directory page holds eight 64-entry page tables and the VM's "
    "2 MiB view is assembled from a pool of frames on die 0. UART: G is the part and its state, E is "
    "why a directory was refused. AW 1042 and AW 1044 are left on this card as controls."
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
if [ -e "$ADF/aw-small-audio.bin" ]; then echo "NOTE: overwriting $ADF/aw-small-audio.bin"; fi
cp "$IMG" "$ADF/aw-small-audio.bin" || { echo "FATAL: image copy failed"; exit 1; }

sync
echo
echo "verifying what is actually on the card (sha256, read back):"
fail=0
for f in $FILES; do
    [ "$f" = "core.json" ] && continue      # patched here, so validated by field, not by hash
    a=$(sha256sum < "$SRC/$f" | cut -d' ' -f1); b=$(sha256sum < "$DST/$f" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "  ok   $f" || { echo "  FAIL $f  card=$b repo=$a"; fail=1; }
done
# core.json: what the framework actually reads, read back off the card. This replaces a hash
# comparison that could never pass (this script rewrites the file after copying it) with the four
# facts that decide whether the core boots at all, plus a structural diff against the repo copy so a
# field nobody meant to drop cannot quietly go missing. A check that cannot pass is not a check.
python3 - "$DST/interact.json" <<'PY' || fail=1
import json, sys
d = json.load(open(sys.argv[1]))
vs = d.get("interact", {}).get("variables", [])
bad = []
if not vs:
    bad.append("variables[] is empty - there is no selector, so the core can only ever boot part 1")
# TWO ENCODINGS, TWO ADDRESSES (aw_rom: is_val_addr). 0x00F00020 is value-selected - it is where a
# PERSISTED list writes, which is the only kind the framework rewrites at boot - and 0x00F00000..1C stays
# address-selected for the benches. This check used to demand 0x00F00000 and therefore failed a CORRECT
# install (the value decode was split out of the base address after a tb_soc run showed the two colliding).
found = None
for v in vs:
    a = str(v.get("address", "")).lower()
    if v.get("type") == "list" and (a.endswith("f00020") or a.endswith("f00000")):
        found = a
        opts = v.get("options", [])
        if len(opts) != 8:
            bad.append("%r has %d options, expected 8 (one per part)" % (v.get("name"), len(opts)))
        if not v.get("persist"):
            bad.append("%r is not persisted, so its value is never rewritten at boot and the select "
                       "would only apply to the session it was pressed in" % v.get("name"))
if found is None:
    bad.append("no list variable at 0x00F00020 (value-selected) or 0x00F00000 (address-selected) - "
               "aw_rom decodes both, and the OSD list must use the value-selected one")
for b in bad:
    print("  FAIL interact.json  %s" % b)
if not bad:
    print("  ok   interact.json  (one persisted 8-option list at %s)" % found)
sys.exit(1 if bad else 0)
PY
python3 - "$DST/core.json" "$SRC/core.json" <<'PY' || fail=1
import json, sys
card, repo = (json.load(open(p)) for p in sys.argv[1:3])
REWRITTEN = {"shortname", "description", "version", "date_release"}
c, r = card["core"], repo["core"]
bad = []
if c.get("magic") != "APF_VER_1":
    bad.append("magic is %r, framework expects APF_VER_1" % c.get("magic"))
if "anotherworld" not in c.get("metadata", {}).get("platform_ids", []):
    bad.append("platform_ids %r does not name anotherworld - the core will not offer the dataslot"
               % c["metadata"].get("platform_ids"))
cores = c.get("cores", [])
if not cores or cores[0].get("filename") != "bitstream.rbf_r":
    bad.append("cores[0].filename is %r, but the bitstream was written as bitstream.rbf_r"
               % (cores[0].get("filename") if cores else None))
if c.get("framework", {}).get("chip32_vm") != "loader.bin":
    bad.append("chip32_vm is %r but loader.bin is what was copied" % c["framework"].get("chip32_vm"))
if c.get("metadata", {}).get("shortname") != "AW 1048":
    bad.append("shortname is %r - the OSD label is how the user picks this build" % c["metadata"].get("shortname"))
# Everything outside the four fields we rewrite must be byte-identical in meaning to the repo copy.
def strip(d):
    d = json.loads(json.dumps(d))
    m = d["core"]["metadata"]
    for k in REWRITTEN:
        m.pop(k, None)
    return d
if strip(card) != strip(repo):
    bad.append("core.json differs from the repo copy outside the rewritten metadata fields")
for b in bad:
    print("  FAIL core.json  %s" % b)
if not bad:
    print("  ok   core.json  (magic, platform, bitstream name, chip32 vm, label; rest identical to repo)")
sys.exit(1 if bad else 0)
PY
a="$BSHA";                    b=$(sha256sum < "$DST/bitstream.rbf_r" | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  ok   bitstream.rbf_r  $b" || { echo "  FAIL bitstream  card=$b repo=$a"; fail=1; }
a="$ISHA";                    b=$(sha256sum < "$ADF/aw-small-audio.bin" | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  ok   aw-small-audio.bin       $b" || { echo "  FAIL aw-small-audio.bin card=$b repo=$a"; fail=1; }
[ -e "$CARD/Cores/Eddie Chan.AW 1042/bitstream.rbf_r" ] \
    && echo "  ok   control AW 1042 still installed: $(sha256sum < "$CARD/Cores/Eddie Chan.AW 1042/bitstream.rbf_r" | cut -c1-16)" \
    || { echo "  FAIL the 1042 control is GONE from the card"; fail=1; }
[ "$fail" -eq 0 ] || { echo "NOT INSTALLED cleanly - do not launch it as if it were."; exit 1; }

cat <<'DONE'

DONE. Eject safely, put the card back in the Pocket, boot.

Start a UART capture BEFORE launching (if you have the adapter):
    python3 scripts/capture_serial.py /dev/ttyUSB1

RUN. Launch "AW 1048", dataslot file  aw-small-audio.bin  (1.79 MiB, two parts), OSD Game part = Part 2.
     Part 2 is part1.bin - the intro, which is where the harvested sounds are. Part 0 in the list
     (value 0) is part0.bin, the copy protection screen, which has no sounds at all.

WHAT TO LISTEN FOR, and when:
    frame ~24 (0.4 s in)   two sounds together: res 8 ch 3 and res 8 ch 2
    frame ~96 (1.6 s in)   another pair: res 9 ch 0 and res 9 ch 1
    after ~8.5 s           module 7 starts, but it is NOT implemented yet (the tracker fails its bench),
                           so expect silence there - that half of the feature is not in any bitstream.

INTERPRETING IT:
  * You hear the two-note pairs -> the audio chain works end to end on hardware, and AW 1047's silence is
    the 3.64 MiB upload: report the CHK line from AW 1047 (G, Z and the two sums) and the next step is a
    smaller shipping image, not an RTL change.
  * Still nothing -> the fault is inside the core and the image is exonerated. Then the next build is
    telemetry: counters for index-loaded / play requests / mixer commands / mixer samples / nonzero
    samples / dropped ticks, printed as one line, so the failure names itself instead of being guessed.

Either way, also worth reporting: does the picture on AW 1048 look the same as on AW 1047 (same intro,
same animation), and does the console print G05 or G01 for this small image.
DONE
