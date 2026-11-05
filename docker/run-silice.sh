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
# EXTRA carries bench plusargs through scripts/sim_soc.sh (e.g. EXTRA=+FUZZ_BRAM=1);
# it is on this list because the list is an allow-list and an unlisted variable is dropped
# in silence - the failure mode documented just above.
# STALL forces aw_rom's restart path (scripts/ab_stall_repro.sh) and FRAMEDIR chooses where the
# pictures go; both were absent from this allow-list, so asking for them did nothing at all --
# the exact silence this comment block warns about, rediscovered while trying to reproduce a
# hardware-only freeze.
# PACK_KIND tells tb_soc what the pack is supposed to render (part0 is black by design); it went
# on this list the same afternoon it was invented, for the same reason as the two above.
# IMG is the combined (paged) image for scripts/sim_soc.sh. It was missing from this list, so
# `IMG=... scripts/sim_soc.sh` came back as a perfectly ordinary plain-pack run with no hint that the
# request had been dropped - and the log looked like a paged run that passed, which is the dangerous
# version: the first paged tb_soc result would have been a plain run wearing a paged label.
# PART is shared: scripts/ref_sim.sh has used it for years as the reference-run part index, and
# scripts/sim_soc.sh now reads it as "which part to select before the VM's first byte". Both are
# integer part indices; if they ever mean different things, one of them gets renamed.
# LATESEL_TEST opts tb_dir's run 7 in or out of the default sequence, and run 7 is the evidence for
# task #28, so a dropped LATESEL_TEST silently turns "the late-select case was checked and passed"
# into "the case was not run" while the suite still prints its usual PASS. Same failure shape as IMG
# above, which is why it is on this list on the same day it was needed.
for _v in TRACE READTRACE FRAMES PACE JOBS SIGTAP QUARTUS_ARGS PART SECS SHOTS REF_DIR REF_OUT PERIPHERALS EXTRA WORK STALL FRAMEDIR PACK_KIND IMG LATESEL_TEST RUNS SWITCH SWITCHAFTER; do
    [ -n "${!_v:-}" ] && docker_args+=(-e "$_v")
done

if [ -n "${AP_EXTRA_MOUNT:-}" ]; then
    IFS=: read -ra extras <<< "$AP_EXTRA_MOUNT"
    for m in "${extras[@]}"; do
        [ -n "$m" ] && docker_args+=(-v "$m")
    done
fi

exec docker run "${docker_args[@]}" "$IMAGE" "$@"
