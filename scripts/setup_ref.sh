#!/usr/bin/env bash
# Prepare the golden reference: a scratch copy of the upstream a5k design, translated
# and built as a Verilator simulator.
#
#   ./docker/run-silice.sh scripts/setup_ref.sh
#
# The copy is deliberate: ports/another-world/upstream is a pinned tree that must stay
# byte-identical to the commit it came from, so nothing may be built inside it (Silice
# writes BUILD_* trees, a5k expects hardware/data.raw). build/ is gitignored.
#
# Upstream's Makefile does `cd common ; ./download_all.sh` first; that fetches board
# files over the network and the pinned tree already carries what verilator needs, so
# we call silice-make.py directly and report honestly if something is missing.
set -uo pipefail

ROOT=/work
SRC="${UPSTREAM_SRC:-$ROOT/ports/another-world/upstream}"
REF="${REF_DIR:-$ROOT/build/ref/upstream}"
PERIPHERALS="${PERIPHERALS:-basic,vga}"

if [ ! -f "$SRC/hardware/a5k.si" ]; then
    echo "error: no upstream design at $SRC/hardware/a5k.si" >&2
    echo "       run ./ports/another-world/fetch_upstream.sh first" >&2
    exit 1
fi

if [ ! -d "$REF" ]; then
    echo "copying the pinned design to $REF ..."
    mkdir -p "$(dirname "$REF")"
    cp -r "$SRC" "$REF"
    rm -rf "$REF/BUILD"
fi

echo "translating + building the verilator sim (peripherals: $PERIPHERALS) ..."
( cd "$REF/hardware" && silice-make.py -s a5k.si -b verilator -p "$PERIPHERALS" \
      -o BUILD_verilator ) 2>&1 | tail -6

# silice-make.py exits 0 even when the make it launches fails (observed: a missing
# GL/gl.h produced "rc=0" and no executable), so the result is checked, not trusted.
if [ -x "$REF/hardware/BUILD_verilator/obj_dir/Vtop" ]; then
    echo "ok: $REF/hardware/BUILD_verilator/obj_dir/Vtop"
    echo "next: PART=/work/ports/another-world/packs/part2.bin ./docker/run-silice.sh scripts/ref_sim.sh"
    exit 0
fi

echo "error: build produced no Vtop executable (silice-make.py may have reported success" >&2
echo "       anyway - check for 'fatal error' / 'Error 1' in the output above)." >&2
exit 1
