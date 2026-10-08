# Pocket metadata: what is verified, what is believed

Every field this core declares, with where the claim comes from. Written because several of these
were load-bearing beliefs, and one of them — the controller word — was wrong in a way that no
simulation in the project could see.

Verification method, reproducible:

```sh
curl -sS -o /tmp/bus-communication.html https://www.analogue.co/developer/docs/bus-communication
curl -sS -o /tmp/openfpga.html           https://www.analogue.co/developer/docs/openfpga
curl -sS -o /tmp/core-definition-files.html https://www.analogue.co/developer/docs/core-definition-files
curl -sS -o /tmp/api.html                https://www.analogue.co/developer/docs/api
curl -sS -o /tmp/platform.html           https://www.analogue.co/developer/docs/platform
```

Fetched 2026-10-04. "Not specified on these pages" below means the literal term does not appear in
any of them (`grep -c` returns 0), not "I could not find it".

## 1. `cont1_key` — VERIFIED against the official spec (and our mapping was wrong)

From the **Bus Communication** page, the controller word each `contN_key` carries:

| bit | function | bit | function | bit | function |
|---|---|---|---|---|---|
| 0 | `dpad_up` | 5 | `face_b` | 10 | `trig_l2` |
| 1 | `dpad_down` | 6 | `face_x` | 11 | `trig_r2` |
| 2 | `dpad_left` | 7 | `face_y` | 12 | `trig_l3` |
| 3 | `dpad_right` | 8 | `trig_l1` | 13 | `trig_r3` |
| 4 | `face_a` | 9 | `trig_r1` | 14 | `face_select` |
| | | | | 15 | `face_start` |

`cores/aw/src/fpga/core/aw_keys.v` now maps those to the packing `vm.si` reads
(`[0] right [1] left [2] up [3] down [4] fire`), with `AW_KEY_*` overridable by `-D`.

**What was there before:** `RIGHT=12 LEFT=13 DOWN=14 UP=15 B=0 A=8` — the numbering from APF-era
community examples. Against the spec those are `trig_l3`, `trig_r3`, `face_select`, `face_start`,
`dpad_up`, `trig_l1`. On a real Pocket the d-pad would have done nothing, **START would have walked
the hero** (it was read as `AW_KEY_UP`), SELECT as down, and the d-pad's up would have fired.
Separately the packing put `RIGHT` in bit 4 and `FIRE` in bit 0 while `vm.si` reads bit 4 as fire
and bit 0 as right — a second, independent swap.

Why simulation missed it: `tb_soc` drives the SoC's `jstick` port directly and never passes through
this mapping. Fixed by extracting the mapping into a module and testing that module:

```sh
make sim-keys      # scripts/sim_keys.sh -> tb_keys.sv
```

13 checks: each d-pad direction, both face buttons as fire, combinations, all six held,
start/select and shoulders/sticks producing **nothing**, and the 3-deep synchroniser depth.
Negative control: restoring the old bit numbers fails 7 of 13 and exits non-zero.

## 2. Data slots — mechanism documented, **field-level schema not specified**

The **openFPGA** page documents the concept and the protocol: a core can have up to 32 associated
assets, each with a unique 16-bit ID abstracting physical from logical slot order, and the core
requests data with the target command `0180 Data slot read`, to which the Pocket replies with the
requested bytes. That is the mechanism our bridge serves.

What the official pages do **not** define is `data.json`'s field list. `data_slots`, `onlaunch`,
`ways`, `savestate_supported` and `filename` appear nowhere on the five pages above, and the vendored
core-template ships `"data_slots": []` with no schema. So these are **believed** (community practice,
as implemented by released cores):

| field | we set | if wrong |
|---|---|---|
| `address` | `10000000` | the bridge window the core is mapped at; wrong value = no data ever arrives (core sits on the "waiting for pack" screen) |
| `size` | `00200000` (2 MiB) | packs are 2 MiB − 16 B; a slot smaller than the file truncates, and the trailer at `len−16` would be missing → boot check fails |
| `ways` | `1` | RAM-style slot geometry; ours is read-only data |
| `extensions` | `["bin"]` | OSD greys the file out |
| `filename` | `{osd_origin}/{osd_filename}` | where the picked file is remembered from |
| `onlaunch.priority/address/timeout_ms` | `1 / 10000000 / 30000` | the auto-load-on-boot path; a too-short timeout aborts a slow load |
| `savestate_supported` | `false` | honest: our design has no save-state |

**First hardware action** (see the bring-up kit): confirm the slot loads at all, then confirm the
`0180` command stream our core answers matches what the OS sends.

## 3. `core.json` — fields not specified on these pages either

We declare `magic APF_VER_1`, `platform_ids ["anotherworld"]`, `shortname`, `description`, `author`,
`url`, `version 0.1.0`, `date_release`, `framework.target_product "Analogue Pocket"`,
`version_required "1.1"`, `sleep_supported false`, `dock.supported true` / `analog_output false`,
`link_port false`, `cartridge_adapter -1`, and one core `default` id 0 → `bitstream.rbf_r`.
None of these literals appear in the fetched pages; they follow the vendored template, which is
itself the strongest local authority. `sleep_supported: false` matters most — claiming sleep without
implementing it is how a core bricks a suspend cycle.

`metadata.url` currently points at <https://github.com/sylefeb/a5k>. This repo has **no remote**, so
there is no URL of ours to put there, and the honest content today is attribution for the engine:
this core runs a port of sylefeb's Silice implementation. Decision: keep the attribution until a
remote exists, then set it to our repo and keep crediting upstream in `info.txt`.

## 4. `video.json` — believed

One scaler mode: 320×200, aspect 4:3, rotation 0, mirror 0. The design generates 825×500 with
320×200 active (verified in simulation: frames are captured at 320×200 from the video pins). What is
*not* verified is how the Pocket's scaler treats it — whether it honours 4:3 letterboxing on the
480×320 panel at 3× and whether the 59.94 vs 60 Hz difference matters to the OSD.

## 5. `input.json` — empty list, believed

`controllers: []` is taken to mean "default pad, auto-mapped". Our RTL only reads `cont1_key`, so
player 2 and any alternate mapping are simply unused — Another World is single player. The bit
positions themselves are no longer a guess: see §1.
