#!/usr/bin/env bash
# Host-side wrapper: run anything in the Silice container (the a5k frontend).
#
#   docker/run-silice.sh                                  # shell in the image
#   docker/run-silice.sh silice --help                    # any command
#   docker/run-silice.sh scripts/a5k_translate.sh         # regenerate build.v
#
# This mirrors docker/run.sh on purpose. The reason it exists: Silice writes
# its whole BUILD_* tree into the repo, and a bare `docker run` (which the
# probe docs used to suggest) runs as root and leaves root-owned files you
# cannot delete from the host without sudo - the BUILD_* directory ends up
# root:root 755, so even unlinking inside it is denied. Running as your uid
# keeps every artifact yours, which is what the rest of this repo promises.
#
# Recognised environment:
#   SILICE_IMAGE   image to run   (default local/ap-silice:latest)
#   AP_RUN_AS      root | user    (default user; root only for tool debugging)
#   DETACH=1       run detached, and keep the container so its log survives
#   RUN_NAME=name  name for the detached container (poll with: docker ps / docker logs name)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${SILICE_IMAGE:-local/ap-silice:latest}"
RUN_AS="${AP_RUN_AS:-user}"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found on PATH" >&2
    exit 127
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "error: image $IMAGE not found - run 'make silice-image' first" >&2
    exit 1
fi

# Silice and its python driver want a writable HOME; keep it in the mount.
mkdir -p "$ROOT/.home"
chmod 777 "$ROOT/.home" 2>/dev/null || true

# Long runs must outlive the call that starts them. `nohup docker run ... &` dies with the
# invoking shell's process group - a 420-frame run vanished this way and left no log at all, so
# there was nothing to report except an intention - and `--rm` deletes the container the moment
# it exits, which leaves `docker logs` with nothing either. So DETACH=1 drops --rm and adds -d.
DETACH="${DETACH:-}"
RUN_NAME="${RUN_NAME:-}"

docker_args=(
    -v "$ROOT:/work"
    -w /work
    -e HOME=/work/.home
    -e SILICE_ROOT=/opt/Silice
    -e PYTHONPATH=/opt/Silice/python
    --label ap-tool=1
)

if [ "$RUN_AS" != "root" ] && [ "$(id -u)" != "0" ]; then
    docker_args+=(--user "$(id -u):$(id -g)")
fi

if [ -n "$DETACH" ]; then
    docker_args+=(-d)
    if [ -n "$RUN_NAME" ]; then docker_args+=(--name "$RUN_NAME"); fi
else
    docker_args+=(--rm)
    if [ $# -eq 0 ] && [ -t 1 ]; then
        docker_args+=(-it)
    elif [ -t 1 ]; then
        docker_args+=(-t)
    fi
fi

# Simulation knobs, forwarded only when set. A bare `docker run` does not inherit the
# caller's environment, which meant `TRACE=1 ... scripts/sim_soc.sh` silently came back
# with no trace and `FRAMES=8` still captured forty - the design then looks like it is
# misbehaving when it is the wrapper ignoring the request. Anything documented by the
# scripts under scripts/ goes through here.
# PART/SECS/SHOTS/REF_DIR belong to scripts/ref_sim.sh (the golden reference run).
for _v in TRACE FRAMES PACE JOBS SIGTAP QUARTUS_ARGS PART SECS SHOTS REF_DIR REF_OUT PERIPHERALS; do
    [ -n "${!_v:-}" ] && docker_args+=(-e "$_v")
done

if [ -n "${AP_EXTRA_MOUNT:-}" ]; then
    IFS=: read -ra extras <<< "$AP_EXTRA_MOUNT"
    for m in "${extras[@]}"; do
        [ -n "$m" ] && docker_args+=(-v "$m")
    done
fi

exec docker run "${docker_args[@]}" "$IMAGE" "$@"
