#!/usr/bin/env bash
# Build the PUBLIC release archive: the core and its platform, and NOTHING derived from the game.
#
#   scripts/package_release.sh [-v 1.0.0] [--zip-only] [--publish]
#
# What goes in:  Cores/<author>.<core>/   (bitstream + the core's JSON files + Chip32 loader)
#                Platforms/                (the platform definition and its image)
#                README.md, LICENSE
# What stays out: Assets/  - the dataslot image and the per-part packs are derived from the
#                 commercial release; the README tells the user to supply their own PC copy and
#                 run `make rom`. This script refuses to publish anything that would put game
#                 data in the archive (it checks the file list, not just the copy step).
#
# --publish uploads the archive as a GitHub release. It needs a token in GH_TOKEN (a fine-grained
# token with "Contents: read and write" on this repository). Without it the script stops after
# building the archive and printing the exact command to run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE=aw
VERSION="$(cd "$ROOT" && python3 -c "import json;print(json.load(open('cores/aw/core.json'))['core']['metadata']['version'])")"
ZIP_ONLY=0
PUBLISH=0
REPO="maded2/another-world-pocket"

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) shift; VERSION="${1:?--version needs a value}" ;;
        --zip-only)   ZIP_ONLY=1 ;;
        --publish)    PUBLISH=1 ;;
        -h|--help)    sed -n '1,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

SD="$ROOT/build/sd/$CORE"
REL="$ROOT/build/release"
ZIP="$REL/another-world-pocket-v$VERSION.zip"
NAME="$(python3 -c "import json;print(json.load(open('$ROOT/cores/aw/core.json'))['core']['metadata']['shortname'])")"

echo "== package the core (bitstream + metadata; Assets stay local) =="
(cd "$ROOT" && make package CORE=$CORE RELEASE_VERSION="$VERSION" >/dev/null)

[ -d "$SD/Cores" ] || { echo "error: no packaged core at $SD/Cores" >&2; exit 1; }
CORE_DIR=$(ls -d "$SD"/Cores/*/ | head -1)
[ -f "$CORE_DIR/bitstream.rbf_r" ] || { echo "error: no bitstream in $CORE_DIR" >&2; exit 1; }

rm -rf "$REL"; mkdir -p "$REL/stage"
cp -r "$SD/Cores" "$REL/stage/"
cp -r "$SD/Platforms" "$REL/stage/"
cp -f "$ROOT/README.md" "$ROOT/LICENSE" "$REL/stage/"

# ---- the rule this script exists to enforce ------------------------------------------------
# A release archive is public. Anything derived from the game - the dataslot image, the packs -
# must never be in it, and a copy step that "happens to be right today" is not a guarantee.
BAD=$(cd "$REL/stage" && find . -type f \( -name '*.bin' -path '*Assets*' -o -name 'part[0-9].bin' \
        -o -name 'aw-all*.bin' -o -name 'aw-audio*' \) -print)
if [ -n "$BAD" ]; then
    echo "REFUSING: the archive would contain game-derived data:" >&2
    echo "$BAD" | sed 's/^/  /' >&2
    exit 1
fi
if [ -d "$REL/stage/Assets" ]; then
    echo "REFUSING: Assets/ is in the archive - that is where the game data lives" >&2
    exit 1
fi

# Deterministic archive: every entry gets the BITSTREAM's timestamp and a fixed file order, and
# zip is told to store no extra attributes (zip -X). Without this the archive's sha256 changes on
# every run - the copy step refreshes mtimes - and a checksum in the release notes would be a lie
# the first time someone rebuilt it to verify.
STAMP=$(stat -c %Y "$CORE_DIR/bitstream.rbf_r")
find "$REL/stage" -exec touch -h -d "@$STAMP" {} +
(cd "$REL/stage" && find . -type f | LC_ALL=C sort | zip -X -q "$ZIP" -@)
SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
SIZE=$(stat -c%s "$ZIP")

echo
echo "== what is in it =="
(cd "$REL/stage" && find . -type f | sed 's|^\./|  |' | sort)
echo
echo "archive : $ZIP"
echo "          $SIZE bytes, sha256 $SHA"
echo "core    : $NAME $VERSION"
echo "bitstream: $(sha256sum "$CORE_DIR/bitstream.rbf_r" | cut -c1-16)... (banner: $(grep -o 'AW [0-9]*a up' "$CORE_DIR/info.txt" 2>/dev/null || echo 'see console'))"
echo
echo "The user supplies the game data: README -> 'Build' -> make rom, then copy the archive's"
echo "Cores/ and Platforms/ to the card and put build/aw-all-audio.bin in"
echo "Assets/anotherworld/common/."

if [ "$ZIP_ONLY" -eq 1 ] || [ "$PUBLISH" -eq 0 ]; then
    cat <<EOF

To publish this as a GitHub release (needs GH_TOKEN with Contents: write):

  GH_TOKEN=... scripts/package_release.sh --publish

or by hand:

  git tag -a v$VERSION -m "Another World Pocket v$VERSION"
  git push origin v$VERSION
  curl -X POST -H "Authorization: Bearer \$GH_TOKEN" \\
       -H "Accept: application/vnd.github+json" \\
       https://api.github.com/repos/$REPO/releases \\
       -d '{"tag_name":"v$VERSION","name":"v$VERSION","body":"...","draft":false}'
EOF
    exit 0
fi

# ---- publish ------------------------------------------------------------------------------
: "${GH_TOKEN:?GH_TOKEN is required with --publish (fine-grained token, Contents: read and write)}"
TAG="v$VERSION"

if ! git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    git -C "$ROOT" tag -a "$TAG" -m "Another World Pocket $TAG"
fi
git -C "$ROOT" push origin "$TAG"

NOTES="$ROOT/docs/release-notes-$TAG.md"
[ -f "$NOTES" ] || { echo "error: no release notes at $NOTES" >&2; exit 1; }

echo "== creating the GitHub release $TAG =="
python3 - "$NOTES" "$TAG" "$ZIP" "$REPO" <<'PY'
import json, os, sys, urllib.request

notes_path, tag, zip_path, repo = sys.argv[1:5]
token = os.environ["GH_TOKEN"]
body = open(notes_path).read()
req = urllib.request.Request(
    "https://api.github.com/repos/%s/releases" % repo,
    data=json.dumps({"tag_name": tag, "name": tag, "body": body,
                     "draft": False, "prerelease": False}).encode(),
    headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
             "Content-Type": "application/json"})
rel = json.load(urllib.request.urlopen(req))
print("release:", rel["html_url"])

name = os.path.basename(zip_path)
data = open(zip_path, "rb").read()
upload = urllib.request.Request(
    rel["upload_url"].split("{")[0] + "?name=" + name,
    data=data,
    headers={"Authorization": "Bearer " + token,
             "Content-Type": "application/zip", "Content-Length": str(len(data))})
asset = json.load(urllib.request.urlopen(upload))
print("asset  :", asset["browser_download_url"], "(%d bytes)" % asset["size"])
PY
