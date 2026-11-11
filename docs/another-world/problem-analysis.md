# Porting *Another World* (a5k) to Analogue Pocket — problem analysis

**Scope of this document:** analysis only. It states what the problem *is* — the
gap between the source design and the target, the requirements, constraints,
risks, and the decisions that must be settled before any implementation is
started. It deliberately contains no design, architecture, or implementation
proposal.

Subject: [`sylefeb/a5k`](https://github.com/sylefeb/a5k) — "Another World on a chip",
a hardware implementation of the Another World / Out of This World engine
(custom VM processor + blitter + polygon rasterizer + SoC) for Lattice FPGAs
(iCE40 UP5K on icebreaker / mch2022 badge, ECP5 on ULX3S), targeting a Pocket
core under the openFPGA framework.

---

## 1. Problem statement and context

The user wants the Another World experience delivered through the Pocket's
ecosystem: a core folder on the SD card, Analogue OS selecting the game, video
and audio through the Pocket's scaler and amplifier, controls from the Pocket
D-pad and buttons (and Dock), and the game files coming from the SD card.

This is not a "recompile the same files for another chip" port. Three separate
mismatches have to be understood before any of them can be reasoned about:

1. **Description-language / toolchain mismatch.** The source of truth is
   67 KB of [Silice](https://github.com/sylefeb/Silice) (`.si`), compiled by
   `silice-make.py` with board/peripheral parameter sets
   (`basic,vga,qspiflash,buttons`, `basic,hdmi,qspiflash,buttons`,
   `basic,psram,lcd,espspi`, `basic,vga` for simulation) and built with the
   Lattice flow (yosys/nextpnr). The design also *imports* hand-written Verilog
   (e.g. `./common/ulx3s_50_25.v`) and vendor-specific primitives
   (`ice40_spram`, `simulation_spram`, PLLs). The Pocket toolflow consumes
   Verilog/VHDL through Quartus Prime Lite with the APF (Analogue Pocket
   Framework) as top level.
2. **Machine-architecture mismatch.** The source design is a *board*, not a
   framework-compatible core: it owns its clock, its display timing, its input
   pads, and — most importantly — it fetches the game program directly from
   Quad-SPI flash as an addressable, burst-streaming ROM.
3. **Game-delivery mismatch.** On the source boards, per-part game data packs
   are built by a host tool from the user's own copy of the game and flashed to
   SPI flash next to the bitstream. On the Pocket, ROM is chosen by Analogue OS
   from the SD card and delivered into the core by the host over the bridge bus
   as data-slot transfers.

A further contextual factor: the source is a personal project explicitly
described as unfinished (see §8), so part of the problem is deciding what
"ported" means when the thing being ported is itself incomplete.

---

## 2. Stakeholder analysis

| Stakeholder | Interest / concern |
|---|---|
| **The user (person porting)** | Wants a playable, faithful Pocket core; wants to know quickly whether the effort is viable and what it will take; does not want to discover deal-breakers after weeks of work |
| **Pocket owners** | Expect the game to behave like any other core: appears in the menu, ROM picked from SD, correct video on the built-in screen and Dock, sound, controls, savestates, no bricking |
| **sylefeb (a5k author)** | Authorship and licence terms (design MIT, write-up CC BY-NC-SA); design is explicitly unfinished; not the maintainer of any port and should not be burdened with port bugs |
| **Analogue** | Framework/EULA terms govern APF use; branding and platform metadata must be truthful; cores must not harm hardware |
| **Original game rights holders (Delphine/Ocean successors, currently Atari-side IP)** | The game data is copyrighted and is not in either repository; the port is only usable by people who own the game |
| **Community (openFPGA core authors, core updaters)** | Would consume the result; a half-ported game that advertises itself as complete damages trust in Pocket cores |

---

## 3. User needs and pain points

**Needs**

- N1. A clear verdict on viability of each part of the port, cheaply obtained, before committing effort.
- N2. Play Another World on Pocket hardware with picture and sound the way other Pocket cores behave.
- N3. Use their own legally owned game files, without being asked to run an unfamiliar build toolchain to prepare them.
- N4. Move between the game's seven parts without leaving the game to reconfigure hardware.
- N5. Save progress and resume — the Pocket's defining convenience, and a feature the original 1992 release handled with passwords/saves.
- N6. Know whether a bug they hit came from the port, from the source design, or from their game files.

**Pain points in the current state**

- P1. The source has **no sound and no music at all** (stated explicitly in the source README). A Pocket core with silence is a visible defect to a Pocket user.
- P2. **One game part per synthesized design**: per-part data-section offsets are baked into the hardware. The author lists "link parts together" as unfinished future work. On the Pocket, switching parts would mean switching what is loaded — the experience is fragmentary.
- P3. ~~No audio path exists in the design and the author is unsure music can be added at all on the
  smallest device.~~ **RESOLVED (2026-11-11):** extractor, RTL mixer, 48 kHz I2S and the music tracker are
  all built and hardware-verified (AW 1062 capture: 282 tracker rows, 90 notes; the intro's looping
  effects play). The device had room all along - the audio index becoming block RAM took the design
  from 97% to 60% LABs. See audio-plan.md.
- P4. **Timing is already known to be wrong** ("the game tends to be too fast") and the port changes every clock relationship, so a defect the source has not resolved becomes unanchored.
- P5. **Known unresolved visual defect** (tiny dots under text rendering) that the port would inherit and be blamed for.
- P6. **Data-pack preparation requires building and running a GPL'd C++ fork** against the user's game files. Pocket users do not do this today; there is no equivalent path on the device, and no way to ship the result.
- P7. The source design has **never been play-tested end to end** by its author; several behaviours (polygon recursion depth, later parts) are unverified.
- P8. Game-file sensitivity: the design is known to work with the DOS version dated 19/3/92; other releases "might run into issues". A Pocket UI that lets anyone select any file invites silent failure.

---

## 4. Requirements

### 4.1 Functional (in user terms)

- F1. The core appears in Analogue OS under a platform that makes sense for a 1992 computer game, and shows a picture on selection.
- F2. The user selects a game file from the SD card and the game starts.
- F3. All rendered graphics — polygons, transparency, the water-shimmer texture-copy effect, pre-rendered fonts and part-6 backgrounds — appear as they do in the source design.
- F4. Controls respond: 4-direction plus two actions (the source's joystick interface is a 6-bit joystick), plus whatever the game needs for pause/menu.
- F5. The four game parts the user reaches are reachable in one continuous session; progression is not blocked by hardware configuration.
- F6. Audio: some defined behaviour — either faithful sound, or an explicitly agreed silent scope.
- F7. Savestate/resume: either supported, or explicitly declared unsupported (the way shipping cores do).
- F8. The core works on the Pocket screen and, if declared, on the Dock, including the analog-output declaration.
- F9. Failure to find/select valid game data is communicated to the user rather than producing garbage.

### 4.2 Non-functional

- NF1. **Fidelity**: picture must match the source (4-bit palette, 320×200, 2× upscale behaviour, double-buffer swap semantics, no tearing).
- NF2. **Timing accuracy** relative to the original game's feel — already a source weakness, and the port must not make it worse.
- NF3. **Resource feasibility**: source is ~5K LUT4-class plus 128 KB of framebuffer storage plus modest VM RAM. Pocket device 5CEBA4F23C8 offers 18,480 ALMs and 3,153,920 memory bits, so capacity is not the binding constraint; behaviour of the memories is (§5).
- NF4. **Determinism/reproducibility** of builds (a Pocket release is a single artifact users install).
- NF5. **Installability** by ordinary Pocket users: SD-card copy, optionally via the community updaters.
- NF6. **Debuggability**: the port must be verifiable short of owning the hardware for every question, because the source's verification habit (compare instruction traces against a C++ reference) cannot be carried over unchanged.
- NF7. **Legality and attribution** of every shipped artifact.

---

## 5. Constraints and the hard gaps (source reality vs target reality)

These are the properties that make the port non-trivial. They are stated as
facts and consequences, not as design directions.

| # | Property in the source | Property of the target | Consequence to be resolved (what, not how) |
|---|---|---|---|
| C1 | Game program and graphics are read from Quad-SPI flash as an addressable memory that streams a byte per cycle after latency; the VM fetches instructions directly from it, with a 64-byte BRAM prefetch cache | The core has no user-addressable flash. ROM arrives as a host-initiated bulk transfer into core-owned memory via data slots, with id/offset/length and completion signalling | The design's fundamental notion of "where instructions come from" changes. Something must be true about program storage on the target; the source's assumptions (instant random access, unbounded capacity, content persists across power cycles, offsets baked in) all stop holding |
| C2 | Four 320×200 4 bpp single-port framebuffers in UP5K **SPRAM**: one read *or* write per cycle, 16-bit interface, **nibble write mask**, one-cycle read latency | Pocket device memories are block RAMs with different port counts, widths, write-enable granularity and latency; the design already carries a second framebuffer implementation for ECP5 using plain per-pixel RAM, showing this is a recognised variation point | Every arbiter and latency assumption in the display path, blitter and rasterizer is tied to "one access per cycle, one-cycle read latency". Whatever memory the target provides, the arbitration and read-back pipelining must be re-derived and re-verified |
| C3 | Blitter and rasterizer are deliberately paused during blanking (`enabled <: vblank`, `display_conflict`) because the displayed page is single-ported | The Pocket scaler consumes a continuous pixel stream produced by the core; the core does not own a VGA-style blanking interval in the same way | The notion of "when may the blitter/rasterizer touch the displayed page" must be re-established against the target's blanking/de semantics, or visible corruption results |
| C4 | SoC runs at 25 MHz; QSPI needs 2×; VGA/HDMI timing is 800×480 total at 25 MHz with 320×200 upscaled 2× inside 640×400 active, top/bottom bars; PLLs are board-specific (`pll_50_25`, `unit pll(clock2x, clock1x)`) | The only clocks handed to a core are two asynchronous 74.25 MHz inputs; the core must supply its own pixel clock, its 90° twin, `de`, `hs`, `vs`, `video_skip`, and declare a scaler mode per video mode | All clock ratios must be re-derived from 74.25 MHz (25 MHz is not an integer division of it), and the display stage must be expressed in the target's signalling vocabulary — which includes a **data-enable signal the source VGA path does not produce** |
| C5 | ~~No audio anywhere in the design~~ **closed 2026-11-11**: effects + tracker audible at 48 kHz on hardware | The Pocket has a defined audio path (master clock, DAC data, LRCK) and users expect sound | Resolved: this was a feature (not a wire) and it was built — see audio-plan.md |
| C6 | One bitstream per game part; per-part section offsets compiled in | A Pocket core folder may declare several core variants with distinct ids and a variant-selection mechanism, and one platform per game | The "seven parts" problem lands on the Pocket's variant model, where it becomes a *user experience* question (how does a player progress?) as much as a hardware one |
| C7 | Inputs are raw buttons (`uint6 jstick`; one button resets the VM thread as an easter egg) | The core receives per-player key/joy/trigger bit vectors with a defined bit map, and must declare its controllers in `input.json` | Button semantics and the reset easter egg must be reconciled with declared controllers and with Dock/4-player declarations |
| C8 | Palette lives in the FPGA and the VM switches it (`pal_swap`) | Cores output 24-bit RGB; the Pocket also has its own palette/scaler features | Ownership of colour must be explicit; interaction with Pocket palette features must be understood, not assumed |
| C9 | Verification culture: Silice + Verilator simulation, instruction traces diffed against the C++ interpreter, `__display` asserts in the design | No Silice in the target flow; verification must survive the translation from `.si` to whatever the target compiler consumes | The source's safety net disappears at exactly the moment the design is being changed. What replaces it is a problem in its own right |
| C10 | Game data: `BANK01`…`BANK0C` + `MEMLIST.BIN` copied from a licensed DOS release (19/3/92), converted by a host-built tool into per-part `.raw` packs flashed beside the bitstream | Users place ROM files in `Assets/<platform>/common`; the core declares data slots and file types and receives them over the bridge | Two sub-problems: (a) the conversion step and its toolchain dependency, (b) what file format the Pocket user is asked for. Also: pre-rendered fonts and part-6 backgrounds are **derived from copyrighted data** |
| C11 | Generated code carries `full_case`, `parallel_case` and `no_rw_check` synthesis attributes (yosys conventions) | The target compiler ignores all three with a warning | Behavioural equivalence is not implied by a successful compile: don't-care inference and read/write-check assumptions differ. Measured in feasibility-probes.md |

---

## 6. Business rules and constraints (non-technical)

- B1. **Licences.** The a5k design is MIT. Its README/write-up is CC BY-NC-SA 4.0. The modified C++ interpreter used to build data packs is GPL. The game data is copyrighted and shipped by nobody. Consequences to clarify: what may be distributed (bitstream? data packs? generated fonts?), what attribution is required, and whether a non-commercial clause attaches to anything derived from the write-up.
- B2. **APF/EULA.** The `apf/` sources are Analogue's and licensed for building cores for Analogue hardware.
- B3. **Release conventions.** Pocket releases are zips of `Cores/`, `Platforms/`, `Assets/`; community updaters consume them; a core that is silent or one-part-only must say so plainly in `info.txt` and the release notes.
- B4. **Author relations.** A port of someone's unfinished personal project should not become their bug tracker.
- B5. **Precedent exists and sets expectations**: other Pocket cores are ports of MiSTer/other-board designs, so the community will compare; a core that visibly runs "too fast" or without sound will be judged against that bar.

---

## 7. Success criteria (to be agreed — candidate definitions)

Because "port Another World" is ambiguous, the decision must be made explicit.
Candidate definitions, from least to most ambitious:

| Level | Definition | What it demands |
|---|---|---|
| **S0 — feasibility proof** | The intro sequence (part 2) appears on Pocket hardware, correct picture, no sound, controlled by the Pocket D-pad | C1, C2, C3, C4, C7 |
| **S1 — single part, well behaved** | S0 plus correct video modes/aspect, clean timing, declared platform and inputs, installable, documented as "one part, no sound" | + F1, F9, NF1, NF5, B3 |
| **S2 — the game, silent** | All seven parts reachable in one session, savestate support or explicit non-support | + C6, F5, F7 |
| **S3 — the game, with sound** | S2 plus sound effects, and a decision on music (which the upstream author thinks may be infeasible) | + C5, F6 |
| **S4 — a release people recommend** | S3 plus timing fidelity, the text-dots defect understood, upstream/portal bugs distinguished, polished UX for wrong game version | + P4, P5, P8, NF2, NF6 |

A metric worth fixing early: *the number of parts the user can play in one
power-on without touching hardware configuration*, and *whether the core is
silent*. Those two numbers decide which level has actually been reached.

---

## 8. Assumptions requiring validation

Each of these is currently believed but not proven; several are cheap to test.

- A1. **[RESOLVED — yes; see §12]** That the Silice-authored design can be expressed to the target compiler at all — i.e. that what Silice emits (generated Verilog plus imported Verilog plus vendor primitives, and memories inferred by a Lattice flow) is acceptable to Quartus for a Cyclone V device.
- A2. **[PARTLY RESOLVED — memory side: yes, 32.5 % of block RAM using the per-pixel framebuffer shape; logic area unmeasured]** That the design's logic fits the Pocket device with the framebuffers in block RAM.
- A3. That a 25 MHz-equivalent SoC clock and a matching pixel clock can be derived from the single 74.25 MHz input with the accuracy the game's own (already loose) timing needs.
- A4. That the game program can live entirely inside the target's memory once delivered — the source's data pack for the largest part must be measured against the target's available RAM, because unlike SPI flash, target RAM is finite and shared with the framebuffers.
- A5. That a single delivered file can serve all parts, or that the part structure can survive being delivered as one blob.
- A6. That the polygon recursion stack (hard-coded at 128) is sufficient for a full playthrough — the author has not verified this.
- A7. That the DOS 19/3/92 data version is the only one worth supporting.
- A8. That the source design's behaviour is reproducible bit-for-bit in simulation before/after translation — i.e. that a golden reference (frame or trace) can be produced and compared.
- A9. What the Pocket's savestate mechanism actually requires of a core, and whether ~128 KB of framebuffer plus VM state is within its bounds. (Do not guess; the framework docs and shipping cores are the source of truth.)
- A10. That the 320×200 (and its 2× upscaled presentation) is expressible as a Pocket scaler mode in the way the source presents it, including the top/bottom bars.

---

## 9. Risks and unknowns

| Risk | Impact | Likelihood (judgement) | Note |
|---|---|---|---|
| **Translation risk**: HDL/toolchain translation changes behaviour subtly (memory inference, read latency, initialisation of RAMs, `uninitialized` framebuffers) | High — silent corruption that reads as "the port is broken" | High | The framebuffers are explicitly `uninitialized` in the ECP5 path; power-on contents on the target are undefined and the game may or may not depend on that |
| **ROM-delivery risk**: the program-data model is the deepest behavioural change | High | High | C1 |
| **Memory-arbitration risk**: single-port assumptions (display vs blitter vs rasterizer) no longer hold or hold differently | High — flicker, corruption, or stalls | Medium–High | C2/C3; also the *performance* headroom changes because the target clock differs |
| **Scope creep via audio**: audio does not exist upstream, so "add sound" is a feature project, not a port | Medium–High on schedule | High | P1, C5 |
| **The seven-parts problem** turns a port into a game-architecture project | High | Medium | C6, P2 |
| **Bug attribution**: a bug appears; is it the port, the source, or the game files? No playthrough exists upstream to compare against | Medium–High on effort | Medium | P7; mitigated only by an A8-style golden reference |
| **Asset pipeline and legality of shipped derivatives** (pre-rendered fonts/backgrounds generated from copyrighted data) | Medium | Medium | B1, C10 |
| **Upstream movement**: a5k is still being updated ("delete your previous ROMs files" note); a port forks silently | Low–Medium | Medium | Needs an explicit upstream-tracking stance |
| **Data-pack tool dependency** remains in the user's path (a GPL C++ build) | Medium | Medium | P6 |
| **Unknown Pocket requirements guessed rather than read** (savestate contract, scaler mode limits, file-type declarations, Dock) | Medium | Medium | Read the framework docs and a shipping core before committing to scope |

---

## 10. Problem decomposition (areas to work, ordered by how much they gate the rest)

1. **Artifact translation feasibility** — can the design be handed to the target
   toolchain and compile for the Pocket device at all, and what breaks (A1, A2).
   This gates everything and is the cheapest thing to learn.
2. **Program and data delivery** — what "ROM" means on the target, how a part
   arrives, how much of it must live in the device, and what happens when the
   wrong file is chosen (C1, C10, A4, A5, F2, F9).
3. **Memory and arbitration semantics** — the framebuffer/port/latency contract
   that the blitter, rasterizer and display all depend on (C2, C3, A8).
4. **Clocking and video presentation** — deriving clocks from 74.25 MHz, the
   target's video signalling (including the data-enable the source lacks), and
   the scaler mode for 320×200/2× (C4, A3, A10, NF1, NF2).
5. **Game structure: seven parts** — how a player experiences progression, and
   what the core declares to Analogue OS (C6, F5, P2).
6. **Audio** — either a scope decision or a feature (C5, F6, P1).
7. **Controls and platform declaration** — input mapping, Dock, platform
   metadata, controller declarations (C7, F1, F4).
8. **State and resume** — savestates, or explicit non-support (F7, A9).
9. **Verification strategy** — golden references, simulation vs hardware loop,
   and separating port bugs from source bugs (NF6, A8, P7).
10. **Asset and release workflow** — who converts game files, in what format,
    under what licence, and what gets shipped (C10, B1, B3, P6).

---

## 11. Decisions taken

Settled by the person commissioning the port:

| # | Question | Decision | Consequence for the problem |
|---|---|---|---|
| 1 | Success level | **S1** — one part, well behaved | Bounded scope: intro (and other parts as declared variants), correct video/inputs/platform metadata, installable, honestly documented. S2-S4 explicitly out |
| 2 | Sound | **Out of scope** | C5 becomes a documented non-feature rather than a work item; `audio.json` still has to declare the truth |
| 3 | The seven parts | **Selectable** (per-part variants acceptable) | C6 lands on how the core declares variants, not on runtime part-linking; progression becomes a menu choice rather than a hardware problem |
| 4 | Asset conversion in the user's workflow | **Acceptable** | The data-pack conversion tool may remain a build step; P6 is mitigated by documentation rather than removed |
| 5 | Fidelity bar | **Match the original game**, not the source design | The upstream "runs too fast" defect and the text-dots artifact are now *in scope to fix* rather than inherited. Raises the bar on C4 and NF2 |
| 6 | Verification bar | **Intro plays on hardware** | The golden-reference need (A8) narrows to the intro sequence |

Deferred, not answered: savestates (F7/A9), supported game-data versions beyond
DOS 19/3/92 (A7/P8), what may be distributed (B1), and the stance toward
upstream changes.

## 12. What the first probes established

See **[feasibility-probes.md](feasibility-probes.md)**.

- **A1 resolved favourably.** Silice emits SystemVerilog; declaring the
  generated file as SystemVerilog removed all 19 syntax errors, leaving only
  12 instances of 4 Lattice primitives, all confined to board plumbing. The
  entire game logic (VM, blitter, rasterizer, videopages, palette) elaborates
  for `5CEBA4F23C8`.
- **C2 became a measured constraint, not a worry.** A sub-byte write mask on a
  16-bit framebuffer port does not map to Cyclone V block RAM: nibble- and
  byte-masked variants both exceeded a 420 s synthesis timeout while an
  unmasked control of identical size mapped instantly. The a5k source already
  carries a per-pixel 4-bit framebuffer variant (its ULX3S path), and that
  shape maps in seconds at **1,024,000 of 3,153,920 memory bits (32.5 %)** for
  all four framebuffers.
- **New constraint C11**: three synthesis attributes used by the generated code
  (`full_case`, `parallel_case`, `no_rw_check`) are silently ignored by the
  target compiler — so "it elaborated" does not mean "it behaves the same",
  which strengthens the case for the golden-reference bar (A8).
- Still open and now the largest unknowns: **C1 (ROM delivery)** and
  **C4 (clocking / video signalling)**. Whole-design logic area is also
  unmeasured; the full-design attempt died on C2.


## 13. Evidence base (all read directly, not assumed)

- `sylefeb/a5k` README (38 KB, main branch): SPRAM/framebuffer reasoning,
  per-part baked offsets and "one design per game part", SPI prefetch cache,
  `display_conflict`, blitter/rasterizer arbitration during blanking,
  pre-rendered fonts and part-6 backgrounds, *"There's no sound and no music!!"*,
  the "What's left to do" list (timing too fast, text dots, music, linking
  parts, game-state experiment), game-data file list and DOS 19/3/92 note, and
  the licence section.
- `hardware/a5k.si` (882 lines): `unit pll`, `blitter`, `videopage` (two
  implementations — `ice40_spram` with nibble write mask vs plain
  `bram uint4 pixels[320*200] = uninitialized` for ECP5), `rasterizer`,
  `unit main` port list (leds, btns, VGA rgb/hs/vs, HDMI GPDI, `sf_*` QSPI,
  PSRAM, LCD, ESP SPI), display pipeline with `H_START/H_END` 800-wide timing
  and 2× pixel doubling, `import('./common/ulx3s_50_25.v')`.
- `hardware/vm.si` (1079 lines): `input uint6 jstick`, `input uint1 uart_rx`,
  blitter/rasterizer busy handshake, `polygonStack` (128), `ENABLE_GAMESTATE_EXPERIMENT`,
  `op_drawString` hijack for pre-rendered glyphs.
- `Makefile` / `hardware/Makefile`: per-part `ROMs/<part>.raw` produced by a
  host-built fork of the Another World bytecode interpreter
  (`./raw --extract=$* --datapath=../GAMEDATA --data-offsets`), flashed at
  offset 2 MB beside the bitstream; per-board Silice peripheral sets.
- Pocket side, from the vendored `open-fpga/core-template`: `core_top` port
  contract (`clk_74a/b`, `video_rgb[23:0]`, `video_rgb_clock[_90]`, `video_de`,
  `video_skip`, `video_vs`, `video_hs`, audio mclk/dac/lrck/adc, `bridge_*`,
  `cont1..4_key/joy/trig`) and `core_bridge_cmd.v` data-slot command set
  (`dataslot_requestread/write`, `dataslot_update` with id and size,
  `target_dataslot_*` with slot offset, bridge address and length).
- Analogue developer docs: platform metadata (`category`, `name`,
  `manufacturer`, `year`; 31-char limits), core definition files, SD folder
  structure, boot process.
- Measured in this workspace: Pocket device 5CEBA4F23C8 = 18,480 ALMs,
  3,153,920 memory bits, 308 RAM blocks, 4 PLLs, 224 user pins (from a real
  fitter report of the core template).
