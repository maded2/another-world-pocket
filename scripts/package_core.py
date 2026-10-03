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
The JSON contract (magic APF_VER_1, unique variant ids in both core.cores[] and
variants.json, every declared bitstream present, every declared platform id
defined) is validated and a release .zip can be produced with --zip.

    package_core.py --core-dir cores/mygame --out build/sd --zip
    package_core.py --core-dir cores/mygame --bitstream build/mygame/bitstream.rbf_r
    package_core.py --core-dir cores/mygame --out build/sd --release   # strict checks

A core that declares more than one entry in core.cores[] needs one artifact per
entry; --bitstream only ever satisfies a single-variant core (or the entry whose
filename matches it). Map the others explicitly:

    package_core.py --core-dir cores/mygame --out build/sd \\
        --variant default=build/mygame/default.rbf_r \\
        --variant hispeed=build/mygame/hispeed.rbf_r

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


def newest_design_source(core_dir):
    """(mtime, path) of the newest file that actually feeds the bitstream.

    Only src/si and src/fpga: a testbench under src/sim is not part of the build, so
    including it would warn on edits that cannot possibly make a bitstream stale, and a
    check that cries wolf gets ignored - which is how a freshness check dies.
    """
    newest = None
    picked = None
    base = Path(core_dir) / "src"
    if not base.is_dir():
        return None, None
    for pat in ("si/*.si", "fpga/**/*.v", "fpga/**/*.sv", "fpga/**/*.qsf", "fpga/**/*.sdc"):
        for p in base.glob(pat):
            try:
                m = p.stat().st_mtime
            except OSError:
                continue
            if newest is None or m > newest:
                newest, picked = m, p
    return newest, picked


def design_resolution(core_dir):
    """The pixel size the design itself generates, read from the Silice source
    ($$H_ACTIVE / $$V_ACTIVE). video.json is a claim about the video pins; nothing else in
    the tree checks that claim, and a core that ships 320x200 while declaring 320x240 gets
    silently rescaled by Analogue OS. Returns [(w, h, source_path), ...]."""
    out = []
    si_dir = Path(core_dir) / "src" / "si"
    if not si_dir.is_dir():
        return out
    for path in sorted(si_dir.glob("*.si")):
        try:
            txt = path.read_text(errors="replace")
        except OSError:
            continue
        hw = re.search(r"^\s*\$\$H_ACTIVE\s*=\s*(\d+)", txt, re.M)
        vh = re.search(r"^\s*\$\$V_ACTIVE\s*=\s*(\d+)", txt, re.M)
        if hw and vh:
            out.append((int(hw.group(1)), int(vh.group(1)), path))
    return out


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


def find_declared(core_dir, fname):
    """Locate a bitstream a core tree already holds for a declared variant."""
    for cand in (core_dir / fname,
                 core_dir / "output" / fname,
                 core_dir / "dist" / fname,
                 core_dir / "src" / "fpga" / "output_files" / fname):
        if cand.is_file():
            return cand
    return None


def package(core_dir, out_dir, core_id=None, bitstream=None,
            make_zip=False, release=False, variant_bits=None):
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

    # optional JSON files, and their magic.  Each file is parsed once: calling
    # load_json twice on a broken file reported the same error two times.
    subs = {}
    for name in CORE_FILES[1:]:
        if not name.endswith(".json"):
            continue
        if not (core_dir / name).is_file():
            if name in ("video.json", "input.json", "data.json", "audio.json"):
                report.warn("{} not present - Analogue OS tolerates it, but most "
                            "cores ship one".format(name))
            continue
        sub = load_json(core_dir / name, report)
        if sub is None:
            continue
        subs[name] = sub
        section = sub.get(name[:-5], {})
        if section.get("magic") != MAGIC:
            report.warn('{}: magic is {!r}, expected "{}"'.format(
                name, section.get("magic"), MAGIC))

    video = subs.get("video.json") or {}
    modes = video.get("video", {}).get("scaler_modes", [])
    for i, m in enumerate(modes):
        if not m.get("width") or not m.get("height"):
            report.error("video scaler_modes[{}] needs width and height".format(i))
        if m.get("rotation") not in (0, 90, 180, 270, None):
            report.warn("video scaler_modes[{}].rotation={} (expected 0/90/180/270)"
                        .format(i, m.get("rotation")))

    # video.json describes the pixels on the wire. If none of the declared modes is the size
    # the design actually generates, Analogue OS rescales something it was not told about.
    for w, h, where in design_resolution(core_dir):
        if modes and not any(m.get("width") == w and m.get("height") == h for m in modes):
            declared = ", ".join("{}x{}".format(m.get("width"), m.get("height"))
                                 for m in modes)
            report.error("video.json declares {} but the design generates {}x{} "
                         "($$H_ACTIVE/$$V_ACTIVE in {})".format(declared, w, h, where))

    # ------------------------------------------------------------------- data
    # A core whose data_slots is empty has nothing for Analogue OS to load: the OSD offers no
    # file picker, nothing is written to the dataslot window, and the core sits waiting for a
    # ROM that will never arrive. Every other symptom of that looks like a hardware bug.
    data = subs.get("data.json") or {}
    slots = data.get("data", {}).get("data_slots")
    if isinstance(slots, list) and not slots:
        msg = ('data.json has data_slots [] - the OSD cannot offer a file, so nothing '
               'is ever loaded into the dataslot window')
        if release:
            report.error(msg)
        else:
            report.warn(msg)
    elif isinstance(slots, list):
        for i, s in enumerate(slots):
            if not isinstance(s, dict):
                report.error("data_slots[{}] must be an object".format(i)); continue
            for key in ("name", "filename", "extensions", "address", "size"):
                if key not in s:
                    report.warn("data_slots[{}]: no '{}' - verify against the Analogue "
                                "data slot spec on hardware".format(i, key))
            exts = s.get("extensions")
            if isinstance(exts, list) and not exts:
                report.error("data_slots[{}]: extensions is empty - no file would match"
                             .format(i))
            for key in ("address", "size"):
                val = s.get(key)
                if isinstance(val, str) and not re.match(r"^[0-9a-fA-F]+$", val):
                    report.error("data_slots[{}].{!r} is {!r}; expected a hex string "
                                 "without 0x".format(i, key, val))

    # variants.json: the list the OSD offers the user. core.cores[] above is the
    # *bitstream* list; these are different lists and both need unique ids.
    if "variants.json" in subs:
        vlist = subs["variants.json"].get("variants", {}).get("variant_list", [])
        if not isinstance(vlist, list):
            report.error("variants.variant_list must be a list")
            vlist = []
        for i, v in enumerate(vlist):
            if not isinstance(v, dict) or v.get("id") is None or not v.get("name"):
                report.error("variants.variant_list[{}] needs both 'id' and 'name'"
                             .format(i))
                continue
        good = [v for v in vlist if isinstance(v, dict)]
        vids = [v.get("id") for v in good]
        if len(set(vids)) != len(vids):
            report.error("variants.json has duplicate variant 'id' values - Analogue "
                         "OS would pick the wrong variant: {}".format(
                             ", ".join(str(i) for i in sorted(set(
                                 x for x in vids if vids.count(x) > 1)))))
        vnames = [v.get("name") for v in good]
        if len(set(vnames)) != len(vnames):
            report.error("variants.json has duplicate variant 'name' values")

    # ---------------------------------------------------------------- bitstream
    # --variant name=path (repeatable) maps a core.cores[] entry to its own
    # build artifact; a bare --bitstream covers the single-variant case.
    supplied = {}
    for spec in (variant_bits or []):
        if "=" not in spec:
            report.error("--variant expects name=path/to/x.rbf[_r], got {!r}"
                         .format(spec))
            continue
        name, path = spec.split("=", 1)
        vpath = Path(path.strip())
        if not vpath.is_file():
            report.error("--variant {}: {} does not exist".format(name.strip(), vpath))
            continue
        supplied[name.strip()] = vpath

    if bitstream is None:
        bitstream = find_bitstream(core_dir, out_dir)
    else:
        bitstream = Path(bitstream)
        if not bitstream.is_file():
            report.error("--bitstream {} does not exist".format(bitstream))
            bitstream = None
    if bitstream is None and not supplied:
        report.error("no bitstream found; build it first (make build) or pass "
                     "--bitstream path/to/x.rbf[_r]")
        return 2

    # Staleness. `make package` does not build, and every other check here validates *what*
    # it copies, never *how old it is* - so packaging after an edit ships the previous
    # bitstream with a clean report. This happened for real: a core packaged at 13:18 was
    # still on the SD-card tree after the 21:29 rebuild that carried the page-arbitration
    # fix, and the only reason it was noticed is that someone compared the two file sizes.
    if bitstream is not None:
        src_mtime, src_path = newest_design_source(core_dir)
        if src_mtime is not None and bitstream.stat().st_mtime < src_mtime:
            report.warn("bitstream {} is older than {} - the packed core may predate the last "
                        "design change; rebuild (make build) before packaging"
                        .format(bitstream, src_path))

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

    # Every filename declared in core.cores[] has to be backed by its own real
    # artifact. Writing the one supplied bitstream under all of them packages a
    # core whose variants all silently boot the same image, so resolve each name
    # individually and fail loudly when one has no source.
    wanted = [v["filename"] for v in variants if v.get("filename")] or ["bitstream.rbf_r"]
    if len(set(wanted)) != len(wanted):
        report.error("core.cores[] declares the same filename more than once")
        wanted = sorted(set(wanted))
    by_filename = {v.get("filename"): v.get("name") for v in variants}

    missing, used, sources = [], {}, {}
    for fname in wanted:
        vname = by_filename.get(fname)
        source = supplied.get(vname) or supplied.get(fname)
        if source is None and len(wanted) == 1 and bitstream is not None:
            source = bitstream
        if source is None and bitstream is not None and bitstream.name == fname:
            source = bitstream
        if source is None:
            source = find_declared(core_dir, fname)
        if source is None:
            missing.append("{}{}".format(fname,
                                         " (variant '{}')".format(vname) if vname else ""))
            continue
        target = dest / fname
        if source.name.endswith("_r"):
            shutil.copy2(str(source), str(target))
            how = "copied"
        else:
            write_reversed(source, target)
            how = "reversed from"
        real = source.resolve() if hasattr(source, "resolve") else source
        used.setdefault(real, []).append(fname)
        sources[fname] = source
        report.ok("{}/{} {} {} ({:,} bytes)".format(
            cid, fname, how, source, target.stat().st_size))

    if missing:
        report.error("no bitstream for declared variant(s): {}. Build each one and "
                     "pass --variant <name>=<path.rbf[_r]> (or --bitstream when the "
                     "core has a single variant); refusing to reuse one image for "
                     "several variants.".format(", ".join(missing)))
    reused = [names for names in used.values() if len(names) > 1]
    for names in reused:
        report.warn("{} share one bitstream file - intended?".format(
            " and ".join(sorted(names))))

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
        # Zip what *this* core owns, not whatever is in the output folder. The out dir is a
        # merged SD tree and is allowed to hold other cores; walking it shipped another
        # core's bitstream and another platform's JSON inside this core's release zip.
        own = [dest]                                        # Cores/<cid>
        own += [out_dir / "Platforms" / "{}.json".format(p) for p in platform_ids]
        own += [out_dir / "Platforms" / "_images" / "{}.bin".format(p) for p in platform_ids]
        own += [out_dir / "Assets" / p for p in platform_ids]
        written = 0
        with zipfile.ZipFile(str(zpath), "w", zipfile.ZIP_DEFLATED) as z:
            for base in own:
                if base.is_file():
                    z.write(str(base), str(base.relative_to(out_dir)))
                    written += 1
                elif base.is_dir():
                    for p in sorted(base.rglob("*")):
                        if p.is_file():
                            z.write(str(p), str(p.relative_to(out_dir)))
                            written += 1
                        elif p.is_dir() and not any(p.iterdir()):
                            zi = zipfile.ZipInfo(str(p.relative_to(out_dir)) + "/")
                            zi.external_attr = 0o40755 << 16
                            z.writestr(zi, b"")
                else:
                    report.warn("zip: expected {} and it is not there".format(base))
        if written == 0:
            report.error("zip would be empty - nothing was packaged")
        report.ok("zip: {} ({:,} bytes, {} file(s), this core only)".format(
            zpath, zpath.stat().st_size, written))

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
    p.add_argument("--variant", dest="variant_bits", action="append",
                   metavar="NAME=PATH",
                   help="bitstream for one core.cores[] entry, by variant name or by "
                        "filename; repeat, once per declared variant")
    p.add_argument("--zip", action="store_true", help="also write <id>-<version>.zip")
    p.add_argument("--release", action="store_true",
                   help="strict metadata checks for a public release")
    opts = p.parse_args(argv)
    return package(opts.core_dir, opts.out, opts.core_id, opts.bitstream,
                   opts.zip, opts.release, opts.variant_bits)


if __name__ == "__main__":
    sys.exit(main())
