#!/usr/bin/env bash
# Compile an Analogue Pocket core with Quartus, then produce the reversed
# bitstream the Pocket actually loads (bitstream.rbf_r).
#
# Runs anywhere Quartus is on PATH - normally inside the ap-pocket container
# (see docker/run.sh), where the repo is mounted at /work.
#
#   build.sh cores/mygame                      # find *.qpf, compile, reverse
#   build.sh cores/mygame --rev default --jobs 16
#   build.sh cores/mygame --no-sigtap          # build without SignalTap (faster)
#   build.sh cores/mygame --clean              # wipe Quartus DB first
#   build.sh cores/mygame --report-only        # re-parse existing reports only
#   build.sh --qpf src/fpga/ap_core.qpf        # explicit project
#
# Outputs under --out (default <repo>/build/<core>/):
#   compile.log          full Quartus transcript
#   <rev>.rbf/.sof       copies of the programming files
#   bitstream.rbf_r      reversed bitstream -> goes into Cores/<Author>.<Core>/
#   report.txt           device, utilisation, timing, hashes
#
# Temporary build-time QSF tweaks (SignalTap off, parallelism) are applied to a
# copy and the original QSF is always restored, so the tree stays clean.
#
# Exit status: 0 ok | 1 compile/tooling failure | 3 timing violation
set -uo pipefail

CORE_DIR=""; QPF=""; REV=""; OUT=""
JOBS="${JOBS:-}"
SIGTAP="${SIGTAP:-keep}"          # keep | off | on
DO_CLEAN=0; DO_REVERSE=1; REPORT_ONLY=0

die() { echo "[build] error: $*" >&2; exit 1; }
log() { echo "[build] $*"; }

usage() { sed -n '2,28p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --qpf)          QPF="$2"; shift 2 ;;
        --rev)          REV="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --no-sigtap)    SIGTAP="off"; shift ;;
        --sigtap)       SIGTAP="on"; shift ;;
        --clean)        DO_CLEAN=1; shift ;;
        --no-reverse)   DO_REVERSE=0; shift ;;
        --report-only)  REPORT_ONLY=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             die "unknown option $1 (try --help)" ;;
        *)              CORE_DIR="$1"; shift ;;
    esac
done

command -v quartus_sh >/dev/null 2>&1 || \
    die "quartus_sh not on PATH - run me inside the container: docker/run.sh build.sh ..."

# The base Quartus image ships its install root-only (restrictive umask at
# build time).  A fix-perms image (docker/Dockerfile FIX_PERMS=1, the default)
# repairs that; otherwise the tools must run as root.
probe_msg="$(quartus_sh --version 2>&1 >/dev/null)" || {
    case "$probe_msg" in
        *"cannot open shared object"*|*libprotobuf*)
            echo "[build] Quartus cannot run as uid $(id -u): $probe_msg" >&2
            echo "[build] the base image's tools are root-only. Either" >&2
            echo "[build]   make image                 (rebuild with FIX_PERMS=1, the default)" >&2
            echo "[build] or" >&2
            echo "[build]   AP_RUN_AS=root make build  (artifacts are chowned back)" >&2
            exit 1 ;;
        *) die "quartus_sh --version failed: $probe_msg" ;;
    esac
}

# when running as root inside the container, hand files back to the host user
chown_back() {
    [ "$(id -u)" = "0" ] || return 0
    [ -n "${AP_CHOWN:-}" ] || return 0
    for d in "$@"; do
        [ -e "$d" ] && chown -R "$AP_CHOWN" "$d" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# locate the Quartus project
# ---------------------------------------------------------------------------
[ -n "$CORE_DIR" ] && { [ -d "$CORE_DIR" ] || die "no such core dir: $CORE_DIR"; }

if [ -z "$QPF" ]; then
    [ -n "$CORE_DIR" ] || die "usage: build.sh <core-dir> [--qpf path/to/x.qpf] [opts]"
    for cand in "$CORE_DIR"/src/fpga/*.qpf "$CORE_DIR"/src/*.qpf "$CORE_DIR"/*.qpf \
                "$CORE_DIR"/projects/*.qpf "$CORE_DIR"/*/*.qpf; do
        [ -f "$cand" ] && { QPF="$cand"; break; }
    done
fi
[ -n "$QPF" ] && [ -f "$QPF" ] || die "no .qpf found under ${CORE_DIR:-.} (pass --qpf)"
QPF="$(cd "$(dirname "$QPF")" && pwd)/$(basename "$QPF")"
PROJ_DIR="$(dirname "$QPF")"
NAME="$(basename "$QPF" .qpf)"
QSF="$PROJ_DIR/$NAME.qsf"

if [ -n "$CORE_DIR" ]; then CORE_NAME="$(basename "$CORE_DIR")"; else CORE_NAME="$(basename "$PROJ_DIR")"; fi

# revision: --rev, else PROJECT_REVISION in the qpf, else the project name
if [ -z "$REV" ]; then
    REV="$(sed -n 's/^[[:space:]]*PROJECT_REVISION[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
           "$QPF" 2>/dev/null | tail -1)"
fi
[ -n "$REV" ] || REV="$NAME"

# output dir: --out, else <repo>/build, else /tmp/ap-build
# The ap-tool workspace root is the directory that holds cores/ - i.e. the
# parent of the "cores" path element.  Falls back to next to the project.
repo_root() {
    d="$PROJ_DIR"
    while [ "$d" != "/" ]; do
        [ "$(basename "$d")" = "cores" ] && { dirname "$d"; return; }
        d="$(dirname "$d")"
    done
    if [ -d "$PWD/cores" ]; then echo "$PWD"; return; fi
    dirname "$PROJ_DIR"
}
if [ -z "$OUT" ]; then
    OUT="$(repo_root)/build"
fi
OUT="${OUT%/}/$CORE_NAME"
mkdir -p "$OUT" || die "cannot write to $OUT"

[ -n "$JOBS" ] || JOBS="$(nproc 2>/dev/null || echo 4)"
DEV="$(sed -n 's/.*-name DEVICE  *\([^ ]*\).*/\1/p' "$QSF" 2>/dev/null | head -1)"
FAM="$(sed -n 's/.*-name FAMILY  *"\([^"]*\)".*/\1/p' "$QSF" 2>/dev/null | head -1)"
OF="$PROJ_DIR/output_files"

log "core     : $CORE_NAME"
log "project  : $QPF  (revision $REV)"
log "device   : ${DEV:-unknown}  family ${FAM:-unknown}"
log "jobs     : $JOBS   signalTap: $SIGTAP"
log "output   : $OUT"

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
if [ "$DO_CLEAN" = 1 ]; then
    log "cleaning Quartus databases and outputs"
    rm -rf "$PROJ_DIR/db" "$PROJ_DIR/incremental_db" "$PROJ_DIR/greybox_tmp" \
           "$PROJ_DIR/c5_pin_model_dump.txt" 2>/dev/null
    rm -f "$PROJ_DIR/output_files"/*.rbf "$PROJ_DIR/output_files"/*.sof \
          "$PROJ_DIR"/*.rpt "$PROJ_DIR"/*.summary "$PROJ_DIR"/*.smsg 2>/dev/null
    rm -rf "$OUT"
    mkdir -p "$OUT"
fi

# ---------------------------------------------------------------------------
# temporary build-time QSF tweaks, always restored
# ---------------------------------------------------------------------------
BAK="$QSF.ap-tool-bak"
restore_qsf() {
    if [ -f "$BAK" ]; then
        mv -f "$BAK" "$QSF"
        log "restored original $QSF"
    fi
}
trap 'restore_qsf' EXIT INT TERM

if [ "$REPORT_ONLY" = 0 ] && [ -f "$QSF" ]; then
    need_bak=0
    grep -q 'ENABLE_SIGNALTAP ON' "$QSF" && [ "$SIGTAP" = "off" ] && need_bak=1
    grep -q 'NUM_PARALLEL_PROCESSORS' "$QSF" || need_bak=1
    if [ "$need_bak" = 1 ]; then
        cp -p "$QSF" "$BAK" || die "cannot back up $QSF"
        [ "$SIGTAP" = "off" ] && \
            sed -i 's/-name ENABLE_SIGNALTAP ON/-name ENABLE_SIGNALTAP OFF/' "$QSF"
        if grep -q 'NUM_PARALLEL_PROCESSORS' "$QSF"; then
            sed -i "s/-name NUM_PARALLEL_PROCESSORS .*/-name NUM_PARALLEL_PROCESSORS $JOBS/" "$QSF"
        else
            # Quartus writes these files CRLF and sometimes without a trailing
            # newline - appending blindly would corrupt the last assignment.
            [ -n "$(tail -c 1 "$QSF")" ] && printf '\r\n' >> "$QSF"
            printf 'set_global_assignment -name NUM_PARALLEL_PROCESSORS %s\r\n' "$JOBS" >> "$QSF"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# compile
# ---------------------------------------------------------------------------
start=$(date +%s)
if [ "$REPORT_ONLY" = 0 ]; then
    # one transcript per build, not an append of every attempt since 2019
    : > "$OUT/compile.log"
    # quartus_sh --flow takes -c/--rev for the revision name
    flow_args=(--flow compile "$QPF" -c "$REV")
    [ -n "${QUARTUS_ARGS:-}" ] && { read -ra extra <<< "$QUARTUS_ARGS"; flow_args+=("${extra[@]}"); }
    log "running: quartus_sh ${flow_args[*]}"
    quartus_sh "${flow_args[@]}" 2>&1 | tee -a "$OUT/compile.log"
    status=${PIPESTATUS[0]}
    if [ "$status" -ne 0 ]; then
        restore_qsf
        chown_back "$PROJ_DIR" "$OUT"
        trap - EXIT INT TERM
        echo "[build] quartus_sh --flow compile failed (rc=$status)." >&2
        grep -E '^Error' "$OUT/compile.log" | tail -12 | sed 's/^/    /' >&2
        echo "[build] stale Quartus databases are the usual cause once a core is" \
             "re-targeted to another device - retry with: make clean-build CORE=$CORE_NAME" >&2
        exit 1
    fi
fi
elapsed=$(( $(date +%s) - start ))
restore_qsf
trap - EXIT INT TERM

# ---------------------------------------------------------------------------
# collect bitstream
# ---------------------------------------------------------------------------
RBF=""; SOF=""
for cand in "$OF/$REV.rbf" "$OF"/*.rbf "$PROJ_DIR/$REV.rbf"; do
    [ -f "$cand" ] && { RBF="$cand"; break; }
done
for cand in "$OF/$REV.sof" "$OF"/*.sof; do
    [ -f "$cand" ] && { SOF="$cand"; break; }
done

if [ -z "$RBF" ] && [ -n "$SOF" ]; then
    log "no .rbf in the flow output; converting with quartus_cdb"
    quartus_cdb "$QPF" -s "$REV" --convert rbf \
        --output_document "$OF/$REV.rbf" 2>&1 | tee -a "$OUT/compile.log" || true
    [ -f "$OF/$REV.rbf" ] && RBF="$OF/$REV.rbf"
fi

REPORT="$OUT/report.txt"
{
    echo "=== Analogue Pocket core build report"
    echo "core       : $CORE_NAME"
    echo "project    : $QPF"
    echo "revision   : $REV"
    echo "device     : ${DEV:-?}  (family ${FAM:-?})"
    echo "quartus    : $(quartus_sh --version 2>/dev/null | sed -n '1,2p' | tr '\n' ' ')"
    echo "elapsed    : ${elapsed}s"
} > "$REPORT"

rc=0
if [ -n "$RBF" ]; then
    cp -f "$RBF" "$OUT/"
    [ -n "$SOF" ] && cp -f "$SOF" "$OUT/"
    {
        echo "rbf        : $RBF ($(stat -c%s "$RBF") bytes)"
        [ -n "$SOF" ] && echo "sof        : $SOF"
        echo "sha256(rbf): $(sha256sum "$RBF" | cut -d' ' -f1)"
    } >> "$REPORT"
else
    echo "rbf        : NOT PRODUCED - check the log for Quartus errors" >> "$REPORT"
    rc=1
fi

# ---------------------------------------------------------------------------
# fitter + timing summaries
# ---------------------------------------------------------------------------
pick() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; echo ""; }

summ="$(pick "$OF/$REV.fit.summary" "$PROJ_DIR/$REV.fit.summary")"
if [ -n "$summ" ]; then
    echo "--- fitter summary ---" >> "$REPORT"
    sed 's/ ; / = /; s/;/ = /; s/[[:space:]]*$//' "$summ" | sed '/^$/d; s/^/  /' >> "$REPORT"
fi

sta_sum="$(pick "$OF/$REV.sta.summary" "$PROJ_DIR/$REV.sta.summary")"
if [ -n "$sta_sum" ]; then
    echo "--- timing summary (STA) ---" >> "$REPORT"
    sed '/^$/d; s/^/  /' "$sta_sum" >> "$REPORT"
    neg="$OUT/.negative_slack"
    awk '{
            n = split($0, f, /[ \t;:]+/)
            for (i = 1; i <= n; i++)
                if (f[i] ~ /^-?[0-9]+\.[0-9]+$/ && (f[i] + 0) < -0.0005) { print; next }
        }' "$sta_sum" > "$neg" 2>/dev/null
    if [ -s "$neg" ]; then
        {
            echo ""
            echo "!!! TIMING VIOLATION: negative slack in at least one corner"
            sed 's/^/    /' "$neg"
        } >> "$REPORT"
        echo >&2
        echo "[build] !! timing violation - negative slack:" >&2
        sed 's/^/    /' "$neg" >&2
        if [ "${ALLOW_TIMING_FAIL:-0}" = "1" ]; then
            echo "[build]    continuing (ALLOW_TIMING_FAIL=1). A core that fails STA" \
                 "can still work, but expect intermittent bugs." >&2
        else
            echo "[build]    failing the build. Re-run with ALLOW_TIMING_FAIL=1 to" \
                 "produce a bitstream anyway." >&2
            rc=3
        fi
    fi
    rm -f "$neg"
else
    echo "--- timing: no .sta.summary found ---" >> "$REPORT"
fi

# ---------------------------------------------------------------------------
# reverse the bitstream (rbf -> rbf_r)
# ---------------------------------------------------------------------------
if [ "$DO_REVERSE" = 1 ] && [ -n "$RBF" ]; then
    here="$(cd "$(dirname "$0")" && pwd)"
    if python3 "$here/reverse_bits.py" --device "${DEV:-5CEBA4F23C8}" \
           "$RBF" "$OUT/bitstream.rbf_r" 2>&1 | tee -a "$OUT/compile.log"; then
        echo "rbf_r      : $OUT/bitstream.rbf_r" >> "$REPORT"
    else
        echo "rbf_r      : REVERSAL FAILED" >> "$REPORT"
        rc=1
    fi
fi

chown_back "$PROJ_DIR" "$OUT"

echo
cat "$REPORT"
echo
if [ "$rc" = "0" ]; then
    log "done -> $OUT/bitstream.rbf_r"
    log "package: python3 scripts/package_core.py --core-dir ${CORE_DIR:-<core>} \
--bitstream $OUT/bitstream.rbf_r --out ${OUT%/*}/sd --zip"
elif [ "$rc" = "3" ]; then
    log "finished with timing violations"
else
    log "finished with errors - see $OUT/compile.log"
fi
exit "$rc"
