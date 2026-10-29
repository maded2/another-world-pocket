#!/usr/bin/env bash
# Assemble cores/<core>/support/loader.asm (Chip32 VM) into cores/<core>/loader.bin.
#
# The Analogue OS stages the selected data-slot file in host memory at boot, but
# the bytes only reach the FPGA when this program streams them with `loadf` -
# without it the pack never moves and the core boots on empty PSRAM (measured
# 2026-10-15: wr_match=0 during a "successful" 2 MiB load). See
# cores/aw/support/loader.asm and docs/another-world/pocket-metadata.md.
#
# Toolchain: the official bass assembler (ARM9/bass, devel branch) with the
# open-fpga/bass-chip32 architecture file. Bootstrapped into build/ on first use,
# mirroring drizzt/openFPGA-MegaDrive scripts/build_loader.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE="${1:-aw}"

ASM="$PROJECT_DIR/cores/$CORE/support/loader.asm"
if [ ! -f "$ASM" ]; then
    echo "no loader program ($ASM), skipping"
    exit 0
fi

ARCH_DIR="$PROJECT_DIR/build/bass-chip32"
BASS_SRC="$PROJECT_DIR/build/bass-src"
BASS_BIN="$ARCH_DIR/bass"

if [ ! -x "$BASS_BIN" ]; then
    mkdir -p "$PROJECT_DIR/build"
    [ -d "$ARCH_DIR" ] || git clone --depth 1 https://github.com/open-fpga/bass-chip32.git "$ARCH_DIR"
    [ -d "$BASS_SRC" ] || git clone --depth 1 -b devel https://github.com/ARM9/bass.git "$BASS_SRC"
    # nall misses <stdexcept> with newer GCC
    grep -q '#include <stdexcept>' "$BASS_SRC/nall/arithmetic/natural.hpp" || \
        sed -i '1a #include <stdexcept>' "$BASS_SRC/nall/arithmetic/natural.hpp"
    make -C "$BASS_SRC/bass" -j"$(nproc)"
    # bass looks for "architectures" next to the executable, so it has to live
    # in the bass-chip32 checkout rather than in its own build tree
    cp "$BASS_SRC/bass/out/bass" "$BASS_BIN"
fi

OUT="$PROJECT_DIR/cores/$CORE/loader.bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ASM" "$TMP/"
( cd "$TMP" && "$BASS_BIN" "$(basename "$ASM")" )
mv -f "$TMP/loader.bin" "$OUT"
echo "loader: $OUT ($(stat -c%s "$OUT") bytes)"
