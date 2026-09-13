# ap-tool — Analogue Pocket openFPGA build environment

A reproducible Docker build environment for [Analogue openFPGA](https://www.analogue.co/developer)
cores, built on the pre-built Quartus image [`didiermalenfant/quartus`](https://hub.docker.com/r/didiermalenfant/quartus),
plus the glue you need to take an existing FPGA core (MiSTer, other openFPGA cores)
to a `.rbf_r` that boots on an Analogue Pocket.

Everything below was run and verified in this workspace:

```
Quartus Prime Lite 22.1std.2 (build 922)   license-free, no licence file needed
base image  didiermalenfant/quartus:22.1-apple-silicon  (linux/amd64, Debian 9)
device      Cyclone V 5CEBA4F23C8           <- the FPGA inside the Pocket

make smoke    throwaway design placed/routed for 5CEBA4F23C8 in 26s -> smoke.rbf
make test     open-fpga/core-template compiled in 57s, positive slack in every
              STA corner (worst setup +5.26 ns, worst hold +0.135 ns),
              414/18,480 ALMs, bitstream reversed, packaged + zipped: OK
make new      scaffolded a fresh core, renamed the Quartus project, built and
              packaged it as Cores/<author>.<core>/ - end to end
artifacts     owned by the host user; no sudo, no root-owned files
```

---

## 1. Quick start

```bash
make image            # one-off: build the env on top of the Quartus image (~4 min, see FIX_PERMS)
make doctor           # Quartus + Cyclone V device DB + workspace checks
make build            # compile cores/core-template -> build/core-template/bitstream.rbf_r
make package          # -> build/sd/{Cores,Platforms,Assets} + a shippable .zip
make shell            # a shell inside the container, repo mounted at /work
```

Starting your own core:

```bash
make new CORE=mygame AUTHOR=jane PLATFORM=nes TITLE="Nintendo Entertainment System" \
         YEAR=1983 MANUFACTURER=Nintendo
make build CORE=mygame
make package CORE=mygame RELEASE=1
```

Copy (don't replace) `build/sd/Cores`, `build/sd/Platforms` and `build/sd/Assets`
to the root of the Pocket's microSD card, or use the generated zip.

Requirements: Docker, ~20 GB free disk (base image ~15 GB + build databases), and
Python 3 on the host for `make package` (any 3.x; the container ships 3.5 so the
scripts run in both places).

---

## 2. What is in the box

| Path | Purpose |
|---|---|
| `docker/Dockerfile` | derived image: repairs the base image's root-only Quartus install, installs the tooling on `PATH`, sets `/work` as the mount point (and `/build` for compatibility with community openFPGA CI scripts) |
| `docker/run.sh` | the one place the `docker run` flags live: mounts the repo at `/work`, runs as your uid, `HOME=/work/.home` |
| `docker/entrypoint.sh` | writable-`HOME` fallback, keeps the base image's `quartus-entrypoint` (GitHub auth, JTAG server), chowns output back when running as root |
| `scripts/build.sh` | the compile driver: finds the `.qpf`, applies build-time QSF tweaks, runs `quartus_sh --flow compile`, collects the bitstream, parses the fitter/STA summaries, reverses the bits |
| `scripts/reverse_bits.py` | `.rbf` → `.rbf_r` (per-byte bit reversal — the step Analogue calls "Creating a reversed RBF") |
| `scripts/package_core.py` | validates the core JSON contract and assembles the SD layout + release zip |
| `scripts/new_core.sh` | scaffolds `cores/<name>` from the template and renames the Quartus project |
| `scripts/doctor.sh` | environment checks, plus `--smoke` which compiles a throwaway design for the Pocket device |
| `cores/core-template/` | git submodule of [`open-fpga/core-template`](https://github.com/open-fpga/core-template) pinned at **v1.3.0** (`da3a021`) — Analogue's official starting point, containing the APF (Analogue Pocket Framework). Clone with `git clone --recurse-submodules`, or `git submodule update --init` afterwards |
| `build/<core>/` | `compile.log`, `report.txt`, `ap_core.rbf`, `ap_core.sof`, `bitstream.rbf_r` |
| `Makefile` | the front door; `make help` lists every target |

### How the toolflow works

```
cores/<core>/src/fpga/<proj>.qpf
   │  quartus_sh --flow compile <proj>.qpf -c <revision>
   ├─ Analysis & Synthesis   (quartus_map)
   ├─ Fitter                 (quartus_fit)   ← NUM_PARALLEL_PROCESSORS applied here
   ├─ Assembler              (quartus_asm)   → output_files/<proj>.sof + .rbf (GENERATE_RBF_FILE)
   └─ TimeQuest STA          (quartus_sta)   → <proj>.sta.summary
   │
   ├─ reverse_bits.py:  <proj>.rbf  →  build/<core>/bitstream.rbf_r
   └─ package_core.py:  JSONs + bitstream + platform metadata → SD tree + zip
```

---

## 3. Porting an existing FPGA core to the Pocket

### 3.1 What the Pocket hands you (the APF contract)

The top level is **`apf_top`** (`src/fpga/apf/apf_top.v`, provided by Analogue — do
not edit it). It owns the physical Pocket I/O: cartridge buses and their level
shifter directions, the two PSRAM chips, the OSD/scaler, the SPI bridge and the
I/O pad controller. Your core is instantiated by `apf_top` as **`core_top`**
(`src/fpga/core/core_top.v`) — that file is yours and is the whole port.

`core_top`'s logical interface (from the template, verbatim):

```systemverilog
// clocks: 74.25 MHz, two asynchronous copies - treat as async domains
input  wire        clk_74a, clk_74b,

// video to the scaler: 24-bit RGB888, pixel clock + its 90° twin
output wire [23:0] video_rgb,
output wire        video_rgb_clock, video_rgb_clock_90,
output wire        video_de, video_skip, video_vs, video_hs,

// audio to the codec (I2S-style: master clock, DAC data, LRCK)
output wire        audio_mclk, audio_dac, audio_lrck,
input  wire        audio_adc,

// host<->target bridge, synchronous to clk_74a (ROM download, savestates,
// OSD menu items, status). core_bridge_cmd.v implements the standard commands.
output wire        bridge_endian_little,
input  wire [31:0] bridge_addr,
input  wire        bridge_wr,  input  wire [31:0] bridge_wr_data,
input  wire        bridge_rd,  output reg  [31:0] bridge_rd_data,

// up to four controllers, key bitmaps + analog + triggers
input  wire [31:0] cont1_key, cont2_key, cont3_key, cont4_key,
input  wire [31:0] cont1_joy, cont2_joy, cont3_joy, cont4_joy,
input  wire [15:0] cont1_trig, cont2_trig, cont3_trig, cont4_trig
```

Inside `core_top` you will also wire three status signals into
`core_bridge_cmd` — these are what Analogue OS waits for:

```systemverilog
status_boot_done   = pll_locked          // FPGA is configured and alive
status_setup_done  = pll_locked          // rising edge triggers target commands
status_running     = reset_n             // core out of reset
```

Official reference: [core boot process](https://www.analogue.co/developer/docs/core-boot-process),
[bus communication](https://www.analogue.co/developer/docs/bus-communication),
[host/target commands](https://www.analogue.co/developer/docs/host-target-commands),
[core definition files](https://www.analogue.co/developer/docs/core-definition-files),
[SD folder structure](https://www.analogue.co/developer/docs/directories-and-sd-folder-structure),
[packaging](https://www.analogue.co/developer/docs/packaging-a-core).

### 3.2 Your budget

From the fitter report of a design on this device (`make report`):

| Resource | 5CEBA4F23C8 total |
|---|---|
| Logic (ALMs) | 18,480 |
| Memory bits | 3,153,920 (308 RAM blocks) |
| DSP blocks | 66 |
| PLLs | 4 |
| User pins | 224 |

For comparison the template uses 414 ALMs. A big core (SNES, Amiga) has to be
sized against this table before you start — a core that fits on a MiSTer
Arria-10 (110K–480K LE, 4–8 MB of block RAM) will **not** fit here unmodified.

### 3.3 Porting checklist

1. **Bring the RTL in, not the project.** Copy the core's RTL into
   `cores/<core>/src/fpga/core/` (e.g. `rtl/`, `ip/`) and register every file in
   `cores/<core>/src/fpga/<proj>.qsf`:

   ```tcl
   set_global_assignment -name VERILOG_FILE  core/rtl/foo.v
   set_global_assignment -name VHDR_FILE     core/rtl/pkg.vhd     ;# VHDL_ORDER matters
   set_global_assignment -name QIP_FILE      core/ip/my_ram.qip
   set_global_assignment -name SDC_FILE      core/core_constraints.sdc
   ```

   Top-level entity stays `apf_top`; `core_top` is where your design hangs off
   the APF signals.

2. **Re-target the device.** MiSTer and other boards use different Cyclone V /
   Arria 10 parts. Set (the template already has the right values):

   ```tcl
   set_global_assignment -name FAMILY "Cyclone V"
   set_global_assignment -name DEVICE 5CEBA4F23C8
   ```

   Anything Arria-10-only (`altera_a10_*` IPs, HPS, EMIF, `altera_iopll` A10
   variants, `ALTDDIO` variants not in Cyclone V) has to go.

3. **Rebuild the clocking around 74.25 MHz.** This is where most ports die.
   The Pocket gives you only `clk_74a`/`clk_74b` at 74.25 MHz; every other
   frequency must come from a PLL instantiated from the APF's
   `mf_pllbase` (Altera PLL IP under `src/fpga/core/mf_pllbase*`). Regenerate
   the PLL for your core's pixel/system clocks and audio master clock, and
   cross domains with async FIFOs. Do **not** divide the pixel clock up to the
   scaler: drive `video_rgb_clock` at the real pixel rate and use `video_skip`
   for modes that need it.

4. **Replace memory primitives.** MiSTer's Arria-10 `altmem`/`10R_*` blocks and
   huge init files must become Cyclone V M9K blocks (`altsyncram`, or the
   `dpram`/`sdpram` wrappers cores usually carry). Check the M9K budget; large
   framebuffers usually go to the PSRAM via the APF instead of block RAM.

5. **ROM loading and save states.** The Pocket has no SD card reader inside the
   FPGA: Analogue OS streams the ROM into your core over the bridge bus.
   Declare the slots in `data.json`, and either let `core_bridge_cmd.v` handle
   the standard FSDB/file commands or implement the handlers for your memory.
   Savestates work by Analogue OS reading back those same data slots.

6. **Describe the core for Analogue OS** — the JSON files at the core root:
   `core.json` (id, platform ids, framework capabilities, variant list),
   `video.json` (one `scaler_mode` per video mode: size, aspect, rotation),
   `input.json` (which controls/axes your core reads), `audio.json`,
   `data.json` (ROM slots + extensions), `interact.json` (on-screen menu
   variables), `variants.json`, `info.txt`.
   `make package` validates these (`magic: APF_VER_1`, unique variant ids,
   every declared bitstream present, every declared platform has a definition).

7. **Build early, build often:**

   ```bash
   make build CORE=mygame              # first build ~1-2h for a large core
   make report CORE=mygame             # utilisation + slack in every corner
   make build CORE=mygame NO_SIGTAP=1  # skip SignalTap when you are done debugging
   ```

8. **Fix timing before chasing bugs.** Negative slack means the design may work
   on the bench and fail in your hands. The build fails on negative slack unless
   `ALLOW_TIMING_FAIL=1`; typical fixes, in order: move logic off the critical
   path / retime, lower the PLL target, enable
   `set_global_assignment -name OPTIMIZE_MULTI_CORNER_TIMING ON`, tighten the
   SDC (false paths and multicycle paths for genuinely async logic — a missing
   `set_false_path` between async domains wastes hours), and only then consider
   the "Extra effort" / "Performance" fitter settings.

9. **Test on hardware.** JTAG the Pocket (T6 screwdriver on the back, JTAG header
   at the bottom edge; the developer edition has a door) with an Intel-approved
   Blaster. USB access from Docker needs the host devices:

   ```bash
   AP_RUN_AS=root AP_WITH_USB=1 make shell
   # inside: quartus_hps / jtagconfig, then program the .rbf (not .sof) you built
   ```
   Re-loading the bitstream over JTAG re-initialises the core with the same
   assets — that is the fast iteration loop. USB-Link mode (Tools ▸ Developer)
   mounts the microSD over USB-C for JSON tweaks (< 1 MB/s).

10. **Release:** bump `core.json` metadata (`version`, `date_release`, `url`),
    then `make package CORE=mygame RELEASE=1` and ship the zip (upstream
    convention is a zip containing `Cores/`, `Platforms/`, `Assets/`).

### 3.4 SignalTap and debug

The template ships a SignalTap `.stp` (`ENABLE_SIGNALTAP ON`). It is invaluable
when a port boots to a black screen and useless once it works — it inflates
compile time and area. Toggle it per build with `NO_SIGTAP=1`; `build.sh` edits
the QSF only for the duration of the build and always restores the original
(you will see `[build] restored original ...qsf` in the output, and `git status`
stays clean for that file).

---

## 4. Configuration

Copy `config.mk.example` to `config.mk` for per-machine defaults. Anything can
also be set per command:

```bash
make build CORE=mygame JOBS=8 NO_SIGTAP=1
ALLOW_TIMING_FAIL=1 make build CORE=mygame
AP_RUN_AS=root make shell              # for JTAG / USB work
AP_EXTRA_MOUNT=/home/me/cores:/home/me/cores make shell
```

| Variable | Meaning |
|---|---|
| `CORE` | which `cores/<name>` to work on |
| `IMAGE` / `BASE_IMAGE` | derived image tag / Quartus base image |
| `PERMS` | `1` (default) repairs the base image's root-only install so builds run as your uid; `0` for a smaller image + `AP_RUN_AS=root` |
| `JOBS` | Quartus `NUM_PARALLEL_PROCESSORS` for this build |
| `NO_SIGTAP` | disable SignalTap for this build |
| `ALLOW_TIMING_FAIL` | keep going when STA reports negative slack |
| `QUARTUS_ARGS` | extra args appended to `quartus_sh --flow compile` |
| `AP_RUN_AS` | `user` (default) or `root` |
| `AP_WITH_USB` | `1` adds `--privileged` for JTAG/USB |
| `AP_DEVICE` | device the doctor sanity-checks (default `5CEBA4F23C8`) |

### Continuous integration

The image is just a Quartus container, so community openFPGA CI recipes work
unchanged (they mount the workspace at `/build`, which is symlinked for
compatibility):

```yaml
- run: docker run --rm -v ${{ github.workspace }}:/build local/ap-pocket:quartus22.1 \
         quartus_sh --flow compile src/fpga/mygame.qpf -c default
```

---

## 5. Troubleshooting (all of these were hit for real while building this env)

* **`quartus_sh: error while loading shared libraries: libprotobuf.so.14`** when
  not root — the base image was built with a restrictive umask, so ~23k files of
  the Quartus install are root-only. Rebuild the env image with the default
  `FIX_PERMS=1` (`make image`, one-off ~4 min / ~1.1 GB) or run
  `AP_RUN_AS=root make build`, which chowns artifacts back to your uid. `make
  doctor` reports exactly this.
* **`Error (125048): Error reading ... .qsf` on the last line** — Quartus writes
  QSF files CRLF and sometimes without a trailing newline; appending an
  assignment to such a file fuses it onto the last line. `build.sh` inserts the
  missing newline; keep it in mind if you script QSF edits of your own.
* **`quartus_sh --flow compile x.qpf -s rev` fails with "Expected arguments are
  --flow <flow_name> <project_name> [-c <revision>]"** — the flow takes `-c`,
  not `-s`.
* **`Warning (292013): LogicLock is only available with a valid subscription
  license`** — Quartus Lite. Harmless unless your port relies on LogicLock
  partitions.
* **`Warning (12914): db/stp1_auto_stripped.stp is not embedded into sof`** —
  benign SignalTap bookkeeping.
* **`Warning (332060): ... was determined to be a clock but was found without an
  associated clock assignment`** — very common in ported cores; add
  `create_clock`/`derive_pll_clocks` coverage in `core_constraints.sdc`, or
  `set_false_path`/`set_clock_groups -asynchronous` if the domain really is
  asynchronous.
* **Bitstream size differs from another build of the same core** — normal: the
  same design is 787,952 bytes with Quartus 18.1 and ~787,900 with 22.1.
  `reverse_bits.py` only warns on gross deviations.
* **A core built by someone else misbehaves** — Quartus version matters for
  placement, not correctness, but PLL/IP generation is version-sensitive: if a
  published core is broken for you, try the Quartus version its author used
  (`BASE_IMAGE=` accepts any Quartus image, e.g. `raetro/quartus:21.1`).
* **Files in `cores/core-template` show as modified after a build** — that repo
  commits Quartus outputs (`ap_core.rbf`, `ap_core.jdi`, `apf/build_id.mif`).
  Your own core should gitignore them, as `.gitignore` here does.
* **`apt-get` inside the container fails** — Debian 9 is off the main mirrors;
  the env deliberately installs nothing. If you truly need a package, use
  `archive.debian.org` with `-o Acquire::Check-Valid-Until=false`.

---

## 6. Notes on the base image

`didiermalenfant/quartus:22.1-apple-silicon` is the only tag on that repository
(≈5.9 GB compressed). It contains Quartus Prime **Lite** 22.1std.2 build 922
(no licence file needed, Cyclone V supported — `make doctor` confirms the
device DB), the Nios II/Unix toolchains, `git`, `make`, `tclsh` and Python
**3.5.3**. Its entrypoint optionally runs `gh auth setup-git` (with
`GITHUB_TOKEN`) and `jtagconfig --addserver` (with `JTAG_SERVER`/`JTAG_PASSWD`);
the derived image preserves that behaviour.

Because that Python is 3.5, everything in `scripts/` is written to run on
Python 3.5 and on modern Python alike — no f-strings, no `dirs_exist_ok`, no
PEP-604 annotations. Keep it that way if you add tooling.

## 7. Licensing

The APF sources under `src/fpga/apf/` are Analogue's, licensed under their
[Pocket EULA](https://www.analogue.link/pocket-eula) — use them only to build
cores for Analogue hardware. Quartus and the device data are Intel-licensed.
The scripts in this repo are yours to do with as you please.
