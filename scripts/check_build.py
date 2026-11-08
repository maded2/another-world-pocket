#!/usr/bin/env python3
"""Audit a Quartus build report for the failures that compile green and do nothing.

    scripts/check_build.py --core-dir cores/aw
    make check-build CORE=aw

Why this exists: the first complete build of the aw core synthesized, placed,
routed and met timing with zero errors - and could not have run, because one
signal driving the ROM read stream had no driver at all. Quartus said so, quietly,
two hundred warnings deep:

    Warning (18550): Found RAM instances implemented as ROM because the write
                     logic is always disabled
    ... aw_rom:u_rom|aw_fifo:u_rqfifo|altsyncram:mem_rtl_0 ...
    ; aw_rom:u_rom|p_want_s[0..2]  ; Stuck at GND due to stuck port data_in ;

A register that can never change, a RAM whose write port can never fire, a
constant clock: all of these are legal Verilog, all of them pass every tool in the
flow, and none of them can possibly work. This script reads what the tools already
reported and answers one question - is there anything in the core's own modules
that the compiler proved dead?

Also reports, because they are the other two things worth knowing after a build:
the clock frequencies the PLL actually produced, and whether timing closed.

Exit status: 0 clean | 1 findings to look at | 2 reports not found
"""

import argparse
import os
import re
import sys

# Nodes the compiler is right to fold away, and which would otherwise be noise on
# every run. audgen_* is the template's silent-I2S filler; psram_cre is the ZBT
# "clock rate" option we tie low; wr_addr[20:21] is die/top-of-space select above
# the two megabytes a pack occupies.
DEFAULT_ALLOW = [
    r'audgen',
    # The I2S sample FIFO holds a 16-bit word whose low byte is the known-zero half of an 8-bit sample
    # scaled by 256 ({{8{sign}}, sample} << 8). Quartus reports rd_q[0] as "stuck at GND due to stuck port
    # data_in" - true, and harmless: the byte that carries the sound varies. Left as a scope allowance
    # rather than restructured, because moving the shift to the read side would only move the constant to
    # a register and hide the fact that the low byte is zero by construction.
    r'u_samp\|rd_q\[', 
    # The VM's chapter request is a 16-bit resource id, but only 0x3E80..0x3E89 is a part: pr_* carries the
    # whole id and the range check IS the contract, so bits 4,5,6,8,14,15 can never be set. Quartus only sees
    # that now that pr_done has one driver (it had two, which a Verilator warning hid and Quartus refused).
    r'u_rom\|pr_(s0|s1|stable|done)\[', 
    # Byte addresses in this design are 22 bits wide (one 4 MiB die, which is also the loader's window), so
    # the top bits of an address register are zero by construction: hb_fb/hb_pb are header u32s narrowed to
    # 24 bits and audio_base_r is their sum. Quartus proves bit 23 constant and reports it as lost fanout.
    r'(hb_fb|hb_pb|audio_base_r)\[2[23]\]', 
    r'aud_mclk',
    r'psram_cre',
    r'wr_addr\[2[01]',   # Quartus compacts bits: [20], [21] or [20,21]
    # --- aw_rom / aw_psram: constant by contract, not by mistake -----------------
    # The pack window is one 2 MB die, so the second die's select never fires. If this
    # ever stops being stuck, something has started addressing a second chip.
    r'start_addr_r\[20\]',
    r'aw_psram.*\bbe\[0\]',   # the bridge writes whole 32-bit words: both lanes always on
    r'u_ldfifo\|rd_q\[32\]',  # bit 0 of the bridge address: 32-bit writes are always aligned
    # The loader's byte-straddling path, for a bridge that hands over unaligned or
    # narrower writes than this APF revision does. It is kept because it documents the
    # contract and costs 20-odd ALMs; it is constant because the bridge is 32-bit aligned.
    r'\bd_odd\b',
    r'\bd_step\b',
    r'cram1',
    r'dram_',
    r'sram_',
    r'cart_tran',
    r'port_tran',
]

# What counts as "the core's own logic": this core's modules, and signals that
# belong to core_top itself. Deliberately not the APF template's modules
# (core_bridge_cmd and friends are full of dead states for commands this core never
# accepts) and not the translated Silice design, whose unused corners belong to
# upstream. Widen it with --scope when you want to look at those.
DEFAULT_SCOPE = r'(aw_rom|aw_psram|aw_fifo|aw_pll)|core_top:ic\|[^|]+$'

# Node names with a '~' are synthesized artifacts of an optimization (c_state~5 is a
# LUT, not the register), and "lost fanout" on one of those means a folded decode
# term, which is normal. --artifacts reports them anyway.
ARTIFACT_RE = re.compile(r'~\d+')


def read(path):
    with open(path, 'r', errors='replace') as fh:
        return fh.read().replace('\r\n', '\n')


def find_reports(core_dir):
    out = os.path.join(core_dir, 'src', 'fpga', 'output_files')
    found = {}
    for kind in ('map', 'fit', 'asm', 'sta'):
        cand = [f for f in sorted(os.listdir(out)) if f.endswith('.%s.rpt' % kind)] \
            if os.path.isdir(out) else []
        if cand:
            found[kind] = os.path.join(out, cand[0])
    return found


def check_stuck(texts, scope_re, allow_res, artifacts=False):
    """Nodes the tools proved constant, or whose fanout disappeared.

    Deduplicated: the map report lists the same node in more than one table, and the
    'why' string is padded to the column width, so the raw matches repeat."""
    findings, seen = [], set()
    for kind, text in texts.items():
        for m in re.finditer(r'^\s*;\s*([^;]+?)\s*;\s*(Stuck at (?:GND|VCC)[^;]*'
                             r'|Lost fanout)\s*;', text, re.M):
            node, why = m.group(1).strip(), m.group(2).strip()
            if not scope_re.search(node):
                continue
            if not artifacts and ARTIFACT_RE.search(node):
                continue
            if any(a.search(node) for a in allow_res):
                continue
            key = (node.split(' - ')[0], why)
            if key in seen:
                continue
            seen.add(key)
            findings.append((kind, node, why))
    return findings


def check_ram_as_rom(texts, allow_res):
    findings = []
    for kind, text in texts.items():
        for m in re.finditer(r'Atom "([^"]+)" is instantiated as RAM, but it is '
                             r'actually implemented as ROM function', text):
            atom = m.group(1)
            if any(a.search(atom) for a in allow_res):
                continue
            findings.append((kind, atom))
    return findings


def check_pll(texts, expect):
    """What the PLL actually makes, per output counter."""
    clocks, out = [], []
    text = texts.get('fit') or texts.get('map') or ''
    for m in re.finditer(r'-- (\S*gpll~PLL_OUTPUT_COUNTER)\s*\n\s*-- Output Clock '
                         r'Frequency\s+(\S+)', text):
        name, freq = m.group(1), m.group(2)
        clocks.append((name, freq))
    if not clocks:  # older/other report shape
        for m in re.finditer(r'Output Clock Frequency\s*;\s*([0-9.]+) MHz', text):
            clocks.append(('(unnamed output counter)', m.group(1) + ' MHz'))
    if expect:
        want = [f.strip() for f in expect.split(',') if f.strip()]
        got = [f for _, f in clocks]
        for w in want:
            if not any(g.startswith(w) for g in got):
                out.append('PLL: requested %s MHz, got %s' % (w, ', '.join(got) or 'nothing reported'))
    return clocks, out


def check_sdc(build_dir):
    """Constraints the compiler accepted the file with and then silently dropped.

    Quartus reports an SDC constraint that matched nothing - an empty collection from a
    typo, a rename, a get_pins where get_registers was meant, a hierarchy path rooted at
    the wrong entity - as a Warning (332049) and carries on as if nothing happened. The
    build still says "successful", every report still says the timing is clean, and the
    interface the constraint existed to protect is unconstrained. That is not hypothetical
    here: the cram0 set_max_delay bounds were dropped in every build until the report was
    read line by line, because the collection named pins of an instance under a hierarchy
    root that does not exist (the netlist's top is apf_top).

    A rejected SDC is worse and says so differently (332008: Read_sdc failed - clock
    groups and all, so an unrelated-but-false clean report), so both are caught."""
    log = os.path.join(build_dir, 'compile.log')
    if not os.path.isfile(log):
        return ['no %s - cannot tell whether the SDC constraints actually loaded' % log]
    dropped, rejected = [], []
    for line in read(log).split('\n'):
        if 'Warning (332049)' in line:
            dropped.append(line.strip())
        elif 'Read_sdc failed' in line or '(332008)' in line:
            rejected.append(line.strip())
    msgs = []
    if rejected:
        msgs.append('sdc: the constraints file was REJECTED (%d message(s), e.g. %s) - '
                    'nothing in it, including the clock groups, is in effect'
                    % (len(rejected), rejected[0][:120]))
    for d in sorted(set(re.sub(r'\s+', ' ', x) for x in dropped)):
        msgs.append('sdc: a constraint was dropped - %s' % d[:200])
    return msgs


def check_timing(build_dir):
    rep = os.path.join(build_dir, 'report.txt')
    if not os.path.isfile(rep):
        return None, ['no %s - run the build first' % rep]
    text = read(rep)
    slacks = re.findall(r"Slack : (-?[0-9.]+)", text)
    if not slacks:
        return None, ['%s has no timing summary' % rep]
    worst = min(float(s) for s in slacks)
    msgs = []
    if worst < 0:
        msgs.append('timing: worst slack is %.3f ns (negative)' % worst)
    return worst, msgs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--core-dir', required=True)
    ap.add_argument('--build', help='build output dir (default <repo>/build/<core>)')
    ap.add_argument('--expect-clock', default='',
                    help='comma list of PLL frequencies that must appear, e.g. 24.75,49.5')
    ap.add_argument('--scope', default=DEFAULT_SCOPE,
                    help='regex: which nodes are "yours" (default: the core\'s own modules)')
    ap.add_argument('--allow', action='append', default=[],
                    help='regex: nodes to ignore; repeatable. Replaces nothing, adds to the defaults')
    ap.add_argument('--artifacts', action='store_true',
                    help='also report synthesized artifact nodes (names with ~n)')
    args = ap.parse_args()

    reports = find_reports(args.core_dir)
    if not reports:
        print('check_build: no Quartus reports under %s/src/fpga/output_files - build it first'
              % args.core_dir, file=sys.stderr)
        return 2

    core = os.path.basename(args.core_dir.rstrip('/'))
    build_dir = args.build or os.path.join(os.path.dirname(os.path.abspath(args.core_dir.rstrip('/'))),
                                           '..', 'build', core)
    build_dir = os.path.normpath(build_dir)

    texts = {k: read(v) for k, v in reports.items()}
    scope_re = re.compile(args.scope)
    allow_res = [re.compile(p) for p in DEFAULT_ALLOW + args.allow]

    problems = []

    print('== %s: reports %s ==' % (core, ', '.join(sorted(reports))))

    clocks, pll_msgs = check_pll(texts, args.expect_clock)
    for name, freq in clocks:
        print('   pll  %-70s %s' % (name.split('~')[-2] if '~' in name else name, freq))
    problems += pll_msgs

    worst, tim_msgs = check_timing(build_dir)
    if worst is not None:
        print('   sta  worst slack %.3f ns' % worst)
    problems += tim_msgs

    problems += check_sdc(build_dir)

    ram_findings = check_ram_as_rom(texts, allow_res)
    for kind, atom in ram_findings:
        problems.append('%s: %s is a RAM the compiler turned into a ROM - its write '
                        'port can never fire' % (kind, atom))

    stuck = check_stuck(texts, scope_re, allow_res, args.artifacts)
    for kind, node, why in stuck:
        problems.append('%s: %s - %s' % (kind, node, why))

    if problems:
        print('')
        print('NEEDS A LOOK (%d)' % len(problems))
        for p in problems:
            print('   - ' + p)
        print('')
        print('A RAM that cannot be written and a register that cannot change both')
        print('compile, place, route and close timing. They just never do anything.')
        return 1

    print('   ok   no dead logic in the core\'s own modules')
    print('   ok   every SDC constraint in compile.log matched something')
    return 0


if __name__ == '__main__':
    sys.exit(main())
