# Feasibility probes: A1 (can a5k reach Quartus) and C2 (framebuffer memory)

Run on 2026-09-13 against `sylefeb/a5k` @ `19c2e34` (pinned in
`ports/another-world/UPSTREAM_PIN`) using Silice 1.0.11 (`620487d`), Quartus
Prime Lite 22.1std.2 (build 922), device **5CEBA4F23C8**.

All commands and artifacts are in the repo so these can be re-run:
`docker/Dockerfile.silice`, `ports/another-world/probe/`.

---

## Headline

**The a5k design does reach Quartus, and the port's hard part is not the
toolchain — it is one memory property.**

| Question | Verdict | Evidence |
|---|---|---|
| **A1** — can the design be handed to the Pocket toolchain at all? | **Yes, with one project-level switch.** Silice emits SystemVerilog (sized casts such as `12'(...)`); Quartus parses `.v` as Verilog-2001 and reported 19 syntax errors at 16 locations. Declaring the file `SYSTEMVERILOG_FILE` removed **every** syntax error. | probe 1 vs probe 2 below |
| Vendor lock-in surface | **Small and confined to board plumbing: 4 primitive types, 12 instances.** After the SystemVerilog switch, the *only* errors were `SB_PLL40_PAD` ×1, `SB_GB` ×1, `SB_IO` ×9, `SB_SPRAM256KA` ×1 — all inside `pll`, `sb_io*`, `ice40_spram` wrappers. The VM, blitter, rasterizer, videopages, palette and SPI-flash controller elaborated. | probe 2 |
| **A2** — does it fit? | **Memory: yes, comfortably — with the right framebuffer shape** (1,024,000 of 3,153,920 bits = 32.5 %). Logic area not yet measured (the full-design run died on the C2 issue below); upstream is ~5 K LUT-class against 18,480 ALMs. | probe 3 + variant c |
| **C2** — can the SPRAM framebuffer be mapped? | **No, not as written.** A sub-byte write mask on a 16-bit port does not map to Cyclone V block RAM: both nibble-mask and byte-mask variants exceeded a 420 s synthesis timeout, while the unmasked control and the design's *own* per-pixel 4-bit variant synthesized instantly. | probe 4 |

---

## Probe 1 — a5k Verilog as-is (Verilog-2001 mode)

```
silice-make.py -s a5k.si -b icebreaker -p basic,vga,qspiflash,buttons \
               -o BUILD_probe --no_build          ->  build.v (181 KB, 8152 lines, 32 modules)
quartus_map (SYSTEMVERILOG off)  ->  rc=3, 19x Error (10170) at 16 distinct lines
```

First rejection:

```verilog
_d___block_15_cpt2 = $signed(`_c___block_15_init_cpt2)<<16;
// macro expands to:  (12'($signed(...)+...))     <- SystemVerilog sized cast
```

(The generated `build.v` is not committed - it is MIT-licensed upstream output;
regenerate it with the command at the bottom of this file.)

Also observed (warnings, **not** blockers, but see the caveat):

```
Warning (10335): Unrecognized synthesis attribute "no_rw_check"
Warning (10335): Unrecognized synthesis attribute "full_case"
Warning (10335): Unrecognized synthesis attribute "parallel_case"
```

*Caveat to carry forward:* those three are yosys-isms that Quartus silently
ignores. `full_case`/`parallel_case` are don't-care/hazard hints; ignoring them
is generally conservative but means the target's inferred logic is not the same
as the source's, so behavioural equivalence cannot be assumed from "it
elaborated".

## Probe 2 — same Verilog, declared SystemVerilog

```
set_global_assignment -name SYSTEMVERILOG_FILE build.v
quartus_map -> rc=3, 12 errors, all Error (12006) "instantiates undefined entity"
```

| Missing entity | Instances | Lives in |
|---|---|---|
| `SB_PLL40_PAD` | 1 | generated `pll` wrapper (board clock) |
| `SB_GB` | 1 | global buffer |
| `SB_IO` | 9 | `sb_io` / `sb_io_inout` / `ddr_clock` (IO + QSPI pads) |
| `SB_SPRAM256KA` | 1 | `ice40_spram` (the framebuffer primitive, instantiated 4×) |

Everything else — `M_main`, `M_vm_M_main_vm`, `M_blitter_M_main_blit`,
`M_rasterizer_M_main_rast`, `M_videopage_M_main_page0..3`, `M_spiflash_*`,
`M_vga` — parsed and elaborated. Memories are emitted as ordinary inferred
arrays (`(* no_rw_check *) reg [W-1:0] buffer[D-1:0];`), which is the portable
form.

## Probe 3 — framebuffer memory shapes × 4 instances (the four framebuffers)

All on 5CEBA4F23C8, `quartus_map`, 420 s cap. This isolates the C2 constraint.

| Variant | Shape | Result |
|---|---|---|
| **a** | 16-bit words, **4-bit (nibble) write mask**, sync read — *what SPRAM does today* | **TIMEOUT > 420 s** |
| **b** | same, async read | **TIMEOUT > 420 s** |
| **c** | **per-pixel 4-bit RAM**, 320×200, sync read — *the design's own ECP5/ULX3S path* | **OK, instant: 1,024,000 memory bits, 12 registers** |
| **d** | 16-bit words, **8-bit (byte) write mask**, sync read | **TIMEOUT > 420 s** |
| **e** (control) | 16-bit words, **no write mask**, sync read | **OK, instant: 1,048,576 memory bits** |

Reading: the blocker is **write-mask granularity on a wide port**, not capacity
and not the RAM size — the unmasked control of identical size maps immediately.
Cyclone V M9K byte-enable exists only for the 72/36/18-bit modes, so a masked
16-bit port has to be built from logic (read-modify-write), and Quartus's
attempt does not terminate in reasonable time at this depth.

The consequence for the port is concrete and bounded: the framebuffer has to be
expressed in the shape variant **c** — which is exactly the second
implementation the a5k source already carries for the ULX3S
(`bram uint4 pixels[320*200]`). That path occupies **32.5 %** of the Pocket
device's block RAM, leaving room for the VM's own memories (256 VM variables,
64 thread records, polygon buffer, 128-deep polygon stack, ROM prefetch cache,
palette).

## What this does *not* yet establish

- **Functional equivalence.** Elaboration is not correctness: the PLL and IO
  stubs in these probes are deliberately meaningless, and the three ignored
  synthesis attributes change what gets inferred. A golden-reference comparison
  (analysis A8) is still needed before any behaviour claim.
- **Whole-design area.** The full-design synthesis attempt blew past memory
  (`malloc: large alloc 1073741824 bytes`) precisely because of the masked-RAM
  problem, so ALM utilisation is still unmeasured. Re-running it against the
  variant-c framebuffer shape is the next measurement.
- **Timing** (analysis C4): the 74.25 MHz → 25 MHz relationship (not an integer
  divide) and the missing `video_de` are untouched by these probes.
- **ROM delivery** (analysis C1) is entirely unaddressed so far — the probe
  synthesised the QSPI master as dead logic behind stub pads; that is the next
  and largest unknown.

## How to re-run

```bash
# Silice toolchain (builds Silice from source in Ubuntu 24.04)
docker build -f docker/Dockerfile.silice -t local/ap-silice:latest .

# emit Verilog for the upstream design
docker run --rm -v $PWD:/work -w /work/ports/another-world/upstream/hardware \
  local/ap-silice:latest python3 /opt/Silice/bin/silice-make.py \
  -s a5k.si -b icebreaker -p basic,vga,qspiflash,buttons -o BUILD_probe --no_build

# Quartus probes (probe/ holds a1probe.qpf/qsf, lattice_stubs.v, ramshape/)
docker run --rm -v $PWD:/work -w /work local/ap-silice:latest true   # tool check
docker/run.sh ports/another-world/probe/ramshape/run.sh              # the 4 shapes
```
