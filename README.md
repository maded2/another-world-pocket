# Another World for the Analogue Pocket

An [openFPGA](https://www.analogue.co/developer) core that runs **Another World** (*Out of This
World*, Delphine Software, 1991) on the Analogue Pocket — the original game engine, not a rewrite:
[sylefeb's a5k](https://github.com/sylefeb/a5k) Silice virtual machine, ported to the Pocket and
extended with a paged single-file game image, the game's own 4-channel 8-bit sound, its music
tracker, and working chapter switching.

> **You must supply the game data yourself.** This repository contains no game files. The data is
> extracted from the **PC (DOS) release of Another World** — the files `bank01`…`bank0d` and
> `memlist.bin` — which you need to own and copy into `gamedata/`. Nothing in this repo can
> substitute for it, and the build stops with a clear message if it is missing.

---

## What works

| | |
|---|---|
| **All eight game parts in one file** | One dataslot upload carries every part; the eight 2 MiB part views share their identical 32 KiB frames in a pool, so the whole game plus audio fits in 3.64 MiB |
| **Picture** | The original renderer (blitter, rasterizer, polygon engine) at 320×200, 4:3, 60 Hz |
| **Sound** | The original 4-channel 8-bit mixer at 48 kHz over I2S, including looping samples |
| **Music** | The game's Amiga-style music modules played by an RTL tracker — verified sample-for-sample against a transcription of the original player |
| **Chapters** | The game asks for the next chapter itself, and the OSD can move between parts while it runs — the switch restarts the VM cleanly instead of blanking the screen |
| **Saves / dock** | Save states are not supported (`sleep` and save states disabled); the Dock is declared, analog output is not |

Known open items are listed in `docs/another-world/port-log.md`; the two that matter are a ±1
sample residual in the tracker's PCM at one particular row rate (8 ms rate is exact) and the fact
that only one hardware run has exercised a mid-game chapter change so far.

---

## Requirements

- **Another World, PC (DOS) version** — `bank01`…`bank0d` + `memlist.bin` from that release.
- **Docker** with ~20 GB free disk (the Quartus image is ~15 GB) and Python 3 on the host.
- *Nothing else.* Quartus, Verilator, Icarus and Silice all live in the containers.

The build environment itself is documented in
[`docs/ap-tool-build-environment.md`](docs/ap-tool-build-environment.md).

---

## Build

### 1. One-time setup

```bash
make image            # Quartus build image on top of didiermalenfant/quartus (~15 GB)
make silice-image     # Silice + Verilator + Icarus image, for the netlist and the benches
```

### 2. Game data

Copy the PC release's data files into `gamedata/`:

```
gamedata/
  bank01 … bank0d      # the DOS release's data banks
  memlist.bin          # the resource table
```

### 3. The ROM image (the dataslot file)

```bash
make rom
```

That single command runs the whole pipeline and verifies it:

1. `ports/another-world/packs/part0.bin`…`part7.bin` — eight 2 MiB packs, one per game part;
2. `build/aw-audio.bin` + `build/aw-audio.json` — every sound effect (103, 11 of them looping) and
   all three music modules, unpacked from the same banks;
3. `build/aw-all-audio.bin` — the frame pool, the eight page tables and the audio blob, then a
   byte-for-byte verification that each part's 2 MiB view is identical to its pack.

Output: **`build/aw-all-audio.bin`**, 3,813,404 bytes (3.64 MiB), sha256 `9719548c…` for the retail
data. Useful variants:

```bash
make rom ARGS=--skip-packs      # reuse the packs, rebuild only audio + image
make rom ARGS=--no-audio        # pool-only image (silent)
scripts/build_all_in_one.sh --out my-image.bin
```

### 4. The core bitstream

```bash
make build CORE=aw            # Quartus: analyse, fit, route, assemble -> build/aw/bitstream.rbf_r
make check-build CORE=aw      # audit the reports: dead logic, clock assignments, timing
```

`make check-build` is not decoration: a design can close timing while a RAM has become a ROM or a
register can never change. It looks for exactly that, and for SDC constraints that matched nothing.

### 5. Package

```bash
make package CORE=aw
```

Produces a ready-to-copy SD layout and a zip:

```
build/sd/aw/
  Cores/Eddie Chan.Another World/     core.json, video.json, bitstream.rbf_r, loader.bin …
  Platforms/anotherworld.json
  Platforms/_images/anotherworld.bin
  Assets/anotherworld/common/         aw-all-audio.bin, the per-part packs
  Eddie Chan.Another World-1.0.0.zip
```

`core.json` is stamped from the artifact it ships with (version and a release date taken from the
bitstream's timestamp) so the folder label cannot disagree with the bitstream inside it.

### 6. Tests (optional, no hardware needed)

```bash
make sim              # static lint + the whole bench suite
make sim-tracker-pcm  # the tracker's audio against the reference renderer, sample for sample
make sim-soc          # boot the design in simulation, capture frames as PPMs
make lint             # fail if a signal the core reads is driven by nothing
```

---

## Install on the Pocket

1. Copy **`Cores/`, `Platforms/` and `Assets/`** from `build/sd/aw/` to the **root of the Pocket's
   microSD card**. Merge — do not replace the folders; other cores live there too.
2. Put the game image where the platform looks for assets. `package` already places it at
   `Assets/anotherworld/common/aw-all-audio.bin`; if you are installing by hand, copy
   `build/aw-all-audio.bin` there.
3. On the Pocket: **openFPGA → Another World**.
4. In the core's menu choose the dataslot file **`aw-all-audio.bin`**. This is the one file that
   carries the whole game; the eight separate `partN.bin` files are only for older test builds.
5. Launch. The intro starts from the first frame, with sound effects and music.

### Choosing a chapter

`Game part` in the core's OSD lists **Part 1 … Part 8** (the game's own numbering; Part 1 is the
copy-protection screen, Part 2 the intro). The choice is persisted, so it applies from the first
frame on the next launch. You can also change it **while the game is running**: the core switches
the page table, restarts the VM and renders the new chapter without an upload or a relaunch. Left
alone, the game requests the next chapter by itself, as the original does.

### Controls

D-pad to move, **A** or **B** to act — Another World has a single action verb, so both face buttons
are fire. The core declares no custom controller block (it reads the OS default pad mapping) and is
single-player; START and the analog stick are not used.

---

## Troubleshooting

**Black or silent, with the right file selected.** Check the console line over the Pocket's USB-C
debug port (115200 baud on `/dev/ttyUSB0` when docked to a PC):

```
AW 1065a up
C0:… Z.0 0545c705/0545c705 G15 E00
M1 0119 005a  I02c A2f0008  C02 S0e D02  K416a  E1a
```

| field | meaning |
|---|---|
| `Z.0` + equal sums | the whole image upload arrived and matches its declared checksums |
| `G15` | the part currently installed (1) and its flags — bit 3 means a select was refused |
| `M1 … rows/notes` | the music tracker is running, and how far |
| `K416a` | the audio index was found in the image (tag `41`, 106 records) |
| `E…` | how many `op_playSound` requests the game has issued |

A `K0000` means the selected dataslot file has no audio section — almost always the wrong file.
Equal `Z` sums with a black screen means the upload was fine and the problem is downstream.

**Nothing on screen at all.** The core needs the dataslot file selected; without one it refuses to
boot rather than drawing a black screen.

**Rebuild reproducibility.** `make rom` is deterministic for the same input data: the image's
sha256 is the check. `make build` needs an existing Silice netlist; if the tree has never been
translated, run `make pocket-translate` first.

---

## How it works, briefly

The original engine is a bytecode interpreter whose "ROM" is a 2 MiB data pack per game part. This
port keeps the engine intact and replaces the storage below it:

- **Paging.** The eight packs are 79 % identical at the same offsets, so the core stores a pool of
  distinct 32 KiB frames plus a 64-entry page table per part. The VM still sees a flat 2 MiB view,
  byte-identical to the pack it would have read; it never learns there is a pool.
- **Streaming.** A byte-stream loader with a 16 KB FIFO feeds the VM over the bridge, which is what
  makes a 3.64 MiB upload arrive intact.
- **Audio.** The index of every sound and music resource is copied out of the image at boot; the
  mixer fetches sample bytes through the same PSRAM port as everything else, with the music tracker
  and effects sharing it by priority.
- **Chapters.** The game's own `op_updateMemList` request is surfaced to the core, which points the
  page table at the new part and restarts the VM — with the trailer re-read and the thread table
  reset to what a cold boot has, which is what makes the new chapter actually run.

Details, measurements and the failures that got here are in
[`docs/another-world/port-log.md`](docs/another-world/port-log.md).

---

## Repository layout

| Path | What |
|---|---|
| `cores/aw/` | the core: APF metadata, `core_top.v`, the APF bridge, the audio and ROM RTL, the Silice SoC source |
| `ports/another-world/` | the a5k port work: extractor, packs, upstream sources |
| `scripts/` | build, extract, package, install and simulation entry points |
| `docs/another-world/` | port log, audio plan, single-image plan, problem analysis, hardware bring-up notes |
| `docs/ap-tool-build-environment.md` | the Docker/Quartus environment this all runs in |
| `gamedata/` | **you supply this** — the PC release's data banks |

---

## Credits and licensing

- **Another World** / *Out of This World* is © Delphine Software International, designed by Éric
  Chahi. All game data, graphics, sound and music remain the property of their owners. This project
  ships no game data, and the extraction tools only operate on files you provide from a copy you
  own.
- The engine implementation is **[sylefeb/a5k](https://github.com/sylefeb/a5k)** (MIT), a Silice
  port of the original bytecode interpreter and renderer, used here as the SoC's core. The
  divergences from upstream (the part request, the audio opcodes, the trailer counter re-arm and the
  cold-boot thread table) are enumerated in `scripts/pocket_translate.sh`.
- Analogue, Pocket and openFPGA are trademarks of Analogue. This is an unofficial, non-commercial
  port and is not affiliated with or endorsed by Analogue, Delphine Software or Éric Chahi.
