#!/usr/bin/env bash
# All four audio benches. Any one failing must fail the target.
#
# These were written ad hoc through docker while the modules were being built, which meant nothing stopped
# them regressing - and this crate has already been bitten by a bench that was red and silently excluded from
# `make sim` (tb_dbg_console, which is how the boot banner lied for two releases). So they belong here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/cores/aw/src/fpga/core"
SIM="$ROOT/cores/aw/src/sim"
OBJ="$ROOT/build/obj-audio"
mkdir -p "$OBJ" "$ROOT/build/audio-idx"

fail=0

# 1. the reference mixer's self-checks, then the RTL against it INCLUDING the perturbed negative control.
#    Delegated to sim_mixer.sh rather than duplicated: that script already builds both scenarios and fails if
#    the comparison accepts a one-sample error, and two copies of a comparison drift.
echo "=== ref_mixer self-checks ==="
python3 "$ROOT/scripts/ref_mixer.py" || { echo "   ref_mixer self-check FAILED"; fail=1; }
echo "=== tb_mixer: RTL vs reference, bit-exact + negative control ==="
bash "$ROOT/scripts/sim_mixer.sh" > "$OBJ/mixer.log" 2>&1
if [ $? -ne 0 ]; then
    echo "   FAILED - last lines:"; tail -4 "$OBJ/mixer.log"; fail=1
else
    grep -e "^PASS -" -e "rejects a one-sample error" "$OBJ/mixer.log" | sed 's/^/   /'
fi

# 2. the 48 kHz tick over a full second
echo "=== tb_audio_tick: 48000 ticks per second ==="
if ! verilator --binary -j 4 --timing --top-module tb_audio_tick -Wno-fatal -Wno-lint \
        --Mdir "$OBJ/tick" "$CORE/aw_audio_tick.v" "$SIM/tb_audio_tick.sv" -o tb_tick > "$OBJ/tick.log" 2>&1; then
    echo "   build FAILED"; grep -E "%Error" "$OBJ/tick.log" | head -5; fail=1
else
    "$OBJ/tick/tb_tick" | grep -e "PASS" -e "FAIL" || fail=1
fi

# 3. index lookup against an oracle dumped from the IMAGE
echo "=== tb_audio_idx: every id resolves ==="
IMG="$ROOT/build/aw-all-audio.bin"
if [ ! -f "$IMG" ]; then
    echo "   (no $IMG - build it with scripts/build_combined_image.py first)"; fail=1
else
    python3 "$ROOT/scripts/audio_idx_dump.py" "$IMG" "$ROOT/build/audio-idx" >/dev/null
    if ! verilator --binary -j 4 --timing --top-module tb_audio_idx -Wno-fatal -Wno-lint \
            -DSCN_PATH="\"$ROOT/build/audio-idx\"" \
            --Mdir "$OBJ/idx" "$CORE/aw_audio_idx.v" "$SIM/tb_audio_idx.sv" -o tb_idx > "$OBJ/idx.log" 2>&1; then
        echo "   build FAILED"; grep -E "%Error" "$OBJ/idx.log" | head -5; fail=1
    else
        "$OBJ/idx/tb_idx" | grep -e "lookups" || fail=1
    fi
fi

# 4. controller: exactly one command per request, right fields
echo "=== tb_audio_rd: byte shim across two clocks, variable responder ==="
if ! verilator --binary -j 4 --timing --top-module tb_audio_rd -Wno-fatal -Wno-lint \
        --Mdir "$OBJ/rd" "$CORE/aw_audio_rd.v" "$SIM/tb_audio_rd.sv" -o tb_rd > "$OBJ/rd.log" 2>&1; then
    echo "   build FAILED"; grep -E "%Error" "$OBJ/rd.log" | head -5; fail=1
else
    "$OBJ/rd/tb_rd" | grep -e "issued" || fail=1
fi

echo "=== tb_audio_i2s: the DAC stream decoded back to samples ==="
if ! verilator --binary -j 4 --timing --top-module tb_audio_i2s -Wno-fatal -Wno-lint \
        --Mdir "$OBJ/i2s" "$CORE/aw_audio_i2s.v" "$CORE/aw_fifo.v" "$SIM/tb_audio_i2s.sv" -o tb_i2s > "$OBJ/i2s.log" 2>&1; then
    echo "   build FAILED"; grep -E "%Error" "$OBJ/i2s.log" | head -5; fail=1
else
    "$OBJ/i2s/tb_i2s" | grep -e "tb_audio_i2s" || fail=1
fi

echo "=== tb_music: the tracker against scripts/ref_tracker.py, event for event ==="
SCN="$ROOT/build/music-scn"
mkdir -p "$SCN"
python3 "$ROOT/scripts/music_scenario.py" "$SCN" --ticks 1100 --delay 15700 > "$OBJ/music-scn.log" 2>&1 || {
    echo "   scenario generation FAILED"; tail -3 "$OBJ/music-scn.log"; fail=1; }
if ! verilator --binary -j 4 --timing --top-module tb_music -Wno-fatal -Wno-lint \
        -DSCN_PATH="\"$SCN\"" --Mdir "$OBJ/music" \
        "$CORE/aw_music.v" "$SIM/tb_music.sv" -o tb_music > "$OBJ/music.log" 2>&1; then
    echo "   build FAILED"; grep -E "%Error" "$OBJ/music.log" | head -5; fail=1
else
    "$OBJ/music/tb_music" | grep -e "events compared" || fail=1
fi

# Modules 137 and 138: the other two MUSIC resources in the image. Neither was ever reached by a
# 25-60 frame harvest run, and both play LOOPING instruments (loop=5728+21392 and 3226+3482), so
# this is the coverage the harvest could not give: the same bench, the same reference, the two
# modules the game has not asked for yet.
for M in 137 138; do
    echo "=== tb_music: module $M, event for event ==="
    SCNM="$ROOT/build/music-$M"; mkdir -p "$SCNM"
    python3 "$ROOT/scripts/music_scenario.py" "$SCNM" --res $M --delay 1000 --ticks 200 \
        > "$OBJ/music-$M-scn.log" 2>&1 || {
        echo "   scenario generation FAILED"; tail -3 "$OBJ/music-$M-scn.log"; fail=1; continue; }
    if ! verilator --binary -j 4 --timing --top-module tb_music -Wno-fatal -Wno-lint \
            -DSCN_PATH="\"$SCNM\"" -DRES_VAL=$M -DDELAY_VAL=1000 -DTICK_MS=8 \
            --Mdir "$OBJ/music$M" \
            "$CORE/aw_music.v" "$SIM/tb_music.sv" -o tb_m$M > "$OBJ/music$M.log" 2>&1; then
        echo "   build FAILED"; grep -E "%Error" "$OBJ/music$M.log" | head -5; fail=1
    else
        "$OBJ/music$M/tb_m$M" | grep -e "events compared" || fail=1
    fi
done

echo "=== tb_audio_ch: play / stop / unknown id ==="
if ! verilator --binary -j 4 --timing --top-module tb_audio_ch -Wno-fatal -Wno-lint \
        --Mdir "$OBJ/ch" "$CORE/aw_audio_idx.v" "$CORE/aw_audio_ch.v" "$SIM/tb_audio_ch.sv" -o tb_ch > "$OBJ/ch.log" 2>&1; then
    echo "   build FAILED"; grep -E "%Error" "$OBJ/ch.log" | head -5; fail=1
else
    "$OBJ/ch/tb_ch" | grep -e "checks," || fail=1
fi

[ "$fail" -eq 0 ] && echo "sim_audio: all audio benches passed" || echo "sim_audio: FAILED"
exit $fail
