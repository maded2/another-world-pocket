#!/usr/bin/env bash
# Four-state DQ contention check, run under Icarus Verilog (the main suite's
# Verilator is two-state and cannot see two drivers fighting on a bus at all).
# tb_iv_check drives the real aw_psram + aw_psram_model through chained writes
# and back-to-back reads and fails if DQ ever carries an X.
#
#   ./docker/run-silice.sh scripts/sim_iv.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-iv}"; mkdir -p "$WORK"; cd "$WORK"
exec 9>"$WORK.lock"
if ! flock -n 9; then echo "note: another tb_iv_check run holds $WORK.lock - waiting"; flock 9; fi
iverilog -g2005 -o tb_iv_check.vvp \
    "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" "$SIM/tb_iv_check.v"
# vvp exits 0 even on a failed test (the bench $finish'es either way), so the
# verdict has to come from its output
OUT=$(./tb_iv_check.vvp)
echo "$OUT" | grep -E 'PASS|FAIL|X at'
echo "$OUT" | grep -q -- '-> PASS' || { echo "error: tb_iv_check failed" >&2; exit 1; }
