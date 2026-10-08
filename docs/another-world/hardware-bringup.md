# Hardware bring-up kit

Written now, executed on a device. Everything currently green is Verilator plus a Quartus compile;
**no result in this project has ever been observed on a Pocket.** This is the list to run the first
time the bitstream goes on a card, in order, with what each step proves and what its failure means.

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

## Screen legend (the core already reports its own state)

Before `rom_ready`, the core drives the same 825×500 timing as the game and shows one of four things
(`core_top.v`, placeholder block). Learn these first — they turn a blank screen into an answer.

| on screen | meaning | first thing to check |
|---|---|---|
| **black, no sync** | core not running at all | bitstream/zip layout, core selected, platform id match |
| **white blinking block, centre** | alive, waiting for a pack | data slot wiring, `data.json` slot address, did the OSD load a file |
| **red** | `ERR_TRAILER` — the offsets at `len−16` are not a pack | wrong/renamed file, truncated copy, `size` smaller than 2 MiB−16 |
| **purple** | `ERR_OVERFLOW` — bridge wrote faster than the chip accepted | `cram0` timing/contention; see symptom table below |
| **amber** | `ERR_WAIT` — the chip never accepted anything | PSRAM clocking/WAIT path; nothing downstream can work |
| intro picture | loaded, booted, rendering | — |

Error codes are sticky once latched, so a colour that appears briefly and is then replaced by the
game is still a real event worth writing down.

## Bring-up sequence

**1. Does it appear and sync.** Copy `build/sd/aw/*` to the SD root (merge, do not replace). Select
the core.
*Expect:* the white blinking block, stable, no rolling.
*Proves:* bitstream loads, PLL locks, the video pins and `video.json` agree well enough to sync.
*If not:* nothing below is reachable. Check the zip layout (`Cores/EddieChan.AnotherWorld/`), then
`video.json`'s single 320×200 scaler mode.

**2. Load `part1.bin` (the intro) and time it.** Use the OSD data-slot pick. Start timing when you
confirm the file, stop at the first game picture.
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
| purple screen during load | bridge outran the chip: write pulses arriving with `WAIT` not honoured at real speed | check `cram0` timing constraints and the WAIT handling; note the pace at which it appears |
| load OK, then stutter during play | VM reads competing with remaining bridge writes | measure how long the bridge stays active; this is the case task #18 (direct random access instead of the byte stream) was deferred for lack of |
| load OK then hang at a fixed frame | VM waiting on data that never arrives | deterministic → data/protocol; capture the frame number and compare to sim |
| hang at varying frames | marginal timing | re-check STA corners, then reduce `cram0` clock or add margin |
| amber from power-on | PSRAM WAIT path never released | clock plan, not the loader |

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
