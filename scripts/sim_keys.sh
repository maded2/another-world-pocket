#!/usr/bin/env bash
# Unit test for the Pocket controller word -> vm.si jstick mapping (cores/aw/src/fpga/core/
# aw_keys.v). Cheap on purpose: a handful of cycles, no pack, no SoC - the point is that the
# mapping has its own coverage instead of being inferred from tb_soc, which drives the SoC's
# jstick port directly and therefore cannot see this path at all.
#
#   ./docker/run-silice.sh scripts/sim_keys.sh
#
# Exit status: 0 pass | 1 the mapping is wrong | other = tooling
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-keys}"; mkdir -p "$WORK"; cd "$WORK"

exec 9>"$WORK.lock"
if ! flock -n 9; then echo "note: another tb_keys run holds $WORK.lock - waiting"; flock 9; fi

if ! verilator --binary -j 4 --timing --top-module tb_keys -Wno-fatal -Wno-lint \
    --Mdir obj "$CORE/aw_keys.v" "$SIM/tb_keys.sv" -o tb_keys > build.log 2>&1; then
    echo "error: tb_keys build failed - first errors:" >&2
    grep -E "%Error" build.log | head -10 >&2
    exit 1
fi
./obj/tb_keys
