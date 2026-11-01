#!/usr/bin/env bash
# Which stream-restart policy survives a stream that actually drains - decided on the CONSUMER's
# landing addresses, not on the wire.
#
# Why the wire is not enough. Every part1 run this project has ever done in sim reported the same
# thing for every policy: bytes delivered, zero wrong bytes. The modelled PSRAM answers fast
# enough that part1 shows ZERO stream restarts, so the restart path is dead code in that sim and
# no comparison of two policies can produce a difference. Hardware disagreed anyway - the c_start
# policy plays the intro with sheared text, the c_addr policy plays it straight and freezes at
# ~10 s, at the same place every launch. That is the trap this script exists to avoid: an A/B
# whose changed path never executes is not an experiment, it is a rerun.
#
# And why byte-exact delivery still could not have caught the freeze. The bytecode fill loop
# (vm.si:491) writes what it receives into its own 64-byte buffer with
#
#     data.addr = data.wenable ? (data.addr + 1) : 0;
#
# so a cycle without data_available sends its write pointer back to 0. The delivery stays
# correct; the LANDING ADDRESSES do not. tb_soc now checks that directly (u_soc.vm.__mem__data:
# every write, against the pack byte that belongs at that address) and the verdict lines below are
# read from it. The text strip monitor is the other half: op_drawString keeps pix_waddr across
# gaps, so it is the consumer that punishes RE-SERVED bytes - the shear - rather than gaps.
#
#   ./scripts/ab_resume_policy.sh                      # part1, 120 frames, a stall every 64 bytes
#   FRAMES=200 STALL=200 ./scripts/ab_resume_policy.sh
#   PACK=/work/ports/another-world/packs/part0.bin ./scripts/ab_resume_policy.sh
#
# Variants (same stimulus, same bench, one file swapped at a time):
#   1040  commit 0596839        a drained stream resumes at the acceptance's FIRST address
#   1041  HEAD                  it resumes at the next byte the VM owes
#   cand  working tree          resumes at the next byte owed, keeps a prefetch that already IS
#                               the wanted word, and does not restart at all when the word is in
#                               hand (the prefill gate holding a byte is not a reason to tear down)
#
# Each old file is given the SAME stall knob by text substitution, and the script refuses to
# continue if the substitution does not apply exactly once - a control that silently lacks the
# stimulus is how a comparison starts lying. The working tree is restored on every exit path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/cores/aw/src/fpga/core/aw_rom.v"
LOGS="$ROOT/build/logs"
FRAMES="${FRAMES:-120}"
STALL="${STALL:-64}"
PACK="${PACK:-/work/ports/another-world/packs/part1.bin}"
mkdir -p "$LOGS"

CAND="$LOGS/aw_rom.cand.v"
V1040="$LOGS/aw_rom.1040.v"
V1041="$LOGS/aw_rom.1041.v"

cp "$CORE" "$CAND" || { echo "FATAL: cannot save the working tree's aw_rom.v"; exit 1; }
git -C "$ROOT" show 0596839:cores/aw/src/fpga/core/aw_rom.v > "$V1040" || {
    echo "FATAL: cannot extract aw_rom.v at 0596839 (the c_start policy)"; exit 1; }
git -C "$ROOT" show HEAD:cores/aw/src/fpga/core/aw_rom.v > "$V1041" || {
    echo "FATAL: cannot extract aw_rom.v at HEAD (the c_addr policy)"; exit 1; }

# The knob, byte-identical for every file that does not already have it. It makes the wanted word
# ABSENT for one core cycle every STALL_EVERY delivered bytes - what the chip does when the
# successor misses its landing cycle - and never fires inside the boot check, whose gapless
# trailer read is a different bug with a different symptom (hang at frame 0, not a freeze at 10 s).
"$ROOT/scripts/patch_aw_rom_variant.py" "$V1040" "$V1041" || {
    echo "FATAL: could not give the controls the stall knob / probe registers"; exit 1; }

restore() { cp "$CAND" "$CORE"; echo "restored the working tree's aw_rom.v"; }
trap restore EXIT INT TERM

run() {  # run <label> <aw_rom file>
    local label="$1" src="$2"
    local log="$LOGS/ab-$label.log"   # not on the line above: `local a=1 b=$a` reads $a BEFORE it
                                      # is assigned, and this script runs under `set -u`, so the
                                      # whole run died on "label: unbound variable" the first time
    cp "$src" "$CORE"
    echo
    echo "=============== $label  (STALL=$STALL FRAMES=$FRAMES pack=$PACK)"
    STALL="$STALL" FRAMES="$FRAMES" FRAMEDIR="/work/build/sim/soc-frames/ab-$label" \
      timeout 2400 "$ROOT/docker/run-silice.sh" scripts/sim_soc.sh "$PACK" > "$log" 2>&1
    local rc=$?
    # "%Error: ... Verilog $stop" is what a FAILING VERDICT prints (tb_soc asserts at the end of
    # the run), not a compile error - the first version of this check called every failing variant
    # "DID NOT COMPILE" and threw away the three results it was run to collect. Decide on whether
    # a verdict line exists, and only then blame the compiler.
    if ! grep -qE "tb_soc: (FAIL|[0-9]+ frames.*-> PASS)" "$log"; then
        echo "   NO VERDICT (exit $rc) - compile or early crash:"
        grep -E "%Error|%Fatal" "$log" | head -5
        return 1
    fi
    echo "   exit=$rc"
    # Every line below is read straight out of the log; nothing here interprets it.
    grep -E "tb_soc: diagnostics|tb_soc: acceptances|tb_soc: fill buffer|TEXT  :|tb_soc: [0-9]+ frames.* (PASS|FAIL)|tb_soc: FAIL" "$log" | sed 's/^/   /'
    echo "   first FILL SHIFT: $(grep -m1 'FILL SHIFT' "$log" | cut -c1-220)"
    echo "   FILL SHIFT lines: $(grep -c 'FILL SHIFT' "$log")   FILL GAP lines: $(grep -c 'FILL GAP' "$log")"
}

run "1040-c_start" "$V1040"
run "1041-c_addr"  "$V1041"
run "cand"         "$CAND"

echo
echo "Read it as: which policy shifts the fill (that is the freeze), which one re-serves bytes"
echo "(that is the shear), and whether restarts > 0 at all - a variant with 0 restarts under this"
echo "stimulus proves nothing about restarts and must be re-run with a smaller STALL."
for f in "$LOGS"/ab-*.log; do
    [ -f "$f" ] || continue
    echo "--- $(basename "$f")"
    grep -E "tb_soc: fill buffer|tb_soc: diagnostics" "$f" | sed 's/^/   /'
done
