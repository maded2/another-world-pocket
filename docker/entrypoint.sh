#!/bin/sh
# Entry point for the derived Pocket build image.
#
#   1. make sure $HOME is writable by the current uid (Quartus refuses to run
#      otherwise),
#   2. keep the base image's quartus-entrypoint behaviour (optional
#      `gh auth setup-git` with GITHUB_TOKEN, optional `jtagconfig
#      --addserver` with JTAG_SERVER/JTAG_PASSWD),
#   3. run the requested command,
#   4. when running as root with AP_CHOWN="uid:gid", hand the generated files
#      back to the host user.

uid="$(id -u)"
name="$(id -un 2>/dev/null | head -1)"
[ -n "$name" ] || name="uid-$uid"

# HOME may point into the bind mount (.home).  If it is not writable, fall
# back to a private dir under /tmp (mode 1777).
if [ ! -d "${HOME:-}" ] || [ ! -w "${HOME:-/nonexistent}" ]; then
    mkdir -p "/tmp/ap-home-$name" 2>/dev/null || true
    HOME="/tmp/ap-home-$name"
    export HOME
fi
mkdir -p "$HOME/.altera" "$HOME/.intelpython" 2>/dev/null || true

# Let an edited ./scripts/ in the mount win over the copy baked into the image.
if [ -d /work/scripts ]; then
    PATH="/work/scripts:$PATH"
    export PATH
fi

qfile="${QUARTUS_ROOTDIR:-/nonexistent}/version.txt"
qver="$(sed -n 's/^Version=//p' "$qfile" 2>/dev/null | head -1)"
qedn="$(sed -n 's/^Edition=//p' "$qfile" 2>/dev/null | head -1)"
echo "ap-pocket build env | user=$name uid=$uid HOME=$HOME \
quartus=${qver:-?}${qedn:+ ${qedn} edition}"

if command -v quartus-entrypoint >/dev/null 2>&1; then
    quartus-entrypoint "$@"
else
    "$@"
fi
rc=$?

# Root-mode builds (AP_RUN_AS=root, e.g. for JTAG) leave root-owned files
# behind; give them back to the host user when we know who that is.
if [ "$uid" = "0" ] && [ -n "${AP_CHOWN:-}" ]; then
    chown -R "$AP_CHOWN" "$HOME" /work/build 2>/dev/null || true
fi

exit "$rc"
