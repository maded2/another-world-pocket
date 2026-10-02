#!/usr/bin/env bash
# Golden reference simulation: run the *upstream* a5k design, unmodified, with one of
# our data packs, in Silice's verilator simulator.
#
#   ./docker/run-silice.sh scripts/setup_ref.sh                 # once
#   PART=/work/ports/another-world/packs/part2.bin \
#     SECS=90 SHOTS=6 ./docker/run-silice.sh scripts/ref_sim.sh
#
# Why this exists: it is the only way to see what the design is *supposed* to do with
# a given pack, without Pocket hardware. Upstream's own debugging method (README) was
# to diff the hardware trace against the C++ reference; frame-by-frame guessing on our
# own port is what turned a one-line reset polarity bug into days.
#
# Output, under build/ref/run/:
#   trace.log   stdout of the sim (the __display lines from vm.si / a5k.si)
#   frame-N.pnm one screenshot of the VGA window every SECS/SHOTS seconds
#   summary     per-frame colour statistics (non-black fraction, distinct colours)
#
# The sim binary reads ../data.raw relative to its own cwd (frameworks/verilator/
# verilator_data.cpp opens "../data.raw"), so the pack goes one level up from obj_dir.
set -uo pipefail

ROOT=/work
REF="${REF_DIR:-$ROOT/build/ref/upstream/hardware}"
PACK="${PART:-$ROOT/ports/another-world/packs/part2.bin}"
SECS="${SECS:-90}"
SHOTS="${SHOTS:-6}"
OUT="${REF_OUT:-$ROOT/build/ref/run}"
DISPLAY_NUM="${DISPLAY_NUM:-97}"

if [ ! -x "$REF/BUILD_verilator/obj_dir/Vtop" ]; then
    echo "error: no reference sim at $REF/BUILD_verilator/obj_dir/Vtop" >&2
    echo "       build it first: scripts/setup_ref.sh" >&2
    exit 1
fi
if [ ! -f "$PACK" ]; then
    echo "error: pack not found: $PACK" >&2
    exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.pnm "$OUT/trace.log"
cp "$PACK" "$REF/BUILD_verilator/data.raw"
echo "reference sim : $REF/BUILD_verilator/obj_dir/Vtop"
echo "pack          : $PACK ($(wc -c < "$PACK") bytes)"
echo "running       : ${SECS}s, ${SHOTS} screenshots on display :${DISPLAY_NUM}"

Xvfb ":${DISPLAY_NUM}" -screen 0 1024x768x24 >/dev/null 2>&1 &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null; kill "${sim_pid:-}" 2>/dev/null' EXIT
sleep 2

( cd "$REF/BUILD_verilator/obj_dir" && DISPLAY=":${DISPLAY_NUM}" timeout "$SECS" ./Vtop ) \
    > "$OUT/trace.log" 2>&1 &
sim_pid=$!

step=$(( SECS / SHOTS )); [ "$step" -lt 1 ] && step=1
for i in $(seq 1 "$SHOTS"); do
    sleep "$step"
    if xwd -display ":${DISPLAY_NUM}" -root -silent 2>/dev/null | xwdtopnm > "$OUT/frame-$i.pnm" 2>/dev/null \
       && [ -s "$OUT/frame-$i.pnm" ]; then
        :
    else
        echo "  frame $i: capture failed"
    fi
done

kill "$sim_pid" 2>/dev/null
wait "$sim_pid" 2>/dev/null

echo "=== sim stdout (first 12 lines) ==="
head -12 "$OUT/trace.log"

echo "=== frame statistics ==="
python3 - "$OUT" <<'PY'
import glob, os, re, sys
out = sys.argv[1]
def read_pnm(path):
    """Return (w, h, rgb_bytes) for P6 or P7/PAM, or None.

    xwdtopnm emits PAM with 16-bit samples for a 24-bit X display, not PPM, so a
    P6-only parser silently produces garbage statistics on every frame.
    """
    data = open(path, 'rb').read()
    if data.startswith(b'P7'):
        end = data.index(b'ENDHDR') + 7
        hdr = data[:end].decode()
        w = int(re.search(r'WIDTH (\d+)', hdr).group(1))
        h = int(re.search(r'HEIGHT (\d+)', hdr).group(1))
        depth = int(re.search(r'DEPTH (\d+)', hdr).group(1))
        maxv = int(re.search(r'MAXVAL (\d+)', hdr).group(1))
        stride = 2 if maxv > 255 else 1
        body = data[end:]
        px = bytearray()
        for i in range(0, len(body) - depth * stride + 1, depth * stride):
            for c in range(3):
                s = body[i + c * stride:i + c * stride + stride]
                px.append(s[0] if stride == 1 else s[1])
        return w, h, bytes(px)
    if data.startswith(b'P6'):
        p = data.split(None, 3)
        return int(p[1]), int(p[2]), p[3]
    return None
frames = sorted(glob.glob(os.path.join(out, 'frame-*.pnm')))
if not frames:
    print("no frames captured")
for f in frames:
    img = read_pnm(f)
    if img is None:
        print(f"{os.path.basename(f)}: unsupported format - skipping")
        continue
    w, h, px = img
    px = px[:w * h * 3]
    nonblack = sum(1 for i in range(0, len(px), 3) if px[i] or px[i+1] or px[i+2])
    colours = len({(px[i], px[i+1], px[i+2]) for i in range(0, len(px), 3)})
    total = w * h
    print(f"{os.path.basename(f)}: {w}x{h}  non-black {100.0*nonblack/total:5.1f}%  distinct colours {colours}")
PY
echo "artifacts : $OUT"
