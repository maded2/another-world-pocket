#!/bin/bash
# One-shot SD-card forensics + catalog-cache clear for the aw core stale-bitstream issue.
# Run when the Pocket SD card is in the reader (mounted under /media/*).
set -u
CARD=""
for m in /media/*/*; do
    [ -d "$m/Cores" ] && { CARD="$m"; break; }
done
[ -n "$CARD" ] || { echo "no Pocket SD card found under /media"; exit 1; }
echo "card: $CARD"

TS=$(date +%Y%m%d-%H%M%S)
BK="build/sd/system-backup-$TS"

echo
echo "=== 1. /System/ contents ==="
ls -la "$CARD/System/" 2>/dev/null || echo "(no /System dir)"

echo
echo "=== 2. the five catalog caches (mtime + size) ==="
for f in core_viewby_platform.bin corelist_cache.bin cores_cache.bin \
         platform_viewby_category.bin platforms_cache.bin; do
    [ -f "$CARD/System/$f" ] && stat -c "%y  %s  %n" "$CARD/System/$f"
done

echo
echo "=== 3. search whole card for copies of our OLD bitstreams ==="
# known old hashes (first 16 hex): ae21e5b7e6ac9f12 (Oct25 18:46 build),
# 59b4095b17173869 (Oct25 21:55 build). Current on card should be 2e47de15f1e23b11.
find "$CARD" -type f -size +500k -name "*.rbf*" -print0 2>/dev/null | while IFS= read -r -d '' f; do
    h=$(sha256sum < "$f" | cut -c1-16)
    case "$h" in
        ae21e5b7*) echo "OLD-1846  $f";;
        59b4095b*) echo "OLD-2155  $f";;
        2e47de15*) echo "CURRENT   $f";;
        *)         echo "$h  $f";;
    esac
done

echo
echo "=== 4. any other .rbf-ish files anywhere (size > 500k, any name) ==="
find "$CARD" -type f -size +500k ! -name "*.bin" ! -path "*/Cores/*" ! -path "*/Assets/*" 2>/dev/null | head -20

echo
echo "=== 5. back up /System and delete the five caches ==="
if [ -d "$CARD/System" ]; then
    mkdir -p "$BK"
    cp -a "$CARD/System/." "$BK/" && echo "backed up to $BK"
    for f in core_viewby_platform.bin corelist_cache.bin cores_cache.bin \
             platform_viewby_category.bin platforms_cache.bin; do
        [ -f "$CARD/System/$f" ] && rm -v "$CARD/System/$f"
    done
    sync
    echo "caches cleared. Pocket will rebuild the catalog on next boot."
else
    echo "(no /System dir - nothing to clear)"
fi
