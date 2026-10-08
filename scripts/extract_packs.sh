#!/usr/bin/env bash
# Turn a licensed *Another World* release into the per-part data packs the
# Pocket core loads.
#
#   make packs                       # host side, goes through docker
#   scripts/extract_packs.sh         # same thing, from inside the container
#
# Input  : gamedata/  (BANK01..BANK0D + memlist.bin from the DOS 19/3/92 release)
# Output : ports/another-world/packs/partN.bin   N = 0..9, 2 MiB each
#          The number is the extractor index, which is also upstream's part number:
#          upstream's `make simulN` runs `--extract=N` and its README says N=1 is the intro, so
#          part1.bin is the intro here too. It used to be part$((N+1)).bin, and that off-by-one
#          cost this project two wrong conclusions (a "working design looks broken" run on the
#          protection screen, and a default that pointed at it). part0.bin is the copy-protection
#          screen, near-black in the reference simulator as well.
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
    echo "# offsets are read back from each pack's trailer (last 16 bytes, 4 LE uint32s), which is"
    echo "# what the VM reads at boot. N = the extractor index = upstream's part number: part1.bin"
    echo "# is the intro (upstream 'make simul1'); part0.bin is the copy-protection screen."
} >> "$OUT/packs.txt"

ok=0
fail=0
for n in 0 1 2 3 4 5 6 7 8 9; do
    # N is the extract index verbatim: part1.bin == --extract=1 == upstream's `make simul1` == the
    # intro. The old part$((n+1)) naming made every part number in this repo differ by one from
    # upstream's, which is how the protection screen ended up being the default test target.
    part=$n
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
        # Segment offsets come from the pack trailer: the same 16 little-endian uint32s at len-16
        # that the VM reads at boot, so the table reports what the design actually receives.
        # They used to be scraped from the extractor's data.si, and that is not trustworthy:
        # $$segVideo2 is uninitialised there. Extract 1 printed -644595728, -730292240 and
        # -831914000 on three runs of identical input, while the trailer has held 241363 every
        # time (and the golden reference sim agrees, modulo its 17-bit field). The other three
        # fields matched, which is why nobody noticed: 3 of 4 columns right is how a broken
        # table survives.
        read -r bc pa ci v2 <<< "$(python3 - "$OUT/part$part.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
print(*struct.unpack('<4I', d[-16:]))
PY
)"
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
first="$(ls "$OUT"/part*.bin 2>/dev/null | head -1)"
echo "size  : $(du -sh "$OUT" | cut -f1) total, $(wc -c < "${first:-/dev/null}" 2>/dev/null || echo 0) bytes each"
echo "load  : part1.bin for the intro (same N as upstream's 'make simulN'); part0.bin is the"
echo "        copy-protection screen and is near-black in the reference simulator too"
