#!/usr/bin/env bash
# Simulate the whole design: load a pack over the modelled bridge, release the VM, capture
# the video pins and write frames as PPMs. This is the test that answers "does the intro
# render?" - the bar agreed for scope S1 - and the only one that exercises the pipeline
# alignment, the ROM's byte contract and the arbitration together.
#
#   ./docker/run-silice.sh scripts/sim_soc.sh                        # part1, 40 frames
#   ./docker/run-silice.sh scripts/sim_soc.sh ports/another-world/packs/part6.bin
#   FRAMES=200 ./docker/run-silice.sh scripts/sim_soc.sh
#
# Frames land in ${TMPDIR:-/tmp}/awframes/frameNN.ppm - plain enough to open in anything,
# and `python3 -c ...` or an image viewer will show what the design drew.
#
# Requires scripts/pocket_translate.sh to have produced cores/aw/src/fpga/core/
# aw_pocket_build.v. Exit status: 0 = frames captured and no mismatch | 1 = see output |
# other = tooling.
set -euo pipefail
set +e   # the run reports its own status

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="${1:-$ROOT/ports/another-world/packs/part1.bin}"
SIM="$ROOT/cores/aw/src/sim"
CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${TMPDIR:-/tmp}/aw-sim-soc"
FRAMES="${FRAMES:-40}"

[ -f "$PACK" ] || { echo "error: no pack at $PACK" >&2
                    echo "       build them with: ./docker/run-extract.sh scripts/extract_packs.sh" >&2
                    exit 2; }
[ -f "$CORE/aw_pocket_build.v" ] || { echo "error: no $CORE/aw_pocket_build.v" >&2
                    echo "       run: ./docker/run-silice.sh scripts/pocket_translate.sh" >&2
                    exit 2; }

mkdir -p "$WORK" "$WORK/frames"

python3 - "$PACK" "$WORK/pack.hex" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as fh:
    for b in data:
        fh.write("%02x\n" % b)
print("wrote %s (%d bytes)" % (sys.argv[2], len(data)))
PY

cd "$WORK"
verilator --binary -j 4 --timing --top-module tb_soc \
    -Wno-fatal -Wno-lint --Mdir obj \
    "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" \
    "$CORE/aw_pocket_build.v" "$SIM/tb_soc.sv" \
    -o tb_soc 2>&1 | tail -25

echo "=== run: load, boot, capture $FRAMES frames ==="
./obj/tb_soc "+PACK=$WORK/pack.hex" "+PACE=${PACE:-8}" "+FRAMES=$FRAMES" \
             "+FRAMEDIR=$WORK/frames"
rc=$?

echo "=== frames ==="
ls -l "$WORK/frames" 2>/dev/null | head -8
if [ "$rc" -eq 0 ]; then
    echo "frames are in $WORK/frames - look at one before believing the summary"
fi
exit $rc
