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

# Which cases to run. Eight cases take minutes, and iterating on one of them should not cost that;
# RUNS is read from the environment, so remember that docker/run-silice.sh forwards an ALLOW-LIST of
# variables and silently drops anything not on it - which has bitten this repo three times (TRACE,
# IMG, LATESEL_TEST). RUNS is on that list now; a filter that quietly did nothing would run
# everything and look like it ran what you asked, which is the safe direction, but would waste the
# time the filter exists to save.
RUNS="${RUNS:-1 2 3 4 5 6 7 8 9}"
TOTAL=0

run_case() {              # run_case <n> <label> [plusargs...]
    local n="$1" label="$2"; shift 2
    case " $RUNS " in
        *" $n "*) ;;
        *) echo "=== run $n: $label - SKIPPED (RUNS='$RUNS') ==="; return 0 ;;
    esac
    echo "=== run $n: $label ==="
    ./obj/tb_dir "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}" "$@"
    local rc=$?
    TOTAL=$(( TOTAL + rc ))
    [ "$rc" -eq 0 ] || echo "    !! run $n exited $rc"
}

# Two runs, because the thing under test is a window: a part select is honoured only until the VM
# accepts its first byte, and a run that reads bytes before selecting cannot observe a select
# succeeding. The default run covers the installed default, the late refusal and the plain-pack
# fallback; +PART=1 covers an actual select.
run_case 1 "directory installs, part 0's map is live, late select refused, plain pack falls back"
run_case 2 "part 1 selected by an address write before the first byte" +PART=1
run_case 3 "a plain pack presented over an installed pool falls back to identity" +NOMAGIC

# PACE 10, like every other run. An earlier revision of this run used PACE=6 "to go faster" and the
# loader FIFO overflowed - ERR_OVERFLOW, with the directory bytes among those dropped, which read as
# "the design lost my table above 2 MiB" and was in fact the bench writing faster than the chip can
# take. The rate that overflows is tested on purpose in tb_rom (+TRIPWIRE); it is not a rate to test
# anything else at.
run_case 4 "bytes written above the old 2 MiB window land, and the view can be pointed there" +HIGH

# Three declarations of one chip state, each with a fresh census: the sum must cover exactly the
# pool_bytes the image declares - no further (that is what the pages above the pool are undefined
# for on hardware) and no shorter (a sum that ignores the declaration is a number, not a range).
run_case 5 "the core checks the pool against the sum the image declares, and notices corruption" +POOLSUM
run_case 6 "an out-of-range entry in the viewed part refuses it and names the entry" +BADENT

# run 7: a part select that lands AFTER the boot sweep. It is back in the default sequence, and what
# changed is the design rather than the expectation: the boot sweep now loads all eight parts' tables,
# so a select is a register write the next fetch sees, with no sweep to arm, no arm to lose to
# rst_core, and no dependence on whether the framework delivers the interact write before or after the
# dataslot upload (the ordering task #21 exists to measure). It passes in both benches now - tb_dir
# here, tb_soc +PART=1 with the VM rendering part 1's intro through part 1's table.
run_case 7 "a part select that lands AFTER the boot sweep still installs its own part" +PART=1 +LATESEL
run_case 8 "a corrupt entry in SOMEBODY ELSE's part - boots, reports, and refuses that select" +PART=1 +PARTBAD

# run 9: the encoding the OSD actually uses. A persisted `list` variable writes ONE value to ONE
# address, so the part has to come from the data - and the byte order of an interact write is not
# documented, so the core ORs the low nibble of all four bytes. This run selects part 1 by value and
# then checks the part register, which is the difference between "the write was accepted" and "the
# view moved".
run_case 9 "the part selected by VALUE at the base address (what the OSD list writes)" +PART=1 +VALSEL

[ "$TOTAL" -eq 0 ] || echo "tb_dir: $TOTAL failing exit status across RUNS='$RUNS'"
exit $TOTAL

