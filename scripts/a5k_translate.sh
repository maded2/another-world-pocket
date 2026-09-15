#!/usr/bin/env bash
# Translate the upstream a5k design (Silice .si) into Verilog for Quartus.
#
#   make a5k-translate                 # host side, goes through docker
#   scripts/a5k_translate.sh           # same thing, from inside the container
#
# Output: ports/another-world/upstream/hardware/BUILD_probe/build.v
#
# This is the input the Pocket flow actually consumes - Quartus never sees .si.
# Upstream is MIT-licensed and is fetched by ports/another-world/fetch_upstream.sh
# at the commit pinned in ports/another-world/UPSTREAM_PIN; build.v itself is
# generated output and stays gitignored.
#
#   SILICE_BOARD   upstream board to translate for (default icebreaker)
#   SILICE_PERIPH  peripheral set                (default basic,vga,qspiflash,buttons)
#   SILICE_OUT     build directory name          (default BUILD_probe)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW="$ROOT/ports/another-world"
HW="$AW/upstream/hardware"

BOARD="${SILICE_BOARD:-icebreaker}"
PERIPH="${SILICE_PERIPH:-basic,vga,qspiflash,buttons}"
OUT="${SILICE_OUT:-BUILD_probe}"

if [ ! -f "$HW/a5k.si" ]; then
    echo "error: $HW/a5k.si not found." >&2
    echo "       fetch upstream first:  ./ports/another-world/fetch_upstream.sh" >&2
    exit 1
fi

if [ ! -e /opt/Silice ]; then
    echo "error: /opt/Silice not found - this must run in the Silice image." >&2
    echo "       try:  make a5k-translate" >&2
    exit 1
fi

echo "translating a5k.si for $BOARD [$PERIPH] -> $HW/$OUT/build.v"
cd "$HW"
python3 /opt/Silice/bin/silice-make.py -s a5k.si -b "$BOARD" \
    -p "$PERIPH" -o "$OUT" --no_build

gen="$HW/$OUT/build.v"
if [ ! -s "$gen" ]; then
    echo "error: silice-make.py produced no $gen" >&2
    exit 1
fi

echo "wrote $gen"
echo "       $(wc -c < "$gen") bytes, $(wc -l < "$gen") lines," \
     "$(grep -cE '^[[:space:]]*module' "$gen") modules"
