#!/usr/bin/env bash
# Host-side wrapper: run anything in the Pocket build container.
#
#   docker/run.sh                       # interactive shell in the image
#   docker/run.sh quartus_sh --version  # any command, same mounts/env
#   docker/run.sh build.sh cores/mygame # the compile driver
#
# The repo is bind-mounted at /work, so ./cores/<name> is /work/cores/<name>.
# By default the container runs as *your* uid/gid so build artifacts are not
# root-owned.  That requires an image built with FIX_PERMS=1 (the default);
# if you built with PERMS=0 the Quartus install is root-only and you must use
# AP_RUN_AS=root - the entrypoint then chowns the output back to your uid.
#
# Recognised environment (set in the environment or in ./config.mk style):
#   AP_IMAGE       image to run            (default local/ap-pocket:quartus22.1)
#   AP_RUN_AS      root | user             (default user)
#   AP_EXTRA_MOUNT extra "-v src:dst" mounts, colon separated
#   AP_DEVICE      device the doctor sanity-checks (default 5CEBA4F23C8)
#   QUARTUS_ARGS   extra args for quartus_sh --flow compile (used by build.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${AP_IMAGE:-local/ap-pocket:quartus22.1}"
RUN_AS="${AP_RUN_AS:-user}"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found on PATH" >&2
    exit 127
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "error: image $IMAGE not found - run 'make image' first" >&2
    exit 1
fi

# Quartus wants a writable HOME; put it in the mount so it survives restarts.
mkdir -p "$ROOT/.home" "$ROOT/build"
chmod 777 "$ROOT/.home" 2>/dev/null || true

docker_args=(
    --rm
    -v "$ROOT:/work"
    -w /work
    -e HOME=/work/.home
    -e AP_DEVICE="${AP_DEVICE:-5CEBA4F23C8}"
    -e JOBS="${JOBS:-}"
    -e QUARTUS_ARGS="${QUARTUS_ARGS:-}"
    -e ALLOW_TIMING_FAIL="${ALLOW_TIMING_FAIL:-}"
    -e AP_CHOWN="$(id -u):$(id -g)"
    -e AP_HOST_UID="$(id -u)" -e AP_HOST_GID="$(id -g)"
    --shm-size=1g
    --label ap-tool=1
)

if [ "$RUN_AS" != "root" ] && [ "$(id -u)" != "0" ]; then
    docker_args+=(--user "$(id -u):$(id -g)")
fi

# Programming a real Pocket over USB/JTAG needs device access
if [ "${AP_WITH_USB:-0}" = "1" ]; then
    docker_args+=(--privileged)
fi

# interactive only when we have a tty and were asked for a bare shell
if [ $# -eq 0 ] && [ -t 1 ]; then
    docker_args+=(-it)
elif [ -t 1 ]; then
    docker_args+=(-t)
fi

# Knobs the scripts under scripts/ document, forwarded only when set: a container does
# not inherit the caller's environment, so `JOBS=8 ./docker/run.sh scripts/build.sh ...`
# or `TRACE=1 ./docker/run.sh scripts/sim_soc.sh` silently does nothing without this.
for _v in TRACE FRAMES PACE JOBS SIGTAP QUARTUS_ARGS; do
    [ -n "${!_v:-}" ] && docker_args+=(-e "$_v")
done

# extra mounts: AP_EXTRA_MOUNT="/path/a:/path/a:/other:/other"
if [ -n "${AP_EXTRA_MOUNT:-}" ]; then
    IFS=: read -ra extras <<< "$AP_EXTRA_MOUNT"
    for m in "${extras[@]}"; do
        [ -n "$m" ] && docker_args+=(-v "$m")
    done
fi

exec docker run "${docker_args[@]}" "$IMAGE" "$@"
