#!/usr/bin/env bash
# Static lint for the core's own Verilog, with ONE job: fail when a signal the core
# reads is not driven by anything.
#
# Why this exists, in one sentence: an unconnected module input is silently zero,
# not an error. `dbg_console` had the music telemetry ports from AW 1055 but
# `core_top` never connected them after a revert, every capture printed
# "M0 0000 0000 C00 S00 D00" as if it were a measurement, and four hardware
# sessions were spent explaining those zeros. It happened AGAIN with the K field
# (AW 1062 built and printed K0000 from an index tag/count the loader never
# drove), which is what made this check worth building rather than remembering.
#
# The repo's simulation commands all pass -Wno-lint, and tb_dbg_console drives
# dbg_console's ports directly, so neither could ever see the missing wire. This
# runs Verilator with -Wall and NOT -Wno-lint, over an elaboration that includes
# the APF template files, so `core_top` actually resolves.
#
# Two modules cannot be elaborated outside Quartus and get stand-ins:
#   aw_pll      - the altera_pll megafunction (stub below)
#   altsyncram  - cores/aw/src/sim/apf_altsyncram_model.v, the simulation model
#
# Scope: the core's OWN files. The APF template (apf/, core_bridge_cmd.v) and the
# translated Silice design (aw_pocket_build.v) belong to someone else and contain
# dead corners on purpose (they are what upstream does not use), so UNDRIVEN there
# is reported but never fatal. Inputs this core deliberately leaves open are
# allowlisted by name, each with a reason - an entry without a reason is a bug.
#
#   ./docker/run-silice.sh scripts/lint_core.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPGA="$ROOT/cores/aw/src/fpga"
CORE="$FPGA/core"
SIM="$ROOT/cores/aw/src/sim"
WORK="${WORK:-${TMPDIR:-/tmp}/aw-lint}"
LOG="$WORK/lint.log"
mkdir -p "$WORK"
cd "$WORK"

# Stand-in for the PLL: three identical clock outputs, locked high. The lint is
# looking at connectivity, not at a waveform, so what the clocks ARE cannot
# matter - but the module has to exist for core_top to elaborate.
cat > aw_pll_lint_stub.v <<'EOF'
module aw_pll (
    input  wire reset_n,
    input  wire refclk,
    output wire clk_core,
    output wire clk_core90,
    output wire clk_psram,
    output wire locked
);
    assign clk_core   = refclk;
    assign clk_core90 = refclk;
    assign clk_psram  = refclk;
    assign locked     = 1'b1;
endmodule
EOF

# aw_pll.v itself is replaced by the stub, not added to.
CORE_V=$(ls "$CORE"/*.v | grep -v '/aw_pll\.v$')

set +e
# shellcheck disable=SC2086
verilator --lint-only -Wall --top-module core_top -Wno-fatal \
    --Mdir "$WORK/obj" \
    $CORE_V \
    "$FPGA"/apf/*.v \
    "$SIM/apf_altsyncram_model.v" \
    "$WORK/aw_pll_lint_stub.v" >"$LOG" 2>&1
RC=$?
set -e

# Verilator exits non-zero for warnings under -Wno-fatal? No: -Wno-fatal demotes
# them, so a non-zero exit here means an elaboration ERROR, which is its own
# failure. Say so plainly instead of parsing half a log.
if [ "$RC" -ne 0 ] && ! grep -q '^%Warning' "$LOG"; then
    echo "lint_core: verilator could not elaborate core_top:" >&2
    grep -E '^%Error' "$LOG" | head -20 >&2 || true
    echo "  full log: $LOG" >&2
    exit 1
fi

# The core's own files. apf/ and aw_pocket_build.v are out of scope (see header) -
# the Silice design DECLARES memory read ports it does not connect, on purpose.
OWN_RE='cores/aw/src/fpga/core/(aw_[a-z0-9_]+\.v|core_top\.v|dbg_[a-z0-9_]+\.v|pin_ddio_clk\.v)|obj/aw_pll_lint_stub\.v'
NOT_OWN_RE='cores/aw/src/fpga/core/aw_pocket_build\.v$'

# Inputs this core deliberately does not drive, with the reason. Match by signal
# name. Every entry here is a thing the APF framework may assert and this core is
# allowed to ignore; it is NOT a place to silence a missing wire of our own.
allowlisted() {
    case "$1" in
        savestate_*)          echo "APF save-state handshake: this core implements no save states" ;;
        target_dataslot_*)    echo "APF dataslot target handshake: the OS streaming path is used instead" ;;
        target_buffer_*)      echo "APF buffer handshake: this core does not use the buffer target" ;;
        datatable_*)          echo "APF data table: not used by this core" ;;
        *)                    return 1 ;;
    esac
}

FOUND=0
BAD=0
while IFS= read -r line; do
    # "%Warning-UNDRIVEN: path:line:col: Signal is not driven: 'name'"
    path=$(printf '%s\n' "$line" | sed -n 's/^%Warning-UNDRIVEN: \([^:]*\):.*/\1/p')
    name=$(printf '%s\n' "$line" | sed -n "s/.*Signal is not driven: '\([^']*\)'.*/\1/p")
    [ -n "$name" ] || continue
    if ! printf '%s\n' "$path" | grep -Eq "$OWN_RE"; then
        continue
    fi
    if printf '%s\n' "$path" | grep -Eq "$NOT_OWN_RE"; then
        continue
    fi
    FOUND=$((FOUND + 1))
    if reason=$(allowlisted "$name"); then
        echo "  allow  $name ($path) - $reason"
    else
        echo "  FAIL   $name ($path) - nothing drives it" >&2
        BAD=$((BAD + 1))
    fi
done < <(grep '^%Warning-UNDRIVEN:' "$LOG" || true)

if [ "$FOUND" -eq 0 ]; then
    # Not the same thing as a pass: if core_top stopped elaborating far enough to
    # check, "no findings" would be a lie. Say which it is.
    echo "lint_core: no UNDRIVEN warnings at all in the core's own files - suspect the elaboration, not a clean design" >&2
    grep -E '^%(Error|Warning-(MODULE|PINMISSING))' "$LOG" | head -10 >&2 || true
    exit 1
fi

if [ "$BAD" -ne 0 ]; then
    echo "lint_core: $BAD undriven signal(s) in the core's own Verilog - an unconnected input reads as 0 on hardware and as X in simulation" >&2
    echo "  full log: $LOG" >&2
    exit 1
fi

echo "lint_core: $FOUND undriven signal(s), all allowlisted - PASS"
