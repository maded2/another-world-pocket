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

# delay 500 compresses the module's 8.5 s wait for its first note to ~256 ms; BOTH sides render with
# the same override, so no sample changes - only the timeline.
python3 "$ROOT/scripts/music_scenario.py" "$SCN" --ticks 120 --delay 500 \
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
