#!/usr/bin/env bash
# Environment doctor for the Analogue Pocket openFPGA build env.
#
#   doctor.sh            quick checks (versions, device DB, mounts, disk)
#   doctor.sh --smoke    also run a throwaway Cyclone V compile to prove the
#                        toolchain can place-and-route for the Pocket device
#
# Run it inside the container (make doctor does exactly that).
set -uo pipefail

DEVICE="${AP_DEVICE:-5CEBA4F23C8}"
SMOKE=0
[ "${1:-}" = "--smoke" ] && SMOKE=1

pass=0; warn=0; fail=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
wrn()  { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warn=$((warn+1)); }
head_() { printf '\n== %s\n' "$*"; }

echo "Analogue Pocket openFPGA build environment - doctor"
echo "target device: $DEVICE"

# ---------------------------------------------------------------- quartus ----
head_ "Quartus"
if command -v quartus_sh >/dev/null 2>&1; then
    QV="$(quartus_sh --version 2>/dev/null | tr '\n' ' ')"
    QERR="$(quartus_sh --version 2>&1 >/dev/null || true)"
    if [ -z "$QV" ]; then
        case "$QERR" in
            *"cannot open shared object"*|*libprotobuf*)
                bad "Quartus cannot run as uid $(id -u): the base image ships its tools root-only"
                echo "        fix: make image            (rebuild with FIX_PERMS=1, the default)"
                echo "        or:  AP_RUN_AS=root make build"
                ;;
            *) bad "quartus_sh --version produced no output: $QERR" ;;
        esac
    else
        ok "quartus_sh: $QV"
        case "$QV" in
            *Lite*)         ok "edition is Lite -> no licence file required" ;;
            *Standard*|*Pro*) wrn "edition is not Lite; a licence is required" ;;
            *)              wrn "could not determine Quartus edition" ;;
        esac
    fi
    missing=""
    for t in quartus_map quartus_fit quartus_asm quartus_sta quartus_cdb quartus_pow; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then bad "missing from PATH:$missing"
    else ok "map/fit/asm/sta/cdb/pow all on PATH"; fi
    [ -n "${QUARTUS_ROOTDIR:-}" ] && ok "QUARTUS_ROOTDIR=$QUARTUS_ROOTDIR" \
        || wrn "QUARTUS_ROOTDIR not set"
else
    bad "quartus_sh not on PATH - run inside the container (make doctor)"
fi

# ------------------------------------------------------------ device DB -----
head_ "Cyclone V device support (the Pocket FPGA)"
ROOT="${QUARTUS_ROOTDIR:-/opt/intelFPGA/quartus}"
if [ -d "$ROOT/common/devinfo/cyclonev" ]; then
    n="$(ls "$ROOT/common/devinfo/cyclonev" | wc -l)"
    ok "devinfo/cyclonev present ($n entries)"
else
    for d in "$ROOT"/share/devinfo/cyclonev "$ROOT"/devinfo/cyclonev; do
        [ -d "$d" ] && { ok "devinfo found at $d"; ROOT_FOUND=1; }
    done
    [ "${ROOT_FOUND:-0}" = 1 ] || bad "no Cyclone V device database found under $ROOT"
fi
# the programmer's device tables name the exact part
if ls "$ROOT"/common/devinfo/programmer/*.tab >/dev/null 2>&1; then
    if grep -qs "$DEVICE" "$ROOT"/common/devinfo/programmer/*.tab; then
        ok "device $DEVICE listed in the programmer device table"
    else
        wrn "$DEVICE not found in programmer tables (still worth compiling)"
    fi
fi

# ----------------------------------------------------------------- python ---
head_ "Python (bitstream reversal + packaging)"
if command -v python3 >/dev/null 2>&1; then
    PYV="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)"
    ok "python3 $PYV"
    python3 - <<'EOF' 2>/dev/null && ok "python can import argparse/json/hashlib" || wrn "python stdlib incomplete"
import argparse, hashlib, json
EOF
    [ "${PYV%%.*}" = "3" ] || bad "python3 too old for the tooling"
else
    bad "python3 missing"
fi

# -------------------------------------------------------------------- misc --
head_ "Tooling and workspace"
command -v git >/dev/null 2>&1 && ok "git present" || wrn "git missing (needed to pull core sources)"
command -v make >/dev/null 2>&1 && ok "make present" || wrn "make missing"
case "$(id -u)" in
    0) wrn "running as root - artifacts may end up root-owned on the host" ;;
    *) ok "running as uid $(id -u) (artifacts stay yours)" ;;
esac
[ -w "${HOME:-/nonexistent}" ] && ok "HOME=$HOME is writable" || bad "HOME=$HOME not writable (Quartus needs this)"

here="$(cd "$(dirname "$0")" && pwd)"
for s in build.sh reverse_bits.py package_core.py new_core.sh a5k_translate.sh; do
    [ -f "$here/$s" ] && ok "script $s" || wrn "script $s missing next to doctor.sh"
done

if [ -d /work ] && [ -w /work ]; then
    ok "/work mounted and writable"
    avail="$(df -PBG /work 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')"
    if [ -n "${avail:-}" ] && [ "$avail" -lt 10 ]; then
        wrn "only ${avail}G free on /work - Quartus builds want >=10G"
    else
        ok "${avail:-?}G free on /work"
    fi
    if [ -d /work/cores ]; then
        ok "cores/ present: $(ls /work/cores | tr '\n' ' ')"
    else
        wrn "no /work/cores directory"
    fi
else
    wrn "/work not mounted (fine if you run Quartus natively)"
fi

# ------------------------------------------------------------- smoke test ---
if [ "$SMOKE" = 1 ]; then
    head_ "smoke compile for $DEVICE"
    tmp="$(mktemp -d /tmp/ap_smoke.XXXXXX)"
    cat > "$tmp/smoke.v" <<'EOF'
module smoke (input wire clk, input wire rst, output reg [7:0] q);
always @(posedge clk) if (rst) q <= 8'd0; else q <= q + 8'd1;
endmodule
EOF
    cat > "$tmp/smoke.qpf" <<EOF
QUARTUS_VERSION = "18.1"
PROJECT_REVISION = "smoke"
EOF
    cat > "$tmp/smoke.qsf" <<EOF
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE $DEVICE
set_global_assignment -name TOP_LEVEL_ENTITY smoke
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name GENERATE_RBF_FILE ON
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name EDA_SIMULATION_TOOL "none"
set_global_assignment -name VERILOG_FILE smoke.v
set_global_assignment -name LAST_QUARTUS_VERSION "22.1"
EOF
    # keep the transcript somewhere the host can read it after the container exits
    logdir=/tmp
    if [ -d /work ]; then mkdir -p /work/build 2>/dev/null && logdir=/work/build; fi
    slog="$logdir/smoke_compile.log"
    echo "  project: $tmp/smoke.qpf   log: $slog"
    if (cd "$tmp" && quartus_sh --flow compile smoke.qpf >"$slog" 2>&1); then
        if [ -f "$tmp/output_files/smoke.rbf" ]; then
            ok "compiled for $DEVICE and produced smoke.rbf \
($(stat -c%s "$tmp/output_files/smoke.rbf") bytes) in \
$(grep -o 'Elapsed time: [0-9:]*' "$slog" | tail -1 | cut -d' ' -f3)"
        else
            wrn "flow succeeded but no .rbf was produced"
        fi
        cw="$(grep -c 'Critical Warning' "$slog" 2>/dev/null || echo 0)"
        if [ "${cw:-0}" != "0" ]; then
            # a throwaway project has no pin assignments and no SDC, so Quartus
            # always complains about pin locations here - that is not a fault
            if grep -q 'No exact pin location assignment' "$slog" && \
               [ "$(grep -c 'Critical Warning' "$slog")" = "$cw" ]; then
                ok "$cw critical warning(s), all of them the expected 'no exact pin
        location assignment' for an unconstrained smoke project"
            else
                wrn "$cw critical warning(s); first one:"
                grep -m1 -A1 "Critical Warning" "$slog" | sed 's/^/      /'
            fi
        fi
    else
        bad "smoke compile failed - tail of $slog:"
        tail -15 "$slog" | sed 's/^/      /'
    fi
    if [ "${SMOKE_KEEP:-0}" = "1" ]; then echo "  kept project in $tmp"; else rm -rf "$tmp"; fi
fi

# ------------------------------------------------------------------ verdict -
echo
echo "summary: $pass ok, $warn warning(s), $fail failure(s)"
[ "$fail" -eq 0 ] || exit 1
exit 0
