#!/usr/bin/env python3
"""Assemble an Analogue Pocket core release (the microSD folder layout).

Input:  a core working tree in the open-fpga/core-template shape - core
        definition JSON files at the root, ``dist/platforms/<id>.json`` +
        ``dist/platforms/_images/<id>.bin`` for the platform metadata,
        optionally ``dist/assets/``.
Output: the tree the Pocket expects at the root of its SD card:

    <out>/Cores/<Author>.<Core>/core.json, video.json, ... , bitstream.rbf_r
    <out>/Platforms/<platform>.json
    <out>/Platforms/_images/<platform>.bin
    <out>/Assets/<platform>/common/

A ``.rbf`` passed with --bitstream is reversed for you; a ``.rbf_r`` is copied.
The JSON contract (magic APF_VER_1, declared bitstreams, declared platform ids)
is validated and a release .zip can be produced with --zip.

    package_core.py --core-dir cores/mygame --out build/sd --zip
    package_core.py --core-dir cores/mygame --bitstream build/mygame/bitstream.rbf_r
    package_core.py --core-dir cores/mygame --out build/sd --release   # strict checks

Written for Python 3.5+ (the Quartus container ships Debian 9's Python 3.5).
"""

import argparse
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path

MAGIC = "APF_VER_1"
CORE_FILES = [
    "core.json", "audio.json", "data.json", "input.json",
    "interact.json", "variants.json", "video.json", "info.txt",
]
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ID_RE = re.compile(r"^[A-Za-z0-9_]+\.[A-Za-z0-9_\-]+$")
REVERSE_TABLE = bytes(int("{:08b}".format(i)[::-1], 2) for i in range(256))


class Report(object):
    def __init__(self):
        self.warnings = []
        self.errors = []

    def warn(self, msg):
        self.warnings.append(msg)
        print("  warn:  {}".format(msg))

    def error(self, msg):
        self.errors.append(msg)
        print("  ERROR: {}".format(msg))

    def ok(self, msg):
        print("  ok:    {}".format(msg))


def load_json(path, report, required=False):
    if not path.is_file():
        if required:
            report.error("{} is missing".format(path))
        return None
    try:
        return json.loads(path.read_text())
    except ValueError as exc:                     # JSONDecodeError on 3.5
        report.error("{}: invalid JSON ({})".format(path.name, exc))
        return None


def derive_core_id(core_dir, core_cfg, report):
    """Pocket core folders are Author.CoreName with the spaces squeezed out."""
    md = core_cfg.get("core", {}).get("metadata", {})
    author = re.sub(r"\s+", "", md.get("author") or "Author")
    short = re.sub(r"\s+", "", md.get("shortname") or core_dir.name)
    candidate = "{}.{}".format(author, short)
    if not ID_RE.match(candidate):
        report.warn("derived core id '{}' looks unusual; pass --id Author.CoreName "
                    "to override".format(candidate))
    return candidate


def find_bitstream(core_dir, out_dir):
    """Best-effort discovery of a freshly built bitstream."""
    candidates = [
        out_dir.parent / "bitstream.rbf_r",
    ]
    candidates += sorted((core_dir / "output").glob("*.rbf_r"))
    candidates += sorted((core_dir / "output").glob("*.rbf"))
    of = core_dir / "src" / "fpga" / "output_files"
    candidates += sorted(of.glob("*.rbf_r"))
    candidates += sorted(of.glob("*.rbf"))
    for c in candidates:
        if c.is_file():
            return c
    return None


SKIP_NAMES = {".keep", ".gitkeep", ".DS_Store"}


def merge_tree(src, dst):
    """copytree with merge semantics (dirs_exist_ok is Python 3.8+)."""
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        if item.name in SKIP_NAMES:
            continue
        target = dst / item.name
        if item.is_dir():
            merge_tree(item, target)
        else:
            shutil.copy2(str(item), str(target))


def write_reversed(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(src.read_bytes().translate(REVERSE_TABLE))


def package(core_dir, out_dir, core_id=None, bitstream=None,
            make_zip=False, release=False):
    report = Report()
    core_dir = Path(core_dir)
    out_dir = Path(out_dir)
    print(":: packaging {}".format(core_dir))

    core_json = core_dir / "core.json"
    cfg = load_json(core_json, report, required=True)
    if cfg is None:
        return 2

    core = cfg.get("core", {})
    if core.get("magic") != MAGIC:
        report.error('core.magic must be "{}", got {!r}'.format(MAGIC, core.get("magic")))

    md = core.get("metadata", {})
    for key in ("shortname", "author", "version", "platform_ids"):
        if not md.get(key):
            report.error("core.metadata.{} is required by Analogue OS".format(key))
    if release:
        if not md.get("url"):
            report.warn("release build: core.metadata.url is empty")
        dr = md.get("date_release") or ""
        if not DATE_RE.match(dr):
            report.warn("release build: date_release should be YYYY-MM-DD, got {!r}"
                        .format(dr))
        elif set(dr.replace("-", "")) == {"0"}:
            report.warn("release build: date_release is still the placeholder {} - "
                        "set it to the actual date".format(dr))
        if md.get("version", "").startswith("0."):
            report.warn("release build: version {} looks like a work in progress"
                        .format(md.get("version")))

    variants = core.get("cores", [])
    if not variants:
        report.error("core.cores[] is empty - no bitstream variants declared")
    for v in variants:
        for key in ("name", "id", "filename"):
            if key not in v:
                report.error("core.cores[{}] missing '{}'".format(v.get("name", "?"), key))
    if len(set(v.get("id") for v in variants)) != len(variants):
        report.error("core.cores[] has duplicate 'id' values - each variant needs a "
                     "unique id")
    if len(set(v.get("name") for v in variants)) != len(variants):
        report.error("core.cores[] has duplicate 'name' values")

    # optional JSON files, and their magic
    for name in CORE_FILES[1:]:
        if not name.endswith(".json"):
            continue
        sub = load_json(core_dir / name, report)
        if sub is None:
            if name in ("video.json", "input.json", "data.json", "audio.json"):
                report.warn("{} not present - Analogue OS tolerates it, but most "
                            "cores ship one".format(name))
            continue
        section = sub.get(name[:-5], {})
        if section.get("magic") != MAGIC:
            report.warn('{}: magic is {!r}, expected "{}"'.format(
                name, section.get("magic"), MAGIC))

    video = load_json(core_dir / "video.json", report) or {}
    modes = video.get("video", {}).get("scaler_modes", [])
    for i, m in enumerate(modes):
        if not m.get("width") or not m.get("height"):
            report.error("video scaler_modes[{}] needs width and height".format(i))
        if m.get("rotation") not in (0, 90, 180, 270, None):
            report.warn("video scaler_modes[{}].rotation={} (expected 0/90/180/270)"
                        .format(i, m.get("rotation")))

    # ---------------------------------------------------------------- bitstream
    if bitstream is None:
        bitstream = find_bitstream(core_dir, out_dir)
    else:
        bitstream = Path(bitstream)
        if not bitstream.is_file():
            report.error("--bitstream {} does not exist".format(bitstream))
            bitstream = None
    if bitstream is None:
        report.error("no bitstream found; build it first (make build) or pass "
                     "--bitstream path/to/x.rbf[_r]")
        return 2

    cid = core_id or derive_core_id(core_dir, cfg, report)
    dest = out_dir / "Cores" / cid
    if dest.exists():
        shutil.rmtree(str(dest))
    dest.mkdir(parents=True)

    copied = 0
    for name in CORE_FILES:
        src = core_dir / name
        if src.is_file():
            shutil.copy2(str(src), str(dest / name))
            copied += 1
    report.ok("{}/ <- {} definition file(s)".format(cid, copied))

    wanted = [v["filename"] for v in variants if v.get("filename")] or ["bitstream.rbf_r"]
    for fname in wanted:
        target = dest / fname
        if bitstream.name.endswith("_r"):
            shutil.copy2(str(bitstream), str(target))
            how = "copied"
        else:
            write_reversed(bitstream, target)
            how = "reversed from"
        report.ok("{}/{} {} {} ({:,} bytes)".format(
            cid, fname, how, bitstream, target.stat().st_size))

    # --------------------------------------------------------------- platforms
    platform_ids = md.get("platform_ids") or []
    plat_src = core_dir / "dist" / "platforms"
    for pid in platform_ids:
        pj = plat_src / "{}.json".format(pid)
        img = plat_src / "_images" / "{}.bin".format(pid)
        if pj.is_file():
            (out_dir / "Platforms").mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(pj), str(out_dir / "Platforms" / "{}.json".format(pid)))
            report.ok("Platforms/{}.json".format(pid))
        else:
            report.error("platform definition missing: {} (id declared in "
                         "core.metadata.platform_ids)".format(pj))
        if img.is_file():
            (out_dir / "Platforms" / "_images").mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(img), str(out_dir / "Platforms" / "_images" /
                                       "{}.bin".format(pid)))
            report.ok("Platforms/_images/{}.bin".format(pid))
        else:
            report.warn("platform image missing: {} (box art, optional)".format(img))
        # the folder Analogue OS browses for ROMs of this platform
        (out_dir / "Assets" / pid / "common").mkdir(parents=True, exist_ok=True)

    extra_assets = core_dir / "dist" / "assets"
    if extra_assets.is_dir() and any(extra_assets.iterdir()):
        merge_tree(extra_assets, out_dir / "Assets")
        report.ok("Assets/ <- {}".format(extra_assets))

    version = md.get("version") or "0.0.0"
    if make_zip:
        out_dir.mkdir(parents=True, exist_ok=True)
        zpath = out_dir / "{}-{}.zip".format(cid, version)
        if zpath.exists():
            zpath.unlink()
        with zipfile.ZipFile(str(zpath), "w", zipfile.ZIP_DEFLATED) as z:
            for folder in ("Cores", "Platforms", "Assets"):
                base = out_dir / folder
                if not base.is_dir():
                    continue
                for p in sorted(base.rglob("*")):
                    if p.is_file():
                        z.write(str(p), str(p.relative_to(out_dir)))
                    elif p.is_dir() and not any(p.iterdir()):
                        zi = zipfile.ZipInfo(str(p.relative_to(out_dir)) + "/")
                        zi.external_attr = 0o40755 << 16
                        z.writestr(zi, b"")
        report.ok("zip: {} ({:,} bytes)".format(zpath, zpath.stat().st_size))

    print(":: {} - {} error(s), {} warning(s)".format(
        "FAILED" if report.errors else "OK", len(report.errors), len(report.warnings)))
    if not report.errors:
        print(":: copy {}/Cores, {}/Platforms and {}/Assets to the root of the "
              "Pocket SD card (merge, do not replace)".format(out_dir, out_dir, out_dir))
    return 1 if report.errors else 0


def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--core-dir", required=True, type=Path,
                   help="core working tree (JSON files at its root)")
    p.add_argument("--out", required=True, type=Path, help="SD-root output folder")
    p.add_argument("--id", dest="core_id",
                   help="override the Author.CoreName folder name")
    p.add_argument("--bitstream", type=Path,
                   help=".rbf (reversed automatically) or an already reversed .rbf_r")
    p.add_argument("--zip", action="store_true", help="also write <id>-<version>.zip")
    p.add_argument("--release", action="store_true",
                   help="strict metadata checks for a public release")
    opts = p.parse_args(argv)
    return package(opts.core_dir, opts.out, opts.core_id, opts.bitstream,
                   opts.zip, opts.release)


if __name__ == "__main__":
    sys.exit(main())
