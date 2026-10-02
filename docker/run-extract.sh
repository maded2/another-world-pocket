#!/usr/bin/env bash
# Host-side wrapper: run anything in the data-pack container.
#
#   docker/run-extract.sh                       # shell in the image
#   docker/run-extract.sh scripts/extract_packs.sh   # gamedata -> partN.bin
#
# Mirrors docker/run.sh / docker/run-silice.sh: the repo is mounted at /work and
# the container runs as your uid, so every pack that lands back in the tree is
# yours. The image is local/ap-extract (see docker/Dockerfile.extract).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${EXTRACT_IMAGE:-local/ap-extract:latest}"
RUN_AS="${AP_RUN_AS:-user}"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found on PATH" >&2
    exit 127
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "error: image $IMAGE not found - run 'make extract-image' first" >&2
    exit 1
fi

mkdir -p "$ROOT/.home"
chmod 777 "$ROOT/.home" 2>/dev/null || true

docker_args=(
    --rm
    -v "$ROOT:/work"
    -w /work
    -e HOME=/work/.home
    --label ap-tool=1
)

# Forward the knobs extract_packs.sh reads, when set. Without this an override is
# silently ignored and the script does the default thing - which for PACKS_OUT
# meant a re-extraction straight over the packs in the tree. Same class of bug as
# run.sh / run-silice.sh forwarding none of TRACE/FRAMES: a wrapper that drops
# the environment turns a mistake into surprise writes.
for var in GAMEDATA PACKS_OUT; do
    if [ -n "${!var:-}" ]; then docker_args+=( -e "$var" ); fi
done

if [ "$RUN_AS" != "root" ] && [ "$(id -u)" != "0" ]; then
    docker_args+=(--user "$(id -u):$(id -g)")
fi

if [ $# -eq 0 ] && [ -t 1 ]; then
    docker_args+=(-it)
elif [ -t 1 ]; then
    docker_args+=(-t)
fi

exec docker run "${docker_args[@]}" "$IMAGE" "$@"
