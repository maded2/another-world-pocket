#!/usr/bin/env bash
# Host-reset vs load-path ordering (aw_reset_gen). On 2026-10-17 the bridge reset
# was ~reset_n | ~pll_locked, so the pack streamed by `loadf` - which happens while
# the OS still holds the core in reset - was discarded byte for byte. This bench
# keeps that ordering failing in simulation instead of on the device.
#
#   ./docker/run-silice.sh scripts/sim_reset.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-reset}"; mkdir -p "$WORK"; cd "$WORK"
exec 9>"$WORK.lock"
if ! flock -n 9; then echo "note: another tb_reset_gen run holds $WORK.lock - waiting"; flock 9; fi
iverilog -g2005 -o tb_reset_gen.vvp \
    "$CORE/aw_reset_gen.v" "$SIM/tb_reset_gen.sv"
# vvp exits 0 even on a failed test (the bench $finish'es either way), so the
# verdict has to come from its output
OUT=$(./tb_reset_gen.vvp)
echo "$OUT" | grep -E 'PASS|FAIL'
echo "$OUT" | grep -q -- '-> PASS' || { echo "error: tb_reset_gen failed" >&2; exit 1; }
