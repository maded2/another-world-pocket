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
# Keyed by pack (see scripts/sim_soc.sh for the reasoning): one fixed dir meant a second run
# overwrote the first run's pack.hex while it was still reading it.
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-rom-$(basename "$PACK" .bin)}"
LOCK="$WORK.lock"

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

# Lock before building: obj/tb_rom is rebuilt in place.
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "note: another tb_rom run holds $LOCK - waiting for it"
    flock 9
fi

# This used to be `verilator ... 2>&1 | tail -20`, and the script runs with `set +e`, so a
# compile error did not stop anything: the run step went ahead and executed obj/tb_rom, which
# was the binary from the previous run, and reported its result as if it were this one's. A
# broken tb_rom could therefore print "505 checks / 0 errors" off a stale binary. Check the
# build's own status and fail before anything gets to run.
if ! verilator --binary -j 4 --timing --top-module tb_rom \
    -Wno-fatal -Wno-lint --Mdir obj ${TRACE:++define+TRACE_LEFT=16} \
    "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" "$SIM/tb_rom.sv" \
    -o tb_rom > build.log 2>&1; then
    echo "error: tb_rom build failed - first errors:" >&2
    grep -E "%Error" build.log | head -10 >&2
    exit 1
fi

echo "=== tripwire: a bridge writing every cycle must be reported, not played back ==="
./obj/tb_rom "+PACK=$WORK/pack.hex" +TRIPWIRE
rc_tw=$?

if [ -n "${TRACE:-}" ]; then
  echo "=== short traced load ==="
  ./obj/tb_rom "+PACK=$WORK/pack.hex" +PACE=6 +TRACESHORT || true
fi

echo "=== functional: a plausible sustained load, then read every byte back ==="
./obj/tb_rom "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}" ${TRACE:++TRACE} ${EXTRA:-}
# EXTRA carries bench plusargs (the positional argument is the pack), e.g.
#   EXTRA=+SKIP=100 ./docker/run-silice.sh scripts/sim_rom.sh   # census must flag the gap
rc_fn=$?

exit $(( rc_tw + rc_fn ))
