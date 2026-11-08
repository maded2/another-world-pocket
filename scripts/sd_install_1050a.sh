#!/bin/bash
# Install AW 1050: the build whose loader can actually hold a 3.64 MiB upload.
#
# WHAT CHANGED. aw_rom's loader FIFO was 512 entries of ONE 32-bit word each - 2 KB of image, not the 64 KB
# the comment beside it claimed. On overflow its tripwire sets ld_abort and drops every later write for the
# rest of the power cycle, so one burst from the host costs the tail of the file. Measured in tb_soc with the
# real image: at PACE=10 the 512-entry version truncates at byte 2,136,508, the 4096-entry version uploads
# the whole thing byte-exact. That is the difference the hardware showed as "garbled sound": the audio
# section never arrived and the mixer played stale PSRAM left by the previous launch.
#
# RUN 1 - AW 1050 + aw-all-audio.bin (3.64 MiB) + OSD Game part = Part 2.
#         Expect clean sound: the two-sound pair around frame 24, another pair around frame 96.
#         Garbled again would mean the host is faster than this buffer can absorb and the answer is a
#         faster drain or a different image layout, not a deeper queue.
#         Silent would mean the tail arrived but the audio cannot be addressed - a different fault.
# RUN 2 - AW 1050 + aw-small-audio.bin (1.79 MiB) + Part 2, as the control: must sound.
#
# If run 1 is still garbled, the ladder images are also worth a pass - aw-p3/p4/p5/p6-audio.bin in
# Assets/anotherworld/common (2.07 / 2.42 / 2.76 / 2.95 MiB, all with the audio blob). Whichever size first
# garbles brackets where the upload stops, by ear, and needs no UART.
set -u

# Set from the build that this probe is: sha256 of build/aw/bitstream.rbf_r. An installer that
# installs whatever happens to be in build/ is how 1026a got reported as 1028b.
EXPECT_SHA="${EXPECT_SHA:-0070b75702f1a190}"

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
IMG="$REPO/build/aw-all-audio.bin"

[ -f "$BS" ]  || { echo "FATAL: no bitstream at $BS - run: make build CORE_DIR=cores/aw"; exit 1; }
[ -f "$IMG" ] || { echo "FATAL: no combined image at $IMG - run: python3 scripts/build_combined_image.py -o build/aw-all-audio.bin --packs ..."; exit 1; }

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
[ "$ISIZE" -eq 3813404 ] || echo "NOTE: image is $ISIZE bytes, not the 3,080,192 this probe was sized for."

DST="$CARD/Cores/Eddie Chan.AW 1050"
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
m["shortname"] = "AW 1050"
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
if [ -e "$ADF/aw-all-audio.bin" ]; then echo "NOTE: overwriting $ADF/aw-all-audio.bin"; fi
cp "$IMG" "$ADF/aw-all-audio.bin" || { echo "FATAL: image copy failed"; exit 1; }

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
if c.get("metadata", {}).get("shortname") != "AW 1050":
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
a="$ISHA";                    b=$(sha256sum < "$ADF/aw-all-audio.bin" | cut -d' ' -f1)
[ "$a" = "$b" ] && echo "  ok   aw-all-audio.bin       $b" || { echo "  FAIL aw-all-audio.bin card=$b repo=$a"; fail=1; }
[ -e "$CARD/Cores/Eddie Chan.AW 1042/bitstream.rbf_r" ] \
    && echo "  ok   control AW 1042 still installed: $(sha256sum < "$CARD/Cores/Eddie Chan.AW 1042/bitstream.rbf_r" | cut -c1-16)" \
    || { echo "  FAIL the 1042 control is GONE from the card"; fail=1; }
[ "$fail" -eq 0 ] || { echo "NOT INSTALLED cleanly - do not launch it as if it were."; exit 1; }

cat <<'DONE'

DONE. Eject safely (sync happened; umount if your desktop did not), put the card back in the Pocket,
boot.

Start a UART capture BEFORE launching:
    python3 scripts/capture_serial.py /dev/ttyUSB1
Every launch prints a CHK line; the two fields that matter are at the end:
    ... Z<flag><quarter> <read_sum>/<written_sum> G<part><flags> E<code>

SET THE PART, OR YOU WILL HEAR NOTHING. This core boots view part 0 = part0.bin, which is the copy
protection screen; the sounds in the harvest are in part1.bin. In the OSD set "Game part" to **Part 2**
(option value 1 - the list is labelled from 1, and part0.bin is what its own header calls GAME_PART1).

RUN 1 - the audio probe.  Launch "AW 1050", pick dataslot file  aw-all-audio.bin  (3.64 MiB), OSD
        Game part = Part 2. Then report, in this order:
  a) the CHK line. G05 = the whole 3.64 MiB arrived and the pool matches what the image declares
     (that also answers the old "does a >2 MiB dataslot arrive" question). G01 = the directory
     arrived but the pool does not add up, i.e. the upload was truncated - note Z's quarter nibble
     and the two sums, which localise the cutoff to a 1 MiB band. G00 E40 = the file was not
     delivered at all.
  b) is there a picture, and is it the intro (drawn scene, not noise)?
  c) is there AUDIO? The harvested cues, by frame, are:
        frame ~24  res 8  freq 1 vol 45 ch 3   and   res 8  freq 5 vol 45 ch 2   (two at once)
        frame ~96  res 9  freq 20 vol 30 ch 0  and   res 9  freq 20 vol 63 ch 1
     Music (module 7, the intro theme) starts after ~8.5 s: 64 rows at 133 ms, then the first note.
     Do the two-note pair and the music start at roughly those times?

     A picture with NO sound is the interesting failure, and the two shapes are different:
       * total silence from the first frame: the audio chain is not running at all (index load or
         the mixer's tick) - the console's G/E fields are unaffected by that, so the picture being
         normal does not clear it;
       * sound that starts late, stutters, or matches the picture badly: the PSRAM port, i.e.
         exactly what the dropped-tick counter was there to rule out in simulation (0 in tb_soc).

RUN 2 - same core, same bitstream, plain pack.  Launch "AW 1050" again and pick part0.bin (2 MiB).
        Expect G00 E40 (a plain pack has no directory - not an error) and a normal protection screen.
        If run 1 is broken and run 2 is fine, the fault is the big upload; if both are broken, it is
        the core.

RUN 3 - the known-good control.  Launch "AW 1042" with part0.bin and confirm it still draws straight
        text and runs past a minute. If the control has changed, the card or the framework changed
        under us and today's readings mean nothing until that is re-established.

WHAT WOULD FALSIFY THE SIMULATION.  Simulation says: the 3.64 MiB image uploads byte-exact at the
host's real pace; the mixer drops 0 ticks with the VM running; I2S has 0 underruns once primed. If
hardware shows sound that stutters while the picture runs smoothly, or music that drifts, the model
that produced those numbers is wrong somewhere and the bench that proves it needs to be the one that
fails first. Report which of those three it was.
DONE

