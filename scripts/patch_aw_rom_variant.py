#!/usr/bin/env python3
"""Give an older aw_rom.v the same forced-stall stimulus and the same observability as the
working tree, so scripts/ab_resume_policy.sh can grade every variant with one bench.

Two insertions, both refused-with-error rather than skipped if the anchors do not match:

  1. THE STIMULUS. `word_ok` gains `& ~stall_block`, and stall_block makes the wanted word ABSENT
     for one core cycle every STALL_EVERY delivered bytes - what the chip does on hardware when a
     successor misses its landing cycle, and what the modelled PSRAM never does. Without it part1
     shows zero restarts and no two restart policies can be told apart: the A/B would be a rerun
     wearing a lab coat.

  2. THE OBSERVABILITY. tb_soc's delivery oracle stands aside for an acceptance that deliberately
     re-serves from its own start (that is the correct continuation for a bytecode fill, whose
     write pointer the gap reset, and it is NOT a wrong byte). It decides by probing
     u_rom.resume_from_start, which only the fixed revision has - so a control without it does not
     compile, and a control that instead reported "always re-serving" would have the shear hidden
     from the comparison. These registers are read by nobody in the control's own control flow.

Usage: patch_aw_rom_variant.py <aw_rom.v> [<aw_rom.v> ...]
"""
import sys

WORD_OK_OLD = "    wire word_ok = c_v & (c_waddr == want_word);"

WORD_OK_NEW = """    wire word_ok = c_v & (c_waddr == want_word) & ~stall_block;
`ifdef AW_STALL
    // Inserted by scripts/ab_resume_policy.sh: identical to the working tree's knob, so every
    // variant in the comparison receives exactly the same stimulus.
    wire stall_tick = (c_state == C_RUN) & want & c_v & (c_waddr == want_word)
                    & (c_served | prefill_ok) & ~chk_active;
    `ifdef STALL_EVERY
        localparam integer STALL_N_BYTES = `STALL_EVERY;
    `else
        localparam integer STALL_N_BYTES = 64;
    `endif
    integer stall_n = 0;
    reg     stall_block = 1'b0;
    always @(posedge clk_core) begin
        if (rst_core) begin
            stall_n     <= 0;
            stall_block <= 1'b0;
        end else begin
            if (stall_block) stall_block <= 1'b0;      // one cycle wide, always droppable
            else if (stall_tick) begin
                stall_n <= (stall_n == STALL_N_BYTES - 1) ? 0 : stall_n + 1;
                if (stall_n == STALL_N_BYTES - 1) stall_block <= 1'b1;
            end
        end
    end
`else
    wire stall_block = 1'b0;
`endif"""

PROBE_CSTART = """    // OBSERVABILITY ONLY, inserted by scripts/ab_resume_policy.sh: nothing in this revision's
    // control flow reads it. tb_soc does - its delivery oracle has to stand aside under the same
    // condition for every variant, or the controls cannot be graded by the same bench.
    reg  [20:0] c_start;"""

PROBE_ACCCNT = """    reg  [6:0]  acc_cnt;   // OBSERVABILITY ONLY: bytes delivered in this acceptance"""


def die(msg):
    sys.exit("patch_aw_rom_variant: " + msg)


def insert_after_line(s, needle, addition, what):
    """Insert `addition` after the first line containing `needle`."""
    lines = s.split("\n")
    hits = [i for i, l in enumerate(lines) if needle in l]
    if not hits:
        die("no line containing %r (for %s)" % (needle, what))
    i = hits[0]
    lines.insert(i + 1, addition)
    return "\n".join(lines)


def patch(path):
    s = open(path).read()

    if "AW_STALL" not in s:
        n = s.count(WORD_OK_OLD)
        if n != 1:
            die("%s: expected exactly one word_ok line, found %d - this revision is not the one "
                "the comparison assumes, so it must not be run as a control" % (path, n))
        s = s.replace(WORD_OK_OLD, WORD_OK_NEW)
        knob = "knob"
    else:
        knob = "knob already present"

    # Each probe register is added only if this revision does not already have it, and "already
    # have it" is checked per register rather than per block: build 1040 keeps a REAL c_start (it
    # resumes from it), so declaring one there too would be a duplicate-definition error, while
    # 1041 deleted c_start when its last reader went away and needs all three.
    obs = ""
    if "reg  [20:0] c_start;" not in s:
        s = insert_after_line(s, "reg  [20:0] c_addr;", PROBE_CSTART, "the c_start declaration")
        s = insert_after_line(
            s, "start_addr_r <= {2'b0, acc_addr[20:1]};",
            "                c_start      <= acc_addr;   // OBSERVABILITY ONLY",
            "the acceptance latch")
        s = insert_after_line(
            s, "c_addr       <= 21'd0;",
            "            c_start      <= 21'd0;         // OBSERVABILITY ONLY",
            "the c_start reset")
        obs += " +c_start"
    else:
        obs += " (c_start already real)"
    if "acc_cnt" not in s:
        s = insert_after_line(s, "reg  [20:0] c_addr;", PROBE_ACCCNT, "the acc_cnt declaration")
        s = insert_after_line(
            s, "start_addr_r <= {2'b0, acc_addr[20:1]};",
            "                acc_cnt      <= 7'd0;      // OBSERVABILITY ONLY",
            "the acceptance latch")
        s = insert_after_line(
            s, "c_addr   <= c_addr + 21'd1;",
            "                if (acc_cnt != 7'h7f) acc_cnt <= acc_cnt + 7'd1;  // OBSERVABILITY ONLY",
            "the byte counter")
        s = insert_after_line(
            s, "c_addr       <= 21'd0;",
            "            acc_cnt      <= 7'd0;          // OBSERVABILITY ONLY",
            "the acc_cnt reset")
        obs += " +acc_cnt"
    if "resume_from_start" not in s:
        s = insert_after_line(s, "reg  [20:0] c_addr;",
                              "    wire resume_from_start = ~c_start[20] & (acc_cnt < 7'd64);"
                              "   // OBSERVABILITY ONLY, read by tb_soc",
                              "the resume_from_start wire")
        obs += " +resume_from_start"
    else:
        obs = "+ probe registers already present"

    open(path, "w").write(s)
    print("%s: %s%s" % (path, knob, obs))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        die("usage: patch_aw_rom_variant.py <aw_rom.v> ...")
    for p in sys.argv[1:]:
        patch(p)
