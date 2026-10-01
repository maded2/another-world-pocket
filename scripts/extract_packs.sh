#!/usr/bin/env bash
# Turn a licensed *Another World* release into the per-part data packs the
# Pocket core loads.
#
#   make packs                       # host side, goes through docker
#   scripts/extract_packs.sh         # same thing, from inside the container
#
# Input  : gamedata/  (BANK01..BANK0D + memlist.bin from the DOS 19/3/92 release)
# Output : ports/another-world/packs/partN.bin   N = 1..10, 2 MiB each
#          ports/another-world/packs/packs.txt   sizes + segment offsets
#          ports/another-world/packs/parts.env   shell vars used by the build
#
# What a pack is (this is upstream's format, not ours - see
# BUILD/Another-World-Bytecode-Interpreter/src/resource.cpp::dumpDataPack):
#
#   0x000000  bytecode segment
#   ...       cinematic segment
#   ...       palettes segment
#   ...       video2 segment          (part 6 pre-rendered backgrounds)
#   ...       zero pad to 1 MiB
#   ...       pre-rendered glyph/background buffers (stringtable.raw)
#   ...       zero pad to 2 MiB - 32
#   0x1FFFE0  four little-endian uint32 segment offsets, read by the VM at boot
#
# The VM reads those 16 bytes first and derives every other address from them,
# so a pack is self-locating: one file = one game part, no compiled-in offsets.
# That is what lets a single bitstream play every part.
#
# The extractor is GPL code that runs against the user's own copy of the game;
# it is built here, in the container, and never shipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW="$ROOT/ports/another-world"
SRC="$AW/upstream/BUILD/Another-World-Bytecode-Interpreter"
OBJ="$AW/upstream/BUILD/b"
RAW="$OBJ/raw"
GAMEDATA="${GAMEDATA:-$ROOT/gamedata}"
OUT="${PACKS_OUT:-$AW/packs}"

# ---------------------------------------------------------------- input check
need=(memlist.bin bank01 bank02 bank03 bank04 bank05 bank06 bank07 bank08
      bank09 bank0a bank0b bank0c bank0d)
if [ ! -d "$GAMEDATA" ]; then
    echo "error: no game data at $GAMEDATA" >&2
    echo "       the packs cannot be built without your own copy of the game." >&2
    exit 1
fi
missing=0
for f in "${need[@]}"; do
    if [ ! -f "$GAMEDATA/$f" ]; then
        echo "  missing: $GAMEDATA/$f" >&2
        missing=1
    fi
done
if [ "$missing" = 1 ]; then
    echo "error: the DOS 19/3/92 release needs ${#need[@]} files:" >&2
    echo "       BANK01..BANK0D + MEMLIST.BIN (lowercase names on Linux)" >&2
    exit 1
fi

# ------------------------------------------------------------ extractor build
if [ ! -x "$RAW" ]; then
    if [ ! -f "$SRC/CMakeLists.txt" ]; then
        echo "error: extractor source missing at $SRC" >&2
        echo "       run: ./ports/another-world/fetch_upstream.sh  and then" >&2
        echo "       git clone -b a5k https://github.com/sylefeb/Another-World-Bytecode-Interpreter.git \\" >&2
        echo "           $SRC" >&2
        exit 1
    fi
    echo "building the pack extractor (GPL, build-time only) ..."
    mkdir -p "$OBJ"
    ( cd "$OBJ" && cmake "$SRC" -G "Unix Makefiles" > cmake.log 2>&1 && \
      make -j"$(nproc)" > make.log 2>&1 ) || {
        echo "error: extractor build failed; see $OBJ/cmake.log and $OBJ/make.log" >&2
        tail -20 "$OBJ/cmake.log" "$OBJ/make.log" >&2 || true
        exit 1
    }
fi
echo "extractor: $RAW"

# ------------------------------------------------------------------ extraction
mkdir -p "$OUT"
: > "$OUT/packs.txt"
: > "$OUT/parts.env"
{
    echo "# part  file          bytes     segBytecode  segPalettes  segCinematic  segVideo2  status"
    printf '# %-5s %-14s %-9s %-11s %-11s %-12s %-10s %s\n' \
        part file bytes bytecode palettes cinematic video2 status
} >> "$OUT/packs.txt"

ok=0
fail=0
for n in 0 1 2 3 4 5 6 7 8 9; do
    part=$((n + 1))
    run="$AW/upstream/BUILD/run$n"
    rm -rf "$run"; mkdir -p "$run"
    status=ok
    if ! ( cd "$run" && "$RAW" --extract="$n" --datapath="$GAMEDATA" --data-offsets \
            > extract.log 2>&1 ); then
        status="FAILED"
    elif [ ! -s "$run/data.raw" ]; then
        status="NO-OUTPUT"
    fi

    if [ "$status" = ok ]; then
        cp "$run/data.raw" "$OUT/part$part.bin"
        size=$(wc -c < "$OUT/part$part.bin")
        # data.si holds the in-RAM segment starts; the pack trailer holds the
        # same four values as stored in the file.
        bc=$(sed -n 's/^\$\$segBytecode = //p' "$run/data.si" 2>/dev/null || echo 0)
        pa=$(sed -n 's/^\$\$segPalettes = //p' "$run/data.si" 2>/dev/null || echo 0)
        ci=$(sed -n 's/^\$\$segCinematic = //p' "$run/data.si" 2>/dev/null || echo 0)
        v2=$(sed -n 's/^\$\$segVideo2 = //p' "$run/data.si" 2>/dev/null || echo 0)
        # useful bytes: the pack is zero-padded, so the last non-zero byte
        # before the trailer is the real end of content (data + stringtable)
        body=$(python3 - "$OUT/part$part.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
body = len(d) - 16
while body > 0 and d[body - 1] == 0:
    body -= 1
print(body)
PY
)
        printf '%-5s %-14s %-9s %-11s %-11s %-12s %-10s %s (used %s B of 2 MiB)\n' \
            "part$part" "part$part.bin" "$(wc -c < "$OUT/part$part.bin")" \
            "$bc" "$pa" "$ci" "$v2" "$status" "$body" >> "$OUT/packs.txt"
        echo "PACK_PART${part}=1" >> "$OUT/parts.env"
        echo "PACK_PART${part}_BODY=${body}" >> "$OUT/parts.env"
        ok=$((ok + 1))
    else
        printf '%-5s %-14s %-9s %-11s %-11s %-12s %-10s %s\n' \
            "part$part" "-" "-" "-" "-" "-" "$status" >> "$OUT/packs.txt"
        fail=$((fail + 1))
        tail -3 "$run/extract.log" >> "$OUT/packs.txt" 2>/dev/null || true
    fi
    rm -rf "$run"
done

cp "$OUT/packs.txt" /dev/stdout 2>/dev/null || cat "$OUT/packs.txt"
echo
echo "packs : $OUT  ($ok ok, $fail not available)"
echo "size  : $(du -sh "$OUT" | cut -f1) total, $(wc -c < "$OUT/part1.bin" 2>/dev/null || echo 0) bytes each"
