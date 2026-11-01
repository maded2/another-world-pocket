#!/usr/bin/env bash
# Simulate the paged-image directory: one upload, a part selected by an address write,
# and the VM's 2 MiB view following the table. Task #18's acceptance test.
#
#   ./docker/run-silice.sh scripts/sim_dir.sh [pack.bin]
#   make sim-dir
#
# Separate from sim_rom.sh on purpose: the part-select path is only open until the VM has
# accepted its first byte, and tb_rom has streamed hundreds of bytes before anything else
# it does. A test that needs a simulation where nothing has been read yet cannot live at the
# end of a bench that already read everything.
#
# Exit status: 0 pass | 1 the design got a byte or a status wrong | other = tooling
set -euo pipefail
set +e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="${1:-$ROOT/ports/another-world/packs/part1.bin}"
SIM="$ROOT/cores/aw/src/sim"
CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-dir-$(basename "$PACK" .bin)}"
LOCK="$WORK.lock"

[ -f "$PACK" ] || { echo "error: no pack at $PACK" >&2
                    echo "       build them with: ./docker/run-extract.sh scripts/extract_packs.sh" >&2
                    exit 2; }
mkdir -p "$WORK"

python3 - "$PACK" "$WORK/pack.hex" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as fh:
    for b in data:
        fh.write("%02x\n" % b)
print("wrote %s (%d bytes)" % (sys.argv[2], len(data)))
PY

cd "$WORK"
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "note: another tb_dir run holds $LOCK - waiting for it"
    flock 9
fi

# Build status is checked before anything runs. sim_rom.sh lost an afternoon to a `| tail`
# that swallowed a compile failure and then executed the PREVIOUS binary and reported its
# result as this one's; the same trap, so the same guard.
if ! verilator --binary -j 4 --timing --top-module tb_dir \
    -Wno-fatal -Wno-lint --Mdir obj \
    "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" "$SIM/tb_dir.sv" \
    -o tb_dir > build.log 2>&1; then
    echo "error: tb_dir build failed - first errors:" >&2
    grep -E "%Error" build.log | head -10 >&2
    exit 1
fi

# Two runs, because the thing under test is a window: a part select is honoured only until the VM
# accepts its first byte, and a run that reads bytes before selecting cannot observe a select
# succeeding. The default run covers the installed default, the late refusal and the plain-pack
# fallback; +PART=1 covers an actual select.
echo "=== run 1: directory installs, part 0's map is live, late select refused, plain pack falls back ==="
./obj/tb_dir "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}"
rc_a=$?

echo "=== run 2: part 1 selected by an address write before the first byte ==="
./obj/tb_dir "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}" +PART=1
rc_b=$?

echo "=== run 3: a plain pack presented over an installed pool falls back to identity ==="
./obj/tb_dir "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}" +NOMAGIC
rc_c=$?

rc=$(( rc_a + rc_b + rc_c ))
[ "$rc" -eq 0 ] || echo "tb_dir: run1=$rc_a run2=$rc_b run3=$rc_c"
exit $rc
