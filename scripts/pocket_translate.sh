#!/usr/bin/env bash
# Translate the Pocket SoC (Silice) into the SystemVerilog Quartus consumes.
#
#   make pocket-translate                        # host side, goes through docker
#   scripts/pocket_translate.sh                  # same thing, inside the container
#
# Input : cores/aw/src/si/aw_pocket.si        (our SoC top; owns display, ROM port,
#                                             framebuffers, blitter, rasterizer)
#         ports/another-world/upstream/hardware/vm.si
#                                             (the VM/processor, upstream plus the
#                                             patches below - each anchored and
#                                             idempotent, applied to the staged copy)
# Output: cores/aw/src/fpga/core/aw_pocket_build.v
#
# Why a build directory at all: Silice resolves $include() relative to the file,
# and our top lives elsewhere in the tree, so the sources are staged next to each
# other and the include is pointed at the staged copy. The staged vm.si is a copy
# of the pinned upstream file with a small, enumerated set of divergences (search
# for "deliberate divergence" below): the part request, the two audio opcodes, and
# the trailer counter re-arm that makes a chapter restart work. Keeping them here
# rather than editing upstream is what lets fetch_upstream.sh stay idempotent and
# lets a diff against the pinned upstream commit come back empty.

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

# ---------------------------------------------------------------------------
# The ONE deliberate divergence from upstream vm.si, applied here so it survives
# fetch_upstream.sh. ports/another-world/upstream is gitignored, so an edit made
# directly to that tree is one fetch away from silently disappearing - the feature
# would still "exist" on this machine and not in any checkout.
#
# What it does: op_updateMemList (h19) carries a resource id, and the desktop engine
# treats an id above the memlist size as "load this game part next"
# (resource.cpp: requestedNextPart = resourceId; vm.cpp: initForPart). The Pocket port
# redirects h19 to op_drawString, which is right for the ids it sees - the extractor
# bakes the pre-rendered buffers into the pack - but it also swallowed the request.
# Recording part-range ids gives the core the chapter change the SCRIPT asks for.
#
# Idempotent: if the port is already there, nothing is inserted.
# ---------------------------------------------------------------------------
python3 - "$BUILD/vm.si" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
port_anchor = "  // leds\n  output uint8  leds(0),\n"
port_add = """  // Part request, as the original engine issues it: op_updateMemList (h19) with an id above the
  // memlist size means "load this game part next" (resource.cpp / vm.cpp: initForPart). Parts are
  // numbered 0x3E80..0x3E89; the core switches the page table when this changes. See
  // scripts/pocket_translate.sh for why this is patched here rather than in the tree.
  output uint16 part_req(0),
"""
body_anchor = "                    // h19 = 00011001\n"
body_add = """                    if (stringId >= 16h3E80 && stringId <= 16h3E89) {
                      part_req = stringId;
                    }
"""
if "output uint16 part_req" not in s:
    assert port_anchor in s, "vm.si: leds anchor not found - upstream changed?"
    s = s.replace(port_anchor, port_anchor + port_add, 1)
if "part_req = stringId;" not in s:
    assert body_anchor in s, "vm.si: h19 anchor not found - upstream changed?"
    s = s.replace(body_anchor, body_anchor + body_add, 1)
open(p, "w").write(s)
print("vm.si: part_req patch applied (or already present)")

# --- audio opcodes -----------------------------------------------------------
# op_playSound (h18) and op_playMusic (h1A) currently SKIP their five argument bytes:
#     mem.addr = mem.addr + 5;
# with the argument reads written but commented out. Re-enable them and publish the values, so the
# core can actually play something. Same pattern as part_req: sticky fields plus a sequence number,
# because the core must notice a REPEATED identical request (the same gunshot twice) and a value
# change alone cannot signal that.
snd_anchor = """                case 8h18: {
                  //uint16 resourceId(0);
                  //uint8  freq(0);
                  //uint8  vol(0);
                  //uint8  channel(0);
                  //(mem,data,resourceId) = nextWord(mem,data);
                  //(mem,data,freq)       = nextByte(mem,data);
                  //(mem,data,vol)        = nextByte(mem,data);
                  //(mem,data,channel)    = nextByte(mem,data);
                  mem.addr = mem.addr + 5;"""
snd_new = """                case 8h18: {
                  uint16 resourceId(0);
                  uint8  freq(0);
                  uint8  vol(0);
                  uint8  channel(0);
                  (mem,data,resourceId) = nextWord(mem,data);
                  (mem,data,freq)       = nextByte(mem,data);
                  (mem,data,vol)        = nextByte(mem,data);
                  (mem,data,channel)    = nextByte(mem,data);
                  snd_res  = resourceId;
                  snd_freq = freq;
                  snd_vol  = vol;
                  snd_ch   = channel;
                  snd_seq  = snd_seq + 1;"""
mus_anchor = """                case 8h1A: {
                  //uint16 resNum(0);
                  //uint16 delay(0);
                  //uint8  pos(0);
                  //(mem,data,resNum) = nextWord(mem,data);
                  //(mem,data,delay)  = nextWord(mem,data);
                  //(mem,data,pos)    = nextByte(mem,data);
                  mem.addr = mem.addr + 5;"""
mus_new = """                case 8h1A: {
                  uint16 resNum(0);
                  uint16 delay(0);
                  uint8  pos(0);
                  (mem,data,resNum) = nextWord(mem,data);
                  (mem,data,delay)  = nextWord(mem,data);
                  (mem,data,pos)    = nextByte(mem,data);
                  mus_num   = resNum;
                  mus_delay = delay;
                  mus_pos   = pos;
                  mus_seq   = mus_seq + 1;"""
if "snd_res  = resourceId;" not in s:
    assert snd_anchor in s, "vm.si: h18 anchor not found - upstream changed?"
    s = s.replace(snd_anchor, snd_new, 1)
if "mus_num   = resNum;" not in s:
    assert mus_anchor in s, "vm.si: h1A anchor not found - upstream changed?"
    s = s.replace(mus_anchor, mus_new, 1)
# the sticky fields, next to the other VM outputs
port_anchor = "  output uint16 part_req(0),\n"
port_add = """  // Audio, as the engine issues it: op_playSound(h18) and op_playMusic(h1A). Sticky fields plus a
  // sequence counter, so the core can tell a REPEATED identical request from no request at all -
  // a value change alone cannot express "the same gunshot twice". See pocket_translate.sh.
  output uint8  snd_seq(0),
  output uint16 snd_res(0),
  output uint8  snd_freq(0),
  output uint8  snd_vol(0),
  output uint8  snd_ch(0),
  output uint8  mus_seq(0),
  output uint16 mus_num(0),
  output uint16 mus_delay(0),
  output uint8  mus_pos(0),
"""
if "output uint8  snd_seq(0)" not in s:
    assert port_anchor in s
    s = s.replace(port_anchor, port_anchor + port_add, 1)

# --- chapter re-entry: re-arm the trailer byte counter -------------------------
# vm_restart returns the generated FSM to ++: (the trailer read), and that is the whole
# mechanism behind a chapter change. But `uint5 n(0);` compiles to a register whose
# initializer is a Verilog POWER-UP value, not part of the algorithm reset:
#
#     reg [4:0] _q___block_167_n = 0;                 // power-up only
#     _q___block_167_n <= _d___block_167_n;           // no (reset) ? 0 term
#
# A cold boot is fine because power-up is 0. A restart is not: n is already 16 when the
# FSM returns to ++:, so `while (~n[4,1])` is false immediately, the new part's 16
# trailer bytes are never consumed, segOffsets keeps the OLD part's four offsets, and
# the VM runs the old chapter's bytecode over the new page table. In tb_soc that is the
# chapter switch's 509/770 shifted fill writes with gaps=0 and rewinds=0 - the stream
# never broke, the view changed underneath it. An explicit `n = 0;` is a real assignment
# in the algorithm, so it is applied every time control reaches ++:, i.e. on every
# restart as well as on the first boot.
#
# Second deliberate divergence from upstream vm.si (the first is part_req above).
rearm_anchor = """    uint5 n(0);
    while (~n[4,1]) {"""
rearm_new = """    uint5 n(0);
    n = 0; // RE-ARM: power-up init is not re-applied by the algorithm reset, so a
           // restart would otherwise enter the loop with n == 16 and skip the trailer.
    while (~n[4,1]) {"""
if "RE-ARM:" not in s:
    assert rearm_anchor in s, "vm.si: trailer counter anchor not found - upstream changed?"
    s = s.replace(rearm_anchor, rearm_new, 1)

# --- CHAPTER RE-ENTRY: give a restart the thread table a cold boot has --------------
# After a chapter restart the VM re-reads the trailer and starts the new script, but the thread
# table still holds the OLD chapter: measured `0000 ffff 24c6 22d1` (thread 0 at its start,
# threads 2 and 3 carrying the previous part's pcs). The first op_pauseThread then schedules
# 0x24c6, the new script runs part 1's branch inside part 2's view, and the polygon it draws
# reads offset 0 with zoom 0 - an empty polygon, black screen, while every byte the ROM serves
# is correct. A cold boot's table is `0000 ffff ffff ...`: thread 0 at pc 0 and every other
# thread INACTIVE (0xffff), with 0xffff in every requested-pc slot and channel-active clear.
# This writes exactly that, before the interpreter starts.
#
# Two traps, both measured: zeroing the table instead of writing 0xffff leaves all 64 threads
# runnable at pc 0 and the engine never settles (0 non-black frames, VM starved at 72 kB); and
# a memory's write enable is defaulted to 0 every cycle by the generated code, so it must be
# asserted INSIDE each loop iteration - setting it once before the loop writes nothing at all,
# which is why the first version of this patch looked like it ran and did nothing.
#
# Fourth deliberate divergence from upstream vm.si.
clear_anchor = """    threadsData.addr    = {1b$PC_OFFSET$,6b0};
    threadsData.wdata   = 0;

    // loop into code execution"""
clear_new = """    threadsData.addr    = {1b$PC_OFFSET$,6b0};
    threadsData.wdata   = 0;

    {
      uint7 tid = 0;
      threadsData.wenable       = 1;
      vmIsChannelActive.wenable = 1;
      while (~tid[6,1]) {
        // wenable must be asserted in EVERY iteration: the generated code defaults every memory's
        // write enable to 0 each cycle, so setting it once before the loop writes nothing at all
        // (measured: the table kept the previous chapter's pcs, which is what made this loop look
        // like it ran and did nothing).
        threadsData.wenable = 1;
        threadsData.addr    = {1b$PC_OFFSET$,tid[0,6]};
        // The state a cold boot is in at its first pause: thread 0 at pc 0, every other thread
        // INACTIVE (0xffff), not merely zero. Zeroing them activates all 64 threads at pc 0 and the
        // engine never settles (measured: 0 non-black frames, the VM starved at 72 kB).
        threadsData.wdata   = (tid[0,6] == 6b000000) ? 16h0000 : 16hFFFF;
      ++:
        threadsData.wenable = 1;
        threadsData.addr    = {1b$REQUESTED_PC_OFFSET$,tid[0,6]};
        threadsData.wdata   = 16hFFFF;
      ++:
        vmIsChannelActive.wenable = 1;
        vmIsChannelActive.addr  = {1b$CURR_STATE$,tid[0,6]};
        vmIsChannelActive.wdata = 0;
        tid = tid + 1;
      }
    }

    // loop into code execution"""
if "uint7 tid = 0;" not in s:
    assert clear_anchor in s, "vm.si: boot-state anchor not found - upstream changed?"
    s = s.replace(clear_anchor, clear_new, 1)

open(p, "w").write(s)
print("vm.si: audio opcode patch applied (or already present); trailer counter re-armed")
PY

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
