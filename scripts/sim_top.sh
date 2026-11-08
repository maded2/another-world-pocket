#!/usr/bin/env bash
# Simulate the WHOLE core_top from power-on: idle screen, pack load over the real
# bridge window, mux switch to game video, host commands, audio pins. The other
# benches test modules; this one tests what the Pocket actually sees first - and it
# is the bench that enforces the APF scaler protocol rules (one-cycle vs/hs, hsync
# >= 3 cycles after vsync, rgb=0 while de low, exactly 320x200 of de per frame) on
# the muxed video pins, from cycle zero.
#
#   ./docker/run-silice.sh scripts/sim_top.sh
#
# Needs scripts/pocket_translate.sh to have produced cores/aw/src/fpga/core/
# aw_pocket_build.v (the M_main netlist). The PLL is a behavioural model
# (apf_pll_model.v); the PSRAM chip is aw_psram_model. Exit status: 0 = PASS |
# 1 = FAIL | other = tooling.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-top}"; mkdir -p "$WORK"; cd "$WORK"

[ -f "$CORE/aw_pocket_build.v" ] || { echo "error: no $CORE/aw_pocket_build.v" >&2
                    echo "       run: ./docker/run-silice.sh scripts/pocket_translate.sh" >&2
                    exit 2; }

exec 9>"$WORK.lock"
if ! flock -n 9; then echo "note: another tb_top run holds $WORK.lock - waiting"; flock 9; fi
if ! verilator --binary -j 4 --timing --top-module tb_top -Wno-fatal -Wno-lint \
    --Mdir obj \
    "$CORE/core_top.v" \
    "$CORE/aw_pll.v" \
    "$CORE/aw_reset_gen.v" \
    "$CORE/aw_rom.v" \
    "$CORE/aw_fifo.v" \
    "$CORE/aw_psram.v" \
    "$CORE/aw_keys.v" \
    "$CORE/aw_audio_tick.v" \
    "$CORE/aw_audio_idx.v" \
    "$CORE/aw_audio_ch.v" \
    "$CORE/aw_mixer.v" \
    "$CORE/aw_audio_rd.v" \
    "$CORE/aw_audio_i2s.v" \
    "$CORE/core_bridge_cmd.v" \
    "$CORE/dbg_console.v" \
    "$CORE/dbg_uart_tx.v" \
    "$CORE/aw_pocket_build.v" \
    "$ROOT/cores/aw/src/fpga/apf/common.v" \
    "$ROOT/cores/aw/src/fpga/apf/mf_datatable.v" \
    "$SIM/apf_pll_model.v" \
    "$SIM/apf_altsyncram_model.v" \
    "$SIM/aw_psram_model.v" \
    "$SIM/apf_video_check.sv" \
    "$SIM/tb_top.sv" \
    -o tb_top > build.log 2>&1; then
    echo "error: tb_top build failed - first errors:" >&2
    grep -E "%Error" build.log | head -10 >&2
    exit 1
fi
./obj/tb_top
