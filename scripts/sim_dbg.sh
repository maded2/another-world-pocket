#!/usr/bin/env bash
# Debug console + UART transmitter (dbg_console.v, dbg_uart_tx.v). The serial
# line on dbg_tx is new hardware-facing logic with no other test that can see
# it: tb_soc drives the SoC's jstick port directly and never touches dbg_tx, so
# framing, baud rate and message content get their own coverage here. Phase A
# pins the bit geometry (DIV 215 at 24.75 MHz -> 115200 +/- a hair); phase B
# checks every log line byte for byte through a deliberately shallow FIFO so
# backpressure is exercised mid-string.
#
#   ./docker/run-silice.sh scripts/sim_dbg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-dbg}"; mkdir -p "$WORK"; cd "$WORK"
exec 9>"$WORK.lock"
if ! flock -n 9; then echo "note: another tb_dbg_console run holds $WORK.lock - waiting"; flock 9; fi
iverilog -g2005 -o tb_dbg_console.vvp \
    "$CORE/dbg_uart_tx.v" "$CORE/dbg_console.v" "$SIM/tb_dbg_console.v"
# vvp exits 0 even on a failed test (the bench $finish'es either way), so the
# verdict has to come from its output
OUT=$(./tb_dbg_console.vvp)
echo "$OUT" | grep -E 'PASS|FAIL'
echo "$OUT" | grep -q -- '-> PASS' || { echo "error: tb_dbg_console failed" >&2; exit 1; }
