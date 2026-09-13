#!/usr/bin/env bash
# Scaffold a new Analogue Pocket core from the vendored core-template.
#
#   new_core.sh mygame --author jane --platform nes --title "Nintendo Ent. System" \
#                     --year 1983 --manufacturer Nintendo
#
# Creates cores/<mygame> from the template (or --from <dir>), renames the
# Quartus project, points core.json at a fresh platform id and prints the
# next steps for a MiSTer/other-core port.
#
# Options:
#   --author NAME        core author  (default $AP_AUTHOR or "author")
#   --platform ID        platform id  (default: the core name)
#   --title NAME         platform display name
#   --year YYYY          platform year
#   --manufacturer NAME  platform manufacturer
#   --from DIR           template to copy (default cores/core-template)
#   --force              overwrite an existing cores/<name>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-}"; shift || true
[ -n "$NAME" ] || { sed -n '2,20p' "$0"; exit 1; }

AUTHOR="${AP_AUTHOR:-author}"
PLATFORM=""
TITLE=""
YEAR="2024"
MANUFACTURER="unknown"
FROM="$ROOT/cores/core-template"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --author)        AUTHOR="$2"; shift 2 ;;
        --platform)      PLATFORM="$2"; shift 2 ;;
        --title)         TITLE="$2"; shift 2 ;;
        --year)          YEAR="$2"; shift 2 ;;
        --manufacturer)  MANUFACTURER="$2"; shift 2 ;;
        --from)          FROM="$2"; shift 2 ;;
        --force)         FORCE=1; shift ;;
        -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
        *)               echo "unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$PLATFORM" ] || PLATFORM="$NAME"
[ -n "$TITLE" ] || TITLE="$NAME"

DEST="$ROOT/cores/$NAME"
[ -d "$FROM" ] || { echo "template not found: $FROM (git clone https://github.com/open-fpga/core-template cores/core-template)" >&2; exit 1; }
if [ -e "$DEST" ] && [ "$FORCE" != 1 ]; then
    echo "refusing to overwrite $DEST (use --force)" >&2; exit 1
fi
case "$NAME" in
    *[!A-Za-z0-9_-]*) echo "core name must be [A-Za-z0-9_-]+ (got $NAME)" >&2; exit 1 ;;
esac

echo "creating $DEST from $FROM"
rm -rf "$DEST"
mkdir -p "$DEST"
# copy everything except Quartus scratch/state and stale build output
( cd "$FROM" && tar --exclude=.git --exclude=db --exclude=incremental_db \
                  --exclude=greybox_tmp --exclude='*.rpt' --exclude='*.summary' \
                  --exclude='*.smsg' --exclude='*.cdf' --exclude='*.jdi' \
                  --exclude='output_files/*.rbf' --exclude='output_files/*.sof' \
                  --exclude='output/*.rbf_r' -cf - . ) | ( cd "$DEST" && tar -xf - )

# ---- rename the Quartus project --------------------------------------------
OLD="$(ls "$DEST"/src/fpga/*.qpf 2>/dev/null | head -1)"
if [ -n "$OLD" ]; then
    OLDNAME="$(basename "$OLD" .qpf)"
    mv "$OLD" "$DEST/src/fpga/$NAME.qpf"
    [ -f "$DEST/src/fpga/$OLDNAME.qsf" ] && mv "$DEST/src/fpga/$OLDNAME.qsf" "$DEST/src/fpga/$NAME.qsf"
    sed -i "s/PROJECT_REVISION = \"$OLDNAME\"/PROJECT_REVISION = \"$NAME\"/" "$DEST/src/fpga/$NAME.qpf"
    sed -i "s/^set_global_assignment -name PROJECT_OUTPUT_DIRECTORY.*/set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files/" "$DEST/src/fpga/$NAME.qsf"
    echo "  Quartus project: src/fpga/$NAME.qpf (revision $NAME, top apf_top)"
else
    echo "  warn: no .qpf in the template - not renamed" >&2
fi

# ---- platform id ------------------------------------------------------------
if [ -d "$DEST/dist/platforms" ]; then
    for f in "$DEST"/dist/platforms/*.json; do
        [ -f "$f" ] || continue
        old_pid="$(basename "$f" .json)"
        [ "$old_pid" = "$PLATFORM" ] && continue
        mv "$f" "$DEST/dist/platforms/$PLATFORM.json"
        if [ -f "$DEST/dist/platforms/_images/$old_pid.bin" ]; then
            mv "$DEST/dist/platforms/_images/$old_pid.bin" \
               "$DEST/dist/platforms/_images/$PLATFORM.bin"
        fi
    done
fi

# ---- core.json / info.txt ---------------------------------------------------
python3 - "$DEST" "$AUTHOR" "$NAME" "$PLATFORM" "$YEAR" "$MANUFACTURER" <<'PY'
import json, re, sys
dest, author, name, platform, year, manuf = sys.argv[1:7]
p = dest + "/core.json"
d = json.load(open(p))
core = d["core"]
md = core.setdefault("metadata", {})
md["platform_ids"] = [platform]
md["shortname"] = name
md["author"] = author
md["description"] = "%s - openFPGA core for Analogue Pocket" % name
# a scaffold is not a release: reset the version/date the template shipped with
md["version"] = "0.1.0"
md["date_release"] = "0000-00-00"
core.setdefault("framework", {}).update({"target_product": "Analogue Pocket"})
open(p, "w").write(json.dumps(d, indent=4) + "\n")

pj = "%s/dist/platforms/%s.json" % (dest, platform)
try:
    pd = json.load(open(pj))
    pl = pd.setdefault("platform", {})
    pl["name"] = platform.replace("_", " ").title()
    pl["year"] = int(year) if year.isdigit() else 2024
    pl["manufacturer"] = manuf
    pl.setdefault("category", "Other")
    open(pj, "w").write(json.dumps(pd, indent=4) + "\n")
except (IOError, OSError):
    pass

with open(dest + "/info.txt", "w") as f:
    f.write("%s\n\nopenFPGA core for Analogue Pocket by %s\nBuilt with the ap-tool "
            "environment (Quartus Prime Lite in Docker).\n" % (name, author))
print("  core.json: author=%s shortname=%s platform=%s" % (author, name, platform))
PY

cat <<EOF

Created cores/$NAME

Next steps for a port:
  1. drop the ported RTL in  cores/$NAME/src/fpga/core/        (e.g. rtl/, ip/)
  2. add every source file to cores/$NAME/src/fpga/$NAME.qsf  as
     set_global_assignment -name VERILOG_FILE core/<...>.v   (or VHDL_FILE / QIP_FILE)
  3. implement the Pocket glue in cores/$NAME/src/fpga/core/core_top.v:
     video (pixel clock, hsync/vsync, 8-bit RGB), audio (signed 16-bit stereo +
     sample-strobe), inputs, ROM download via the host/target bus, and the
     OSD/scaler handshake - see the template's core_top.v for the shapes
  4. describe the core for Analogue OS: video.json, input.json, data.json,
     interact.json, variants.json, audio.json
  5. build:   make build CORE=$NAME
     package: make package CORE=$NAME
     (make help lists everything)
EOF
