#!/usr/bin/env bash
# Simulate the pack ROM path: load a pack over the modelled bridge, read it back
# the way the VM does, compare every byte.
#
#   ./docker/run-silice.sh scripts/sim_rom.sh                 # part1
#   ./docker/run-silice.sh scripts/sim_rom.sh ports/another-world/packs/part6.bin
#
# Verilator compiles the design (aw_rom and friends, no Quartus primitives), so
# this runs in the Silice image, which is also where the simulators live:
#
#   make sim-rom
#
# Exit status: 0 pass | 1 the design got a byte wrong | other = tooling
set -euo pipefail
set +e   # the two runs below report their own status

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="${1:-$ROOT/ports/another-world/packs/part1.bin}"
SIM="$ROOT/cores/aw/src/sim"
CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${TMPDIR:-/tmp}/aw-sim-rom"

[ -f "$PACK" ] || { echo "error: no pack at $PACK" >&2
                    echo "       build them with: ./docker/run-extract.sh scripts/extract_packs.sh" >&2
                    exit 2; }

mkdir -p "$WORK"

# one byte per line, the format $readmemh wants
python3 - "$PACK" "$WORK/pack.hex" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as fh:
    for b in data:
        fh.write("%02x\n" % b)
print("wrote %s (%d bytes)" % (sys.argv[2], len(data)))
PY

cd "$WORK"
verilator --binary -j 4 --timing --top-module tb_rom \
    -Wno-fatal -Wno-lint --Mdir obj ${TRACE:++define+TRACE_LEFT=16} \
    "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" "$SIM/tb_rom.sv" \
    -o tb_rom 2>&1 | tail -20

echo "=== tripwire: a bridge writing every cycle must be reported, not played back ==="
./obj/tb_rom "+PACK=$WORK/pack.hex" +TRIPWIRE
rc_tw=$?

if [ -n "${TRACE:-}" ]; then
  echo "=== short traced load ==="
  ./obj/tb_rom "+PACK=$WORK/pack.hex" +PACE=6 +TRACESHORT || true
fi

echo "=== functional: a plausible sustained load, then read every byte back ==="
./obj/tb_rom "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}" ${TRACE:++TRACE}
rc_fn=$?

exit $(( rc_tw + rc_fn ))
