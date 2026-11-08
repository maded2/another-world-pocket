#!/usr/bin/env bash
# Build and run the mixer bench, then compare bit-exactly against scripts/ref_mixer.py.
#
# Two runs, and the second is the point: the same scenario with ONE expected sample perturbed must be
# rejected. A bit-exact comparison that cannot fail is decoration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/cores/aw/src/fpga/core"
SIM="$ROOT/cores/aw/src/sim"
WORK="$ROOT/build/mixer-scn"
BAD="$ROOT/build/mixer-scn-bad"

python3 "$ROOT/scripts/mixer_scenario.py" "$WORK" >/dev/null
python3 "$ROOT/scripts/mixer_scenario.py" "$BAD" --perturb >/dev/null

build() {   # build <outdir-that-provides-SCN-at-runtime>
    verilator --binary -j 4 --timing --top-module tb_mixer -Wno-fatal -Wno-lint \
        -DSCN_PATH="\"$1\"" -DTICKS=64 \
        --Mdir "$ROOT/build/obj-mixer" "$CORE/aw_mixer.v" "$SIM/tb_mixer.sv" \
        -o tb_mixer > "$ROOT/build/mixer-build.log" 2>&1 || {
        echo "error: tb_mixer build failed:" >&2; grep -E "%Error" "$ROOT/build/mixer-build.log" | head -10 >&2; exit 1; }
}

build "$WORK"
# NOT `| tail -2`: that discarded every diagnostic the bench printed, which is how three debugging
# attempts in a row "proved" nothing was happening inside the RTL. A harness that hides the output of the
# thing it is testing is the same fault as sim_dbg.sh filtering out its own GOT/WANT diff.
"$ROOT/build/obj-mixer/tb_mixer"

compare() {   # compare <dir> <expect: pass|fail>
python3 - "$1" "$2" <<'PY'
import sys
d, mode = sys.argv[1], sys.argv[2]
exp = [int(x) for x in open(d + "/expect.hex")]
act = [int(x) for x in open(d + "/actual.hex")]
bad = [(i, e, a) for i, (e, a) in enumerate(zip(exp, act)) if e != a]
print("ticks compared: %d (expected %d, actual %d)" % (min(len(exp), len(act)), len(exp), len(act)))
if len(exp) != len(act):
    bad.append((-1, len(exp), len(act)))
if bad:
    print("FAIL - %d samples differ" % len(bad))
    for i, e, a in bad[:8]:
        print("   tick %d: ref %d  rtl %d" % (i, e, a))
    sys.exit(0 if mode == "fail" else 1)
print("PASS - RTL matches the reference bit-exactly over %d ticks" % len(exp))
sys.exit(1 if mode == "fail" else 0)
PY
}

compare "$WORK" pass || { echo "error: the real scenario did not match" >&2; exit 1; }

# The negative control. The comparison above is only worth something if it can reject a one-sample error,
# so the same RTL is run against a scenario whose LAST expected sample is off by one. It must be rejected.
build "$BAD"
"$ROOT/build/obj-mixer/tb_mixer" > /dev/null
echo "--- negative control (one expected sample perturbed) ---"
if compare "$BAD" fail; then
    echo "OK - the comparison rejects a one-sample error"
else
    echo "error: the comparison accepted a perturbed scenario - it is decoration" >&2
    exit 1
fi
