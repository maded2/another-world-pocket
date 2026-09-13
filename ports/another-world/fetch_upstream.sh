#!/usr/bin/env bash
# Fetch the upstream a5k design at the pinned commit into ./upstream/.
#
#   ./ports/another-world/fetch_upstream.sh
#
# The clone is deliberately NOT vendored into this repository: it is upstream
# code (MIT) that we translate, not our source. The exact commit we worked
# against is recorded in UPSTREAM_PIN.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="https://github.com/sylefeb/a5k"
PIN="$(cat "$here/UPSTREAM_PIN")"

if [ -e "$here/upstream/.git" ]; then
    echo "upstream/ already present; fetching $PIN"
    git -C "$here/upstream" fetch --depth 1 origin "$PIN"
    git -C "$here/upstream" checkout -q FETCH_HEAD
else
    echo "cloning $URL at $PIN"
    git clone --depth 1 "$URL" "$here/upstream"
    git -C "$here/upstream" fetch --depth 1 origin "$PIN"
    git -C "$here/upstream" checkout -q FETCH_HEAD
fi

echo "upstream is now at $(git -C "$here/upstream" rev-parse HEAD)"

# Silice pulls shared peripheral sources (PLLs, IO cells, SPRAM model, SPI
# flash controller, UART, VGA/HDMI) into hardware/common/ at build time.
if [ -x "$here/upstream/hardware/common/download_all.sh" ] || \
   [ -f "$here/upstream/hardware/common/download_all.sh" ]; then
    echo "fetching hardware/common/ peripheral sources"
    ( cd "$here/upstream/hardware/common" && bash ./download_all.sh >/dev/null )
fi

echo "done. translate with:"
echo "  docker build -f docker/Dockerfile.silice -t local/ap-silice:latest ."
echo "  docker run --rm -v \$PWD:/work -w /work/ports/another-world/upstream/hardware \\"
echo "    local/ap-silice:latest python3 /opt/Silice/bin/silice-make.py \\"
echo "    -s a5k.si -b icebreaker -p basic,vga,qspiflash,buttons -o BUILD_probe --no_build"
