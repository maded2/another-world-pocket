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
# Frames land in build/sim/soc-frames/<pack>-<pid>/frameNN.ppm - plain enough to open in
# anything, and `python3 -c ...` or an image viewer will show what the design drew. The dir is
# per run: see the FRAMEDIR note below for why that is not cosmetic.
#
# Long runs: start them detached or they die with the shell that started them.
#   DETACH=1 RUN_NAME=aw-soc FRAMES=600 ./docker/run-silice.sh scripts/sim_soc.sh
#   docker ps; docker logs -f aw-soc
#
# Requires scripts/pocket_translate.sh to have produced cores/aw/src/fpga/core/
# aw_pocket_build.v. Exit status: 0 = frames captured and no mismatch | 1 = see output |
# other = tooling.
set -euo pipefail
set +e   # the run reports its own status

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default is part1.bin: the intro. The part number is the extractor index and matches upstream's
# `make simulN` (README: "use N=1 for the intro"). part0.bin is the copy-protection screen, which
# is nearly black in the reference simulator too - it used to be named part1.bin, and defaulting
# to that made a working design look broken. See docs/another-world/port-log.md.
PACK="${1:-$ROOT/ports/another-world/packs/part1.bin}"
SIM="$ROOT/cores/aw/src/sim"
CORE="$ROOT/cores/aw/src/fpga/core"
FRAMES="${FRAMES:-40}"
# WORK is keyed by the pack. Be precise about what this fixes, because I got it wrong the first
# time: WORK is /tmp, which is container-local, so two separate `docker run` invocations never
# shared it. What actually collided was FRAMEDIR below, on the shared mount. WORK still matters
# for the case that does exist - two sims in one container, e.g. `bash -c "a.sh & b.sh & wait"`
# or an interactive shell - where a fixed dir meant one run rebuilt obj/ and overwrote pack.hex
# underneath the other, so the first reported on bytes it never asked for. Keying by pack makes
# different packs independent; the lock below handles the same-pack case.
SLUG="$(basename "$PACK" .bin)"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-soc-$SLUG}"
LOCK="$WORK.lock"
# The frames have to land somewhere the host can see. This script runs inside a container
# whose /tmp is its own, so writing pictures there meant every "look at a frame" instruction
# pointed at files that did not exist once the container exited. Unique per run for the same
# reason as WORK: with a fixed dir, a run that failed its build is still judged against the
# previous run's frames sitting in it.
FRAMEDIR="${FRAMEDIR:-$ROOT/build/sim/soc-frames/$SLUG-$$}"

[ -f "$PACK" ] || { echo "error: no pack at $PACK" >&2
                    echo "       build them with: ./docker/run-extract.sh scripts/extract_packs.sh" >&2
                    exit 2; }
[ -f "$CORE/aw_pocket_build.v" ] || { echo "error: no $CORE/aw_pocket_build.v" >&2
                    echo "       run: ./docker/run-silice.sh scripts/pocket_translate.sh" >&2
                    exit 2; }

mkdir -p "$WORK" "$FRAMEDIR"

# obj/tb_soc is rebuilt in place, so two runs of the same pack must not build at once: one
# would rebuild underneath the other's running binary. Lock, and say so while waiting, because
# a silent wait is indistinguishable from a design that has stopped producing frames.
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "note: another $SLUG run holds $LOCK - waiting for it (this is not the design stalling)"
    flock 9
fi

python3 - "$PACK" "$WORK/pack.hex" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as fh:
    for b in data:
        fh.write("%02x\n" % b)
print("wrote %s (%d bytes)" % (sys.argv[2], len(data)))
PY

# TRACE=1 wires the design's own rasterizer/busy/paging nets out of the generated netlist
# and prints every change. A black screen with a byte-accurate ROM is either 'the VM stopped
# asking' or 'the VM is waiting on a busy that never falls' and these two bits say which.
DEFINES=()
# verilator takes defines as -D<name>; `--define` is not an option it knows.
[ -n "${TRACE:-}" ] && DEFINES+=(-DSOC_TRACE)
# READTRACE=1 turns on aw_rom's own per-access trace (ACCEPT/LAND/TAKE/REWIND). The stream
# is ~1 kB per frame, so even a 40 frame run prints tens of thousands of lines - cheap
# enough to keep in the script, and it is the only way to see what the reader did around a
# single wrong byte.
[ -n "${READTRACE:-}" ] && DEFINES+=(-DREAD_TRACE)
# STALL=N forces the stream reader to lose the word it needs every N delivered bytes, so the
# restart path runs on schedule instead of never. The modelled PSRAM answers fast enough that
# part1 shows 0 restarts in sim, which is exactly why the bench reported 1040 and 1041 as
# identical while the Pocket froze at 10 s on one and played the intro on the other.
[ -n "${STALL:-}" ] && DEFINES+=(-DAW_STALL -DSTALL_EVERY="$STALL")

cd "$WORK"
# A stale frame directory is worse than no frame directory: the run below fails, the
# listing underneath still shows frames from an earlier run, and the transcript looks
# like a result. Clear it, and check the build's own status (piping verilator to tail
# made $? belong to tail, so a compile error walked straight into the run step and
# reported 'No such file or directory' instead of the error).
rm -rf "$FRAMEDIR"; mkdir -p "$FRAMEDIR"
if ! verilator --binary -j 4 --timing --top-module tb_soc \
    -Wno-fatal -Wno-lint --Mdir obj \
    "${DEFINES[@]}" \
    "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" \
    "$SIM/apf_video_check.sv" \
    "$CORE/aw_pocket_build.v" "$SIM/tb_soc.sv" \
    -o tb_soc > build.log 2>&1; then
    echo "error: tb_soc build failed - first errors:" >&2
    grep -E "%Error" build.log | head -10 >&2
    exit 1
fi

# `role` is prose for the log; `kind` is what the bench grades on. They must agree, and the
# reason is a false alarm that ran for weeks: part0 is near-black in the REFERENCE simulator as
# well, so demanding rich frames from it fails a correct design. The bench now skips the
# rich/black tests only for kind=text and demands a strip instead, so neither kind can be
# satisfied by a design that renders nothing. Override with PACK_KIND=rich|text.
case "$PACK" in
    *part0.bin) role="copy-protection screen (near-black by design; the reference sim is too)"
                kind="text" ;;
    *part1.bin) role="intro - the S1 target, upstream's make simul1"
                kind="rich" ;;
    *)          role="unknown part; see ports/another-world/packs/packs.txt"
                kind="rich" ;;
esac
kind="${PACK_KIND:-$kind}"
echo "pack  : $PACK"
echo "role  : $role"
echo "kind  : $kind (what the verdict is graded on)"
echo "=== run: load, boot, capture $FRAMES frames ==="
./obj/tb_soc "+PACK=$WORK/pack.hex" "+PACE=${PACE:-10}" "+FRAMES=$FRAMES" \
             "+FRAMEDIR=$FRAMEDIR" "+PACK_KIND=$kind" ${EXTRA:-}
# EXTRA carries bench plusargs that are not the pack, e.g.
#   EXTRA=+FUZZ_BRAM=1 ./docker/run-silice.sh scripts/sim_soc.sh
# (the positional argument is the pack, so "$@" could not be used for both)
rc=$?

echo "=== frames ==="
ls -l "$FRAMEDIR" 2>/dev/null | head -8
if [ "$rc" -ne 0 ]; then
    echo "run FAILED (rc=$rc) - any frames above are not from this run" >&2
    exit "$rc"
fi
if [ "$rc" -eq 0 ]; then
    echo "frames are in $FRAMEDIR - look at one before believing the summary"
fi
exit $rc
