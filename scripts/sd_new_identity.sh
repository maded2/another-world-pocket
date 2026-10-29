#!/bin/bash
# Create a FRESH core identity (Eddie Chan.AW 1026) carrying the 1026a bitstream,
# to bypass any OS-internal bitstream cache keyed by the old core's identity.
# Folder name = EXACTLY author.shortname from core.json (space preserved): the
# OS builds the launch path from the metadata, so a space-less name indexes but
# fails to launch.
# Also re-clears the five /System catalog caches so the new core appears in the menu.
set -u
CARD=""
for m in /media/*/*; do
    [ -d "$m/Cores" ] && { CARD="$m"; break; }
done
[ -n "$CARD" ] || { echo "no Pocket SD card found under /media"; exit 1; }
echo "card: $CARD"

SRC="$CARD/Cores/Eddie Chan.Another World"
DST="$CARD/Cores/Eddie Chan.AW 1026"

[ -d "$SRC" ] || { echo "source core folder missing: $SRC"; exit 1; }

if [ -e "$DST" ]; then
    echo "$DST already exists - removing first"
    rm -rf "$DST"
fi
mkdir -p "$DST"
cp -v "$SRC"/bitstream.rbf_r "$SRC"/core.json "$SRC"/loader.bin "$SRC"/data.json \
      "$SRC"/audio.json "$SRC"/input.json "$SRC"/interact.json "$SRC"/variants.json \
      "$SRC"/video.json "$SRC"/info.txt "$DST"/

# new identity in core.json: shortname + version + date so no cached entry can match
python3 - "$DST/core.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
md = d["core"]["metadata"]
md["shortname"] = "AW 1026"
md["version"] = "0.2.0"
md["date_release"] = "2026-10-26"
md["description"] = ("Another World - diagnostic build 1026a (UART boot tag 'AW 1026a up', "
                     "per-second trailer dumps). Same core as Eddie Chan.Another World.")
json.dump(d, open(p, "w"), indent=4)
print("core.json updated: shortname='AW 1026' version=0.2.0")
EOF

echo
echo "=== verify new folder ==="
ls -la "$DST"
sha256sum < "$DST/bitstream.rbf_r" | cut -c1-16   # expect 2e47de15f1e23b11

# re-clear the five catalog caches so the fresh core is picked up (KB-056)
TS=$(date +%Y%m%d-%H%M%S)
BK="build/sd/system-backup-$TS"
if [ -d "$CARD/System" ]; then
    mkdir -p "$BK" && cp -a "$CARD/System/." "$BK/" && echo "backed up /System -> $BK"
    for f in core_viewby_platform.bin corelist_cache.bin cores_cache.bin \
             platform_viewby_category.bin platforms_cache.bin; do
        [ -f "$CARD/System/$f" ] && rm -v "$CARD/System/$f"
    done
fi
sync
echo
echo "DONE. Put the card back in the Pocket, boot, and launch 'AW 1026' (NOT 'Another World')."
