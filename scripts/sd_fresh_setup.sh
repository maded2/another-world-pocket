#!/bin/bash
# Set up a BLANK Pocket SD card with exactly one core: Eddie Chan.AW 1026
# (fresh identity carrying the 1026a diagnostic bitstream), its platform files,
# and the eight game packs. Run when the blank card is in the USB reader.
#
# The folder name must be EXACTLY author.shortname as written in core.json
# (space preserved): the OS builds the launch path from the metadata, not the
# folder name - a space-less 'Eddie Chan.AW1026' gets indexed but fails to
# launch (no data-slot prompt), see scripts/package_core.py derive_core_id.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"

CARD=""
for m in /media/*/*; do
    [ -d "$m" ] && [ ! -e "$m/Cores/Eddie Chan.Another World" ] && CARD="$m" && break
done
# fall back: any mounted card that has no Cores dir yet
if [ -z "$CARD" ]; then
    for m in /media/*/*; do
        [ -d "$m" ] && [ ! -d "$m/Cores" ] && CARD="$m" && break
    done
fi
[ -n "$CARD" ] || { echo "no blank card found under /media (expected a card WITHOUT Cores/)"; exit 1; }
echo "card: $CARD"

# --- filesystem check -------------------------------------------------------
FSTYPE=$(stat -f -c %T "$CARD" 2>/dev/null)
case "$FSTYPE" in
    exfat|vfat) echo "filesystem: $FSTYPE (ok)" ;;
    *)
        echo "filesystem: '$FSTYPE' - NOT exFAT/FAT32. Formatting as exFAT (card must be blank!)"
        DEV=$(mount | awk -v p="$CARD" '$3==p {print $1}')
        [ -n "$DEV" ] || { echo "cannot find device for $CARD"; exit 1; }
        sync; sleep 1
        umount "$CARD" || { echo "umount failed"; exit 1; }
        mkfs.exfat -L POCKET "$DEV" || { echo "mkfs.exfat failed"; exit 1; }
        sleep 2
        mount "$DEV" "$CARD" || { echo "remount failed"; exit 1; }
        ;;
esac

# --- core folder ------------------------------------------------------------
SRC="$REPO/build/sd/aw/Cores/Eddie Chan.Another World"
DST="$CARD/Cores/Eddie Chan.AW 1026"
mkdir -p "$DST"
cp -v "$SRC"/bitstream.rbf_r "$SRC"/core.json "$SRC"/loader.bin "$SRC"/data.json \
      "$SRC"/audio.json "$SRC"/input.json "$SRC"/interact.json "$SRC"/variants.json \
      "$SRC"/video.json "$SRC"/info.txt "$DST"/

python3 - "$DST/core.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
md = d["core"]["metadata"]
md["shortname"] = "AW 1026"
md["version"] = "0.2.0"
md["date_release"] = "2026-10-26"
md["description"] = ("Another World - diagnostic build 1026a (UART boot tag 'AW 1026a up', "
                     "per-second trailer dumps).")
json.dump(d, open(p, "w"), indent=4)
print("core.json: shortname='AW 1026' version=0.2.0")
EOF

# --- platform ---------------------------------------------------------------
mkdir -p "$CARD/Platforms/_images"
cp -v "$REPO/build/sd/aw/Platforms/anotherworld.json" "$CARD/Platforms/"
cp -v "$REPO/build/sd/aw/Platforms/_images/anotherworld.bin" "$CARD/Platforms/_images/"

# --- packs ------------------------------------------------------------------
mkdir -p "$CARD/Assets/anotherworld/common"
for i in 0 1 2 3 4 5 6 7; do
    cp -v "$REPO/build/sd/aw/Assets/anotherworld/common/part$i.bin" \
          "$CARD/Assets/anotherworld/common/"
done

sync
echo
echo "=== verify ==="
ls -la "$DST"
sha256sum < "$DST/bitstream.rbf_r" | cut -c1-16   # expect 2e47de15f1e23b11
grep '"shortname"' "$DST/core.json"
du -sh "$CARD"
echo
echo "DONE. Put the card back in the Pocket, boot, launch 'AW 1026', select part1.bin when asked."
