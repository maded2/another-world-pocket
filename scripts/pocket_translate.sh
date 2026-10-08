#!/usr/bin/env bash
# Translate the Pocket SoC (Silice) into the SystemVerilog Quartus consumes.
#
#   make pocket-translate                        # host side, goes through docker
#   scripts/pocket_translate.sh                  # same thing, inside the container
#
# Input : cores/aw/src/si/aw_pocket.si        (our SoC top; owns display, ROM port,
#                                             framebuffers, blitter, rasterizer)
#         ports/another-world/upstream/hardware/vm.si
#                                             (the VM/processor, unmodified upstream)
# Output: cores/aw/src/fpga/core/aw_pocket_build.v
#
# Why a build directory at all: Silice resolves $include() relative to the file,
# and our top lives elsewhere in the tree, so the sources are staged next to each
# other and the include is pointed at the staged copy. vm.si itself is not
# edited - not for pacing, not for anything (see the pacing note in
# aw_pocket.si for the arithmetic that makes that the right call). Keeping this
# a pure copy is what lets fetch_upstream.sh stay idempotent and lets a diff
# against the pinned upstream commit come back empty.

# Quartus is fed SystemVerilog: Silice emits sized casts such as 12'(...) which
# Verilog-2001 mode rejects (19 syntax errors before, 0 after - see
# docs/another-world/feasibility-probes.md). The board top module is dropped: it
# belongs to a Lattice part and would only bring SB_* primitives with it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW="$ROOT/ports/another-world"
UP="$AW/upstream/hardware"
SI="$ROOT/cores/aw/src/si"
BUILD="$AW/BUILD_pocket"
OUT_V="$ROOT/cores/aw/src/fpga/core/aw_pocket_build.v"

BOARD="${SILICE_BOARD:-icebreaker}"
PERIPH="${SILICE_PERIPH:-basic}"

if [ ! -e /opt/Silice ]; then
    echo "error: /opt/Silice not found - this must run in the Silice image." >&2
    echo "       try:  make pocket-translate" >&2
    exit 1
fi
if [ ! -f "$UP/vm.si" ]; then
    echo "error: $UP/vm.si not found - run ./ports/another-world/fetch_upstream.sh" >&2
    exit 1
fi

# ---------------------------------------------------- staging: sources to build
rm -rf "$BUILD"
mkdir -p "$BUILD"
cp -r "$UP/common" "$BUILD/common"
cp "$UP/vm.si" "$BUILD/vm.si"

# our top, with the include pointed at the staged copy of vm.si
sed -e "s#\$include('../../../ports/another-world/upstream/hardware/vm.si')#\$include('vm.si')#" \
    -e "s#\$include('../../../ports/another-world/upstream/hardware/common/clean_reset.si')#\$include('common/clean_reset.si')#" \
    "$SI/aw_pocket.si" > "$BUILD/aw_pocket.si"
if grep -q "ports/another-world/upstream" "$BUILD/aw_pocket.si"; then
    echo "error: aw_pocket.si still includes something outside the staging dir;" >&2
    echo "       add the path to the rewrite list in this script." >&2
    exit 1
fi
if ! grep -qF "\$include('vm.si')" "$BUILD/aw_pocket.si"; then
    echo "error: could not redirect the vm.si include in aw_pocket.si." >&2
    echo "       the include line it looks for is:" >&2
    echo "         \$include('../../../ports/another-world/upstream/hardware/vm.si')" >&2
    exit 1
fi

# ------------------------------------------------------------------- generate
echo "translating aw_pocket.si for $BOARD [$PERIPH] ..."
cd "$BUILD"
# -a no-pin-check: we are not building for this board, we are asking Silice for
# the design's Verilog. Its ports are the Pocket's (a byte-stream ROM port and a
# DE/HS/VS video bus), none of which exist in a Lattice pin file.
python3 /opt/Silice/bin/silice-make.py -s aw_pocket.si -b "$BOARD" \
    -p "$PERIPH" -o gen --no_build -a no-pin-check

gen="$BUILD/gen/build.v"
if [ ! -s "$gen" ]; then
    echo "error: silice-make.py produced no $gen" >&2
    exit 1
fi

# ------------------------------------------------- drop the Lattice board top
python3 - "$gen" "$OUT_V" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# module top(...) ... endmodule   (first occurrence: the board wrapper)
m = re.search(r'(?m)^module\s+top\b.*?^endmodule\s*$', s, re.S | re.M)
if not m:
    sys.exit("no board 'module top' found in the generated file - check the "
             "silice-make.py invocation before assuming it is safe to drop")
s = s[:m.start()] + "// (board top dropped: it maps pins of a Lattice part; the Pocket\n" \
      "//  top level is apf_top/core_top, which instantiates M_main directly)\n" + s[m.end():]
if 'M_main' not in s:
    sys.exit("generated file has no M_main after stripping the board top")
# Assert what the closing summary used to only print. silice-make.py exits 0 even when the make
# it launches fails, so the existence check above is what catches a missing file - but a
# translation that produced a plausible-looking file while losing the framebuffers, or that left
# a Lattice primitive behind because the board top was not really dropped, sailed through and
# failed much later as a Quartus error about a cell that does not exist on this part, or as a
# design with no pixels. Measured on the current netlist: 0 SB_*, 8 M_videopage definitions.
n_pages = len(re.findall(r'(?m)^\s*module\s+M_videopage', s))
n_sb = len(re.findall(r'\bSB_', s))
if n_sb:
    sys.exit("generated netlist still has {} SB_* Lattice primitives: the board top was not "
             "dropped, and Quartus will fail on cells absent from this part".format(n_sb))
if n_pages < 1:
    sys.exit("generated netlist has no M_videopage module: the framebuffers are missing, so "
             "nothing can be drawn - look at aw_pocket.si, not at Quartus")
open(dst, 'w').write(s)
PY

echo "wrote $OUT_V"
echo "       $(wc -c < "$OUT_V") bytes, $(wc -l < "$OUT_V") lines," \
     "$(grep -cE '^[[:space:]]*module' "$OUT_V") modules"
echo "       SB_ primitives: $(grep -c 'SB_' "$OUT_V" || true) (want 0)"
echo "       framebuffers  : $(grep -c 'module M_videopage' "$OUT_V") videopage modules"
