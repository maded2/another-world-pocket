# Hardware bring-up kit

Written now, executed on a device. This is the list to run the first time the bitstream goes on a
card, in order, with what each step proves and what its failure means.

`scripts/hw-bringup.sh` prints this sequence with a worksheet to fill in.

## What is already established (so you know what you are testing)

| established | how | on hardware? |
|---|---|---|
| pack bytes are what the producer makes | two independent extractions byte-identical | no |
| segment offsets | trailer values match the golden reference sim | no |
| palette bytes | 16/16 RGB565 words vs pack | no |
| page arbitration | generated netlist shape equals upstream | no |
| pad reaches the VM's own variables | `make sim-soc` (7/7 patterns) | no |
| `cont1_key` bit numbers | Analogue's bus-communication docs | no |
| pad mapping code | `make sim-keys` (13 checks, mutant fails 7) | no |
| sustained load, timing closure | sim at pace 10; STA +2.5 ns | **no — this is the big one** |

The unknowns that can stop the core working are: the real bridge write rate, loader/VM contention on
`cram0`, and whether the scaler/OSD accept what we generate. None of them can be simulated honestly.

## Root causes found on hardware (do not regress these)

**1. Missing Chip32 VM loader (2026-10-15).** The OS's "File: Load ... Slot: load done" only stages
the file in *host* memory; the bytes cross the bridge only when a declared
`core.framework.chip32_vm` program calls `loadf`. Ours declared none, so every "successful" load
moved zero bytes (debug grid: `wr_match=0`, total bridge writes < 65536 = command traffic only).
Fix: `cores/aw/support/loader.asm` → `loader.bin` (`make loader`), declared in `core.json`, copied
by the packager. The PSRAM protocol was never at fault here.

**2. Load path held in reset during the load (2026-10-17).** With the loader in place, the boot log
showed the full sequence: `CORE` → bitstream, `LOADF` → "File: LOADF Long Start", *then* Run →
**Reset Exit**. The OS streams the pack while still holding the core in reset. But
`rst_bridge = ~reset_n | ~pll_locked`, so bridge acceptance, the FIFO, the drain and the debug
counters were all in reset for the entire transfer - every byte discarded, same red screen.
The known-good SNES `data_loader` has no reset input at all for exactly this reason. Fix:
`aw_reset_gen.v` - the load path resets on PLL lock only; `reset_n` gates the game
(`design_run`) and nothing else. `tb_reset_gen` pins the ordering down.

## Screen legend (the core already reports its own state)

Before `rom_ready`, the core drives the same 825×500 timing as the game and shows one of four things
(`core_top.v`, placeholder block). Learn these first — they turn a blank screen into an answer.

| on screen | meaning | first thing to check |
|---|---|---|
| **black, no sync** | core not running at all | bitstream/zip layout, core selected, platform id match |
| **white blinking block, centre** | alive, waiting for a pack | data slot wiring, `data.json` slot address, did the OSD load a file |
| **red** | `ERR_TRAILER` — the offsets at `len−16` are not a pack | wrong/renamed file, truncated copy, `size` smaller than 2 MiB−16 |
| **purple** | `ERR_OVERFLOW` — bridge wrote faster than the chip accepted | `cram0` timing/contention; see symptom table below |
| **amber** | `ERR_WAIT` — no longer reachable in this build: WAIT is not read and the chip's CLK pin is held low (async mode, see below) | if it ever appears again, the bitstream on the card is not the one you think it is |
| intro picture | loaded, booted, rendering | — |

**Expected one-time glitch:** the frame that straddles the idle→game mux switch may contain one
blank line (the switch suppresses the game side of its own line so the transition line carries a
legal DE count — see the 2026-10-25 port-log entry). It happens once, at boot, and is not a bug.

**PSRAM protocol (what this build assumes about the chip):** async mode — `cram0_clk` held low,
`cram0_wait` never read. The fitted part idles WAIT high and its known-good neighbours ignore it;
two amber runs (2026-10-10/11) came from treating it as a handshake. The access sequence is timed
on the PLL's 82.5 MHz output in `aw_psram.v` (6 cycles = 72.7 ns per access, matching the
datasheet's ~70 ns budgets). Writes chain back-to-back on their release edge (the part never
drives DQ during a write) so the drain sustains ~27.5 MB/s — above the pace-10 model load of
24.75 MB/s with margin. Reads do NOT chain: every read parks one idle cycle after cleanup,
matching the reference's gap between all accesses, which is what lets the part finish releasing
DQ (tOE) before the next address appears. That costs one cycle per read (84.9 ns/word, just over
the reader's 80.8 ns budget); the reader's late-handoff/seek path absorbs it.

**The red screen is a debugger.** On ERR_TRAILER it renders the sixteen bytes the last trailer
check read back as a bit grid (one column per byte, top bit = MSB; columns left→right are
chk_data[7:0] … [127:120], so the first four columns are offset 0). A constant pattern
everywhere means the chip never answered (DQ floating); a pattern that changes between the ~84 ms
retries means marginal timing; plausible-but-wrong offsets mean address corruption. If the chip
does not respond at all, suspect pin assignments (`cram0_clk` G10, `cram0_wait` K7), the
async-mode assumption itself (try driving `psram_clk` from `clk_psram` — one-line change in
`aw_psram.v`), or the CE# die-select mapping.

**Pack integrity, from 1040a: the `Z` field on the CHK line.** The two counters that used to
prove the upload (`wr_match`/`wr_all`) count *addresses seen in range*, not data that reached the
chip, and until 1040a the only read-backs in 2 MiB were word 0 (`P`) and the trailer (`C0`). The
core now sums every 16-bit word as it commits it, reads the same range back once (~126 ms, VM in
reset) and sums again, and prints `Z<flag> <quarter> <read_sum>/<written_sum>` at the end of the
line. For part1.bin both sums should read **`dd744c92`** — that is the file's own word sum, so
`Z.0 dd744c92/dd744c92` is the statement "the 2 MiB in the chip is the 2 MiB that was sent", and
nothing below it needs to be re-examined. `!` plus the quarter mask names a 512 KiB range (word
bits [19:18]); `T` is a stalled sweep (suspect the read path, not the pack); `P` means no upload
completed, so read the `C`/`S` fields instead. Full legend and the per-part sums:
`scripts/sd_install_1040a.sh`.

Error codes are sticky once latched, so a colour that appears briefly and is then replaced by the
game is still a real event worth writing down.

## Debug channels beyond the screen

The screen legend answers "what state is the core in". These answer "where exactly".

**1. Debug-key UART console (devkit only).** The core logs short lines at 115200 8N1 on the
cartridge bus: TX on pin 3 (`cart_tran_bank0[6]`), activity LED on pin 4 (`bank0[5]`) — the
wiring of the Analogue devkit debug key (agg23/analogue-pocket-utils, `debug_key.v`). Lines:
core up, pack loaded, ROM error codes, menu in/out. It needs cart power, which is why
`core.json` carries `cartridge_adapter: 0`; a core without the dev key pays a little idle
power for that flag, and we keep it because this console is the difference between "no sync at
all" and "alive, waiting, here is why" when the screen gives no answer. If you have the
devkit, capture it (`scripts/capture_serial.py` exists for the breakout; the key's SI2104 is a
plain USB-UART at 300 bps–2 Mbps) and read the log before touching anything else.

**2. SignalTap.** A session already lives in the core (`src/fpga/core/stp1.stp`, instance
`auto_signaltap_2`); it needs an Intel-approved USB Blaster (Terasic P0302 works). Two things
from the community wiki that matter for this core specifically:
* *Tools → Developer → **Pause Core Boot*** halts boot until a button press, and ***Pause Data
  Load*** halts data-slot loading. Our boot order streams the pack while the core is still held
  in reset (root cause #2 above), so anything you want to catch on the load path — bridge
  acceptance, FIFO levels, the drain FSM, `rom_error` before it latches — is only catchable
  with one of these pauses armed. Without them the interesting part happens in the first second.
* Multiple debugger instances can be saved in one design; and changing *which nets trigger*
  (not the AND/OR mode) does not require a recompile, so iterate on triggers between flashes.

**3. If no core produces any video.** Our stream cannot put vsync inside hsync (sim-enforced:
vs at x=0, hs at x=3, one cycle each), but older arcade cores have done exactly that and on
current firmware it hard-crashes the scaler so badly that *no* core shows video afterwards.
If after a failure even known-good cores are black: fully restart the Pocket (power cycle),
then re-test. Do not spend an evening on our bitstream first.

## Bring-up sequence

**1. Does it appear and sync.** Copy `build/sd/aw/*` to the SD root (merge, do not replace). Select
the core.
*Expect:* the white blinking block, stable, no rolling.
*Proves:* bitstream loads, PLL locks, the video pins and `video.json` agree well enough to sync.
*If not:* nothing below is reachable. Check the zip layout (`Cores/Eddie Chan.Another World/` — folder must match author.shortname in core.json exactly, spaces included), then
`video.json`'s single 320×200 scaler mode.

**2. Load `part1.bin` (the intro) and time it.** Use the OSD data-slot pick. Start timing when you
confirm the file, stop at the first game picture. **Do not test with part0**: its content is only
the opening credits ("IBM PC VERSION / BY / DANIEL MORAIS" on black), after which the VM idles -
and on hardware it has been observed rendering a white screen with dark blocky glyphs that matches
no reference frame (2026-10-17, unexplained; see the root-causes section). part1 is the real test:
the golden reference (`make ref-sim PART=.../part1.bin`) shows the hero in a doorway at ~1 min and
the green "I see you have driven here in your Ferrari" / IDENTIFICATION scene at ~2 min.
*Expect:* intro within a couple of seconds; definitely under the declared `timeout_ms` 30000.
*Proves:* the bridge, the `0180 Data slot read` path, `cram0` writes at real rates, the boot check,
and the trailer, all on hardware.
*Record:* wall seconds → effective rate = 2 MiB ÷ t. **This is the number task #18 was gated on.**
If it is far slower than the modelled pace-10 load, the byte-stream reader's prefill is the suspect;
if it aborts near 30 s, raise `timeout_ms` and note the real requirement.
*If red/purple/amber:* see the legend and the contention table.

**3. Does the intro play through.** Watch to the end of the sequence.
*Proves:* sustained VM+bridge coexistence on `cram0` — the loader and the reader competing on one
chip — and the palette/page paths.
*Failure shapes:* freezes at a fixed point → note the frame and whether it is deterministic (a
deterministic stop is a data/protocol bug; a drifting one is timing); colours wrong → palette bank,
compare a screenshot with `build/sim/soc-frames/` from `make sim-soc`.

**4. Input — the regression this kit exists for.** Get to a scene with a controllable hero, then:

| press | expect | if instead |
|---|---|---|
| d-pad ← → | hero walks | nothing → `AW_KEY_LEFT/RIGHT` wrong for this firmware |
| d-pad ↑ ↓ | hero moves diagonally per the game's isometric mapping | fires → the fire bit is landing on the d-pad (the exact bug fixed in `25fd5ee`) |
| A **and** B | action fires both | only one → the A/B OR is not what you think |
| **START** | pause/game menu — **hero must not move** | hero walks → START is being read as a direction |
| **SELECT** | nothing in-game | hero moves → same class of bug |

Bits come from Analogue's bus-communication docs (`[0] up [1] down [2] left [3] right [4] A [5] B`),
and `make sim-keys` verifies our mapping against them, so a mismatch here means the *word* differs
from the docs (firmware change?) rather than our code: fix with `-D AW_KEY_UP=…` etc., do not touch
the packing. Record what you observed either way — this table is the hardware half of a path that
simulation can only half-cover.

**5. Soak.** Leave the intro looping, or leave a scene running, for 15+ minutes handheld and docked.
*Proves:* no slow drift, no thermal/timing edge, no PSRAM refresh issue.
*Watch for:* colour shifts, progressive artefacts, freeze at a time-dependent point.

**6. Docked output and suspend.** `dock.supported: true`, `analog_output: false`,
`sleep_supported: false`.
*Expect:* HDMI output mirrors, no analogue claim; suspending and waking does not wedge the core (with
`sleep_supported: false` the OS should fully restart it — verify it comes back to the screen legend,
not a frozen frame).

**7. Part switching without re-flashing.** Load `part1`, then `part2`, then `part5` from the OSD.
*Proves:* the one-bitstream decision (part is data, offsets come from the pack trailer) on hardware,
which is what that decision was made on reasoning alone.
*Note:* `part0.bin` is the copy-protection screen and is near-black **by design** — it is not a fault,
and the reference simulator is equally dark.

**8. Save states.** `savestate_supported: false`. Confirm the OSD does not offer save-state and that
nothing tries to use it.

## `cram0` contention symptom table

| symptom | reading | action |
|---|---|---|
| purple screen during load | bridge outran the drain: the FIFO filled because the chip accepted slower than the model assumes | the drain is 26.8 MB/s by construction (145.5 ns per word); if the real chip needs more than that per access, the protocol in `aw_psram.v` is too fast for it — add cycles to the write window and re-sim |
| load OK, then stutter during play | VM reads competing with remaining bridge writes | measure how long the bridge stays active; this is the case task #18 (direct random access instead of the byte stream) was deferred for lack of |
| load OK then hang at a fixed frame | VM waiting on data that never arrives | deterministic → data/protocol; capture the frame number and compare to sim |
| hang at varying frames | marginal timing | re-check STA corners, then reduce `cram0` clock or add margin |
| (amber is unreachable now) | — | see the protocol note in the screen legend |

## Telling loader starvation from a VM hang

- Loader/chip problem: the core is still on the **placeholder** (white block or one of the three
  error colours) and `rom_ready` never rises.
- VM problem: the **game** screen is up (so the pack verified) and holds the last rendered frame.
- In simulation the same distinction is available as `starving=` in `make sim-soc` output and the
  `rom_error` codes; on device the placeholder colour is the equivalent signal.

## What to report back

1. Seconds from file confirm to first picture, for `part1`.
2. Screen colour for any failure, with what you loaded.
3. The input table, ticked — including whether START moves the hero.
4. Soak result and whether docked differs.
5. Whether parts 2 and 5 load on the same bitstream.

Those five answers close, or properly open, tasks #18 and #29's remaining assumptions.
