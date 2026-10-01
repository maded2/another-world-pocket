#!/usr/bin/env bash
# Fast write/read-back test of the pack path: 256 bytes in, 256+16 bytes out.
# scripts/sim_rom.sh does the same with a real pack and every VM access pattern,
# but takes minutes; this one is for when the write path is suspect.
#
#   ./docker/run-silice.sh scripts/sim_write.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${TMPDIR:-/tmp}/aw-sim-write"; mkdir -p "$WORK"; cd "$WORK"
verilator --binary -j 4 --timing --top-module tb_write -Wno-fatal -Wno-lint \
    --Mdir obj "$CORE/aw_rom.v" "$CORE/aw_fifo.v" "$CORE/aw_psram.v" \
    "$SIM/aw_psram_model.v" "$SIM/tb_write.sv" -o tb_write 2>&1 | tail -5
./obj/tb_write ${TRACE:++TRACE}
