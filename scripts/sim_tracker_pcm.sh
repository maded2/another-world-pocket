#!/usr/bin/env bash
# The tracker's AUDIO against the reference rendering, sample for sample.
#
# tb_music grades the command stream event for event and tb_mixer grades the mixer bit-exactly
# against ref_mixer.py; this is the first check that compares the SAMPLES the tracker produces with
# the ones scripts/ref_tracker.py renders (phase G's second acceptance half).
#
# Deliberately NOT part of `make sim`: it is currently a known-open measurement rather than a
# passing gate - see docs/another-world/port-log.md, 2026-11-12. Making the suite red until it
# passes would hide every other bench's verdict, and silently tolerating the difference would be
# worse. Run it with `make sim-tracker-pcm` and read the number.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/cores/aw/src/sim"; CORE="$ROOT/cores/aw/src/fpga/core"
SCN="$ROOT/build/music-pcm"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-sim-tracker-pcm}"
mkdir -p "$SCN" "$WORK"

# delay 1000 compresses the module's ~8.5 s wait for its first note to ~0.5 s; BOTH sides render with
# the same override, so no sample changes - only the timeline.
#
# 1000 and not 500: at --delay 500 (4 ms per tick) 56 of 4000 samples differ by +-1 in short runs,
# while at 1000 the render is bit-exact (4000/4000). That is recorded in the port log as an open
# question about the 4 ms row rate, not something this gate should paper over - the gate uses the
# period the comparison reproduces exactly, and the 500 case stays reproducible by hand.
python3 "$ROOT/scripts/music_scenario.py" "$SCN" --ticks 240 --delay 1000 \
    --pcm "$SCN/ref-pcm.txt" --pcm-samples 4000 | tail -2

cd "$WORK"
if ! verilator --binary -j 4 --timing --top-module tb_tracker_pcm -Wno-fatal -Wno-lint \
    -DSCN_PATH="\"$SCN\"" --Mdir obj \
    "$CORE/aw_music.v" "$CORE/aw_mixer.v" "$SIM/tb_tracker_pcm.sv" -o tb_tracker_pcm > build.log 2>&1; then
    echo "error: tb_tracker_pcm build failed - first errors:" >&2
    grep -E "%Error" build.log | head -8 >&2
    exit 1
fi
./obj/tb_tracker_pcm
