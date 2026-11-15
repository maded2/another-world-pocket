#!/usr/bin/env bash
# From the ORIGINAL Another World ROM banks to the one file the Pocket core loads.
#
#   scripts/build_all_in_one.sh                # packs -> audio -> build/aw-all-audio.bin
#   scripts/build_all_in_one.sh --skip-packs   # reuse ports/another-world/packs
#   scripts/build_all_in_one.sh --no-audio     # pool only (no sound/music in the image)
#   scripts/build_all_in_one.sh --out FILE     # choose the output path
#
# Input  : gamedata/  - the DOS 19/3/92 release: BANK01..BANK0D + memlist.bin
# Output : one dataslot file holding all eight parts AND the audio (pool + blob), plus the
#          per-part packs it is assembled from. The image is verified byte-for-byte against
#          those packs at the end - a build that cannot fail is not a build gate.
#
# The three steps it orchestrates are individually documented, and each is idempotent:
#   scripts/extract_packs.sh   gamedata/ -> ports/another-world/packs/partN.bin (2 MiB each)
#   scripts/extract_audio.py   gamedata/ -> build/aw-audio.bin + build/aw-audio.json
#   scripts/build_combined_image.py
#                              packs (+ audio blob if present) -> the paged image + verify
#
# Why one file: the core's dataslot upload is the slow part of a launch and the pool makes the
# eight 2 MiB part views share their identical 32 KiB frames, so all eight parts plus the audio
# fit in 3.64 MiB - under the ~4 MiB the framework will hand over. See
# docs/another-world/single-image-plan.md and audio-plan.md (decision D1a).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_PACKS=0
WITH_AUDIO=1
OUT="$ROOT/build/aw-all-audio.bin"
PACKS="$ROOT/ports/another-world/packs"
AUDIO_BLOB="$ROOT/build/aw-audio.bin"
AUDIO_INDEX="$ROOT/build/aw-audio.json"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-packs) SKIP_PACKS=1 ;;
        --no-audio)   WITH_AUDIO=0; OUT="$ROOT/build/aw-all.bin" ;;
        --out)        shift; OUT="${1:?--out needs a path}" ;;
        -h|--help)    sed -n '1,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ---- 0. the original ROM ------------------------------------------------------------------
# gamedata/ is the licensed release and is not in the repo; say exactly what is missing rather
# than failing three steps later with a size mismatch.
# The release ships the banks as bank01..bank0d; some copies use upper case, so accept both.
BANKS=$(ls "$ROOT"/gamedata/[Bb][Aa][Nn][Kk][0-9A-Fa-f][0-9A-Fa-f] 2>/dev/null | wc -l)
if [ "$BANKS" -lt 4 ] || [ ! -f "$ROOT/gamedata/memlist.bin" ]; then
    echo "error: gamedata/ does not look like the DOS 19/3/92 release" >&2
    echo "       found $BANKS bankNN files and $([ -f "$ROOT/gamedata/memlist.bin" ] && echo yes || echo no) memlist.bin" >&2
    echo "       expected bank01..bank0d plus memlist.bin; see README (the game data is not in this repo)" >&2
    exit 1
fi
echo "rom      : $BANKS BANK files + memlist.bin"

# ---- 1. per-part packs --------------------------------------------------------------------
if [ "$SKIP_PACKS" -eq 1 ]; then
    echo "packs    : reusing $PACKS (--skip-packs)"
else
    echo "packs    : extracting all parts from gamedata/ (a few minutes)"
    "$ROOT/docker/run-extract.sh" scripts/extract_packs.sh
fi
for i in 0 1 2 3 4 5 6 7; do
    [ -f "$PACKS/part$i.bin" ] || { echo "error: $PACKS/part$i.bin missing after extraction" >&2; exit 1; }
done

# ---- 2. audio (sound effects + music) -----------------------------------------------------
if [ "$WITH_AUDIO" -eq 1 ]; then
    echo "audio    : unpacking every RT_SOUND and RT_MUSIC resource"
    python3 "$ROOT/scripts/extract_audio.py" --out "$AUDIO_BLOB" >/dev/null
    [ -f "$AUDIO_INDEX" ] || { echo "error: extract_audio.py produced no index at $AUDIO_INDEX" >&2; exit 1; }
    python3 - "$AUDIO_INDEX" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["entries"]
snd = [x for x in e if x["type"] == "SOUND"]
mus = [x for x in e if x["type"] == "MUSIC"]
loop = [x for x in snd if x.get("loop_len", 0)]
print("           %d sounds (%d looping), %d music modules" % (len(snd), len(loop), len(mus)))
if not mus:
    sys.exit("no MUSIC resources extracted - the tracker would have nothing to play")
PY
else
    echo "audio    : skipped (--no-audio)"
    rm -f "$AUDIO_BLOB" "$AUDIO_INDEX"
fi

# ---- 3. the image, and the proof it is the packs -----------------------------------------
echo "image    : building and verifying $OUT"
python3 "$ROOT/scripts/build_combined_image.py" -o "$OUT" | sed 's/^/           /'
python3 "$ROOT/scripts/build_combined_image.py" --verify "$OUT" | tail -3 | sed 's/^/           /'

SIZE=$(stat -c%s "$OUT")
SHA=$(sha256sum "$OUT" | cut -c1-16)
echo
echo "done     : $OUT"
echo "           $SIZE bytes ($(python3 -c "print('%.3f' % ($SIZE/2.0**20))") MiB), sha256 ${SHA}..."
if [ "$WITH_AUDIO" -eq 1 ]; then
    echo "           load it as the dataslot file; the OSD's Game part list then selects the chapter."
else
    echo "           load it as the dataslot file; it carries the eight parts but NO audio."
fi
