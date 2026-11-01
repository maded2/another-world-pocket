# One image, one load: plan for combining the eight packs

Status: **plan, nothing implemented.** Every number below was measured on 2026-11-01 from
`ports/another-world/packs/` and the RTL in `cores/aw/src/fpga/core/`; the commands are inline so
any of it can be re-derived. Known-good baseline while this proceeds is `AW 1042`, bitstream
`579746d33d45b594`, which plays (intro + straight text).

## 1. What "load once" has to mean

Today one 2 MiB pack is loaded per launch. Playing the whole game means eight trips to the OSD data
picker, and **each pick is a full re-upload plus a core restart** (`aw_rom.v` header: "quitting and
relaunching works, and the relaunch re-uploads the pack"). The bring-up doc still lists that as a
test to perform by hand: "7. Part switching without re-flashing. Load `part1`, then `part2`, then
`part5` from the OSD."

Two separate problems hide in here, and conflating them is how this gets built twice:

* **P1 — storage/load:** hold all eight parts in the core from one upload. This plan solves this.
* **P2 — *when* to switch:** the ported engine has no concept of a part, so nothing in the game can
  ask for the next one. Verified: `vm.si` reads exactly four segment offsets from
  `mem.addr = (1<<21) - 32` (the trailer, `vm.si:363` "get part offsets from SPIflash") and never
  revisits the question. **Combining the files does not make the game continuous.** §7 keeps P2
  separate and honest.

## 2. Measured facts that decide the design

| fact | value | where it comes from |
|---|---|---|
| pack size | 2,097,136 B = 2 MiB − 16, of which body 1,681,086–1,809,536 B | `parts.env`, `packs.txt` |
| eight packs concatenated | **16.00 MiB** | `sum(len(partN))` |
| **cellular PSRAM addressable by this core** | **8 MiB** — 22-bit word address, `bit 21 = die select`, 16-bit wide | `aw_psram.v:104` `wr_addr` comment, `aw_psram.v:268` `psram_a <= req_addr[21:16]`, and agg23's reference driver `cram_a[21:16]` (`docs/pocket-dev-reference.md:217`) |
| zeros | 50–68 % of each *body* is all-zero, plus 288–416 KB of tail padding per pack | 4 KiB scan |
| positional identity | 78.7 % of 4 KiB chunks are identical at the same offset in all eight packs | same scan |
| **distinct 32 KiB frames across all eight packs** | **92 non-zero frames + 1 zero frame = 2.91 MiB** | sha1-dedup at 32 KiB |
| frames used per part | 21, 26, 26, 28, 28, 23, 31, 22 (0.66–0.97 MiB) | same |
| where parts differ | pages 0–7 (first 256 KiB) differ in **every** part, page 63 (holds the trailer), plus 0–8 extra pages for parts 0/3/4/6 | `partN` vs `part1`, 32 KiB pages |
| VM's view | fixed 2 MiB, pack offset = `mem_addr[20:0]`, trailer at `TRAILER_ADDR = 24'h1fffe0` | `aw_rom.v:194,203` |
| census cost | 11.1 sequencer cycles/word → 126 ms for 2 MiB, VM held in reset until it finishes | `aw_rom.v` census block, measured in `tb_rom` |
| upload pacing | framework pushes ≈ 1 word / 75 cycles of 74 MHz → ~0.5 s for 2 MiB, ~2.1 s for 8 MiB | APF bridge rule in `docs/pocket-dev-reference.md` |

The load-bearing coincidence: **92 frames = 2.91 MiB fits in the 8 MiB we already address**, while
the naive 16 MiB concatenation does not. Everything below follows from that.

## 3. Options, with the arithmetic

| option | image | resident | verdict |
|---|---|---|---|
| **A.** flat concat of 8 × 2 MiB, bank register selects 2 MiB | 16 MiB | needs 16 MiB | **impossible**: 2× the addressable PSRAM, and it would also break the loader's `bridge_addr[20:0]` mask and the self-test probe word at `22'h100000` |
| **B. paged frame pool + per-part page table** | **2.92 MiB** | 2.91 MiB | **recommended.** VM keeps its exact 2 MiB view; PSRAM grows 2 → 3 MiB; upload grows 2 MiB → 2.92 MiB once instead of 2 MiB ×8 |
| C. keep 8 dataslots, all uploaded at boot | 16 MiB | 16 MiB | impossible (same 8 MiB wall), and eight file picks is not "load once" |
| D. compress / RLE + inflate during load | ~1 MiB? | 16 MiB inflated | rejected: the inflate destination is the problem, not the file; also destroys the property that makes the bench work (VM address → pack byte is a pure function). Paging gets the same byte saving with zero codecs and keeps that property exactly |
| E. four parts only, flat (4 × 2 MiB = 8 MiB) | 8 MiB | 8 MiB | fits, but ships a partial game, costs the whole 8 MiB, and still needs 2 extra PSRAM address bits. Only worth revisiting if B's page lookup fails STA |

## 4. Recommended design (B)

### 4.1 Image format — `aw-all.bin`, directory at the end, mirroring today's trailer

```
offset 0x00000 : frame 0     \ 92 non-zero frames, 32 KiB each, in builder order
               : ...         /  frame index = (offset) / 32768
offset 0x2E0000: zero frame (32 KiB of 0x00)   <- every zero page points here
               : directory:
                 magic 'AWP1', version, frame_count, whole-image word sum
                 8 × [ page_table[64] (uint16 frame idx), view word sum, expected Z string ]
               : 16-byte trailer, so `TRAILER_ADDR` of the *selected view* still lands on that
                 part's own four segment offsets (it is data, not a special case)
```

* The builder is content-addressed: `frame_of(page)` for each part, deduplicated by sha1; zero
  pages collapse to the single zero frame (that is where the 50–68 % zero content goes).
* **The acceptance test is in software and needs no simulator:** reassembling page table *N* must
  reproduce `partN.bin` **byte for byte**, all eight parts, trailer included. If that passes, the
  core's view is bit-identical to what 1042 reads today — and every oracle, checksum and reference
  comparison we already have stays valid.
* Directory at the end, not the front, so `frame_index = offset / 32768` with no header skew.

### 4.2 Core changes, smallest first

1. **Loader width.** `aw_rom.v:230` masks `bridge_addr[20:0]` — a 2 MiB window. Widen to
   `bridge_addr[23:0]` (16 MiB window, so the format never outgrows it) and derive the PSRAM word
   from the byte address. This alone is what lets a bigger file in.
2. **Page table**: 64 × 8-bit RAM (one M10K, initialised from the directory after upload) + the
   mapping `psram_word = {frame[6:0], pack_word[13:0]}`, where `pack_word = pack_byte[20:1]` and
   the table index is `pack_word[19:14]`. 21 bits — **fits one die, no `aw_psram` address change.**
3. **Page-crossing stall, not a lookup in the chip path.** The stream producer walks sequentially
   (`p_addr`, `start_addr_r`), so the frame only changes once every 16,384 words. Hold
   `frame_cur` in a register, and on `pack_word[13:0] == 0` take **one** stall cycle to fetch the
   next frame. With `FETCH_HEADROOM = 7` and `LOOKAHEAD = 40` words, one stall per 16 Ki words is
   invisible. This is a deliberate timing decision: worst slack is **+0.135 ns**, and the address
   path out to `cram0` is exactly where 1039a lost 4 paths at −0.385 ns (documented at
   `aw_rom.v` "Registered, and that is the whole point of the flop"). An M10K read inserted between
   `p_addr` and `aw_psram`'s `take` is the same class of mistake.
4. **Move the self-test probe word.** `ST_ADDR_D0 = 22'h100000` is "first word past the pack" and
   the A5A5/5A5A probes **write** there. With a 2.91 MiB pool that address is inside frame 128's
   territory: the self-test would scribble on game data. Relocate to a cell above the pool (die 1,
   e.g. `22'h3F_FFFF`) and make the census/self-test read paths go through the same frame map or
   explicitly bypass it — they address *physical* PSRAM, the producer addresses *views*.
5. **Census over the pool, once.** 1.5 Mi words ≈ 17 M cycles ≈ 180 ms (vs 126 ms) — still behind
   `rom_ready`, and `CEN_QSHIFT`'s quarter slicing must be recomputed for the new range (that
   logic has already been wrong once for exactly this reason; see the `CEN_QSHIFT+1 +: 2` note in
   `aw_rom.v`). Expected sums come from the directory, so `Z` keeps meaning "the chip holds what was
   sent" — with the caveat in §6 that `hardware-bringup.md`'s `dd744c92` is a *per-pack* sum and
   stops being the number to expect.
6. **Part select + switch.** A 3-bit `part_sel`, a table-load FSM (256 words from the directory,
   ~2 µs), **bump the read generation** so nothing from the old part survives in the stream FIFO or
   in flight — that machinery already exists for exactly this purpose ("the consumer discards
   anything not tagged current") — then pulse the core reset so the VM re-reads the trailer through
   the new table. Order matters and is checkable: table loaded *before* generation bump *before*
   reset release.
7. **Selection source.** Two candidates, and the difference is a hardware unknown, not a preference:
   * `interact.json` variable (`"Part"`, 0–7) → bridge parameter write. Nicest UX, but unverified:
     does the framework push variables to a Chip32 core without touching the dataslot, and what
     exactly happens during the OSD visit — telemetry shows the core going to `inmenu=1` and the
     UART falling silent, which we have never explained. PSRAM is async with **no refresh**
     (`aw_psram.v:6`), so contents survive a clock pause; our loader/sequencer state is the question.
   * **Gamepad combo handled in the core** (e.g. Select+Start held 2 s → next part). No framework
     dependency at all, works mid-scene, and `aw_keys.v` already decodes the pad. Ugly UX, but it
     retires an unknown, so build this first and add the OSD variable when the behaviour is measured.
8. **Telemetry.** Add the active table index and directory-valid flag to `MID_CHK`, and bump
   `MSG_UP` while in there — it has been hardcoded `"AW 1041a up\n"` since 1041 and prints that for
   every build, which already caused a false accusation against a good install this month. Still
   ≤ 12 chars, so no `msg_len`/`pos` churn. Also worth adding now for a different reason: with one
   image there is finally something to report that the old line could not — which part the view is
   showing.

### 4.3 Boot and switch sequences

```
upload 2.92 MiB → infer completion (existing: writes reached trailer area, then quiet)
  → census pool, compare to directory sums   → Z. / Z! + quarters
  → read directory, check magic+version      → refuse to run and report if it disagrees
  → load page table for part_sel             → hold reset
  → release reset: VM reads trailer at 0x1FFFE0 through the table, boots that part

switch: latch new part_sel → load table → generation++ → pulse core reset → boots new part
        (no upload, no OSD, ~2 µs of table + the VM's own boot)
```

## 5. Verification, in the order that catches things cheapest

1. **Builder self-test (no simulator, seconds).** For all 8 parts: reassemble from directory →
   compare to `partN.bin` byte for byte. This is the whole idea, tested before any RTL. Negative
   control: perturb one table entry and confirm the test fails, so it is a real check and not a
   tautology.
2. **`tb_rom`**: upload the 2.92 MiB file (exercises the widened loader), then switch tables
   mid-stream and assert no byte from the previous part lands after the switch — the generation
   path, which is where this design could silently corrupt a stream. Reuse the forced-`STALL`
   stimulus (`STALL=64`) so a switch lands inside held acceptances, and keep the fill-buffer
   landing oracle pointed at the reassembled view.
3. **`tb_soc`, all 8 parts, per-pack verdicts unchanged** (`kind=text` for part0, `rich` for the
   rest — and both branches were already shown able to fail by grading each pack the other way).
   `ref_mem` becomes the reassembled view of the selected part, so the existing byte-exact and
   fill-landing oracles need no semantic change. Compare golden frames against a 1042 run of the
   same part: same pictures, or the paging changed behaviour.
4. **Long runs, not short ones.** part1 clean for **600+ frames**: the short runs are the reason
   this bug survived weeks (a 115-frame part1 shows 0 restarts; at 655 frames it takes 31, and the
   1041-policy control froze at frame 553 with no stimulus at all). Any A/B of this work runs long.
5. **Build + scoped audit**: `make build CORE_DIR=cores/aw`, then
   `make check-build CORE_DIR=cores/aw` (unscoped audits the template and cries wolf). Watch worst
   slack against +0.135 ns and the `cram0` output paths specifically; the dead-logic check is the
   tripwire if a page table gets optimised away unread.
6. **Hardware gate, in this order**: upload once and confirm the new `Z` sums against the builder's
   directory (not `dd744c92`); switch through all 8 parts and confirm each matches what that pack
   did on 1042; time the single upload against the eight it replaces. New identity, hash recorded,
   1042 kept as the control — the controls being off the card now means a comparison costs a
   reinstall (`scripts/sd_install_1042a.sh` and friends), so plan the run to capture both in one
   session.

## 6. Risks and open questions, not smoothed over

* **Framework dataslot size limit is unverified.** `parameters: "0x109"` is "bitfield, undocumented
  … copied, not derived" (`pocket-metadata.md:74`), so nothing declares a size and we have never
  uploaded more than 2 MiB. 2.92 MiB is only 46 % more, but if the framework refuses or truncates,
  option B dies the same way A does. **First hardware question, cheap to answer with a padded file.**
* **Directory/image mismatch is a new failure mode with the same symptom as the bug we just fixed**
  (a VM executing the wrong data → animated garbage or a black screen). The builder's hash must be
  checked at boot and a mismatch reported, never booted through.
* **OSD variable semantics are unmeasured** (§4.2.7). Do not design the UX around them before one
  hardware run says what happens to the core and the dataslot across an OSD visit.
* **P2 is still unsolved.** Nothing switches parts automatically, because nothing in the engine
  asks. Before building anything for it: find out what the reference does at the end of a part
  (`scripts/ref_sim.sh PART=...`, and the upstream extractor for a part-change command). If the
  engine simply idles with no live threads, a core-side "all threads dead for N s → advance" is
  possible but is a heuristic, and heuristics that boot the next chapter deserve their own evidence
  trail, not a plausible story.
* **Census grows to ~180 ms**, and it gates `rom_ready`. Fine, but it is boot latency, and quarter
  slicing must be recomputed for the new range or we lose the "which quarter went bad" half again.
* **Docs that go stale the day this lands:** `hardware-bringup.md` §7 ("part switching without
  re-flashing" is now a variable, not a file pick) and every `dd744c92` expectation; `interact.json`
  gains its first variable; `core.json`'s description ("game data loaded through the dataslot")
  needs the one-sentence version of this scheme.
* **Effort estimates are guesses with a direction**: builder + software test, a day; RTL
  (loader width, table, page-crossing stall, probe relocation, switch FSM), a few days including
  `tb_rom`/`tb_soc` bring-up; hardware gate, one session with the card. The unknown with real
  leverage on that is §'s first bullet — the framework's willingness to upload 3 MiB.

## 7. Sequencing

1. **Spike (no RTL):** builder + byte-exact reassembly for all 8 parts + the negative control. If
   that is not green in an hour's work, the design is wrong and it costs an hour to know.
2. Probe the framework question with a padded 3 MiB dummy image on the existing core (only the
   loader mask changes): does it upload fully, does `Z` agree with the builder.
3. `tb_rom` paging + switch-under-stall.
4. `tb_soc` all 8 parts, long runs, golden-frame A/B against 1042.
5. Hardware gate; ship as its own identity, keep 1042.
6. **Then** P2 (switch trigger), as its own plan with its own evidence — informed by what the
   reference simulator says about end-of-part.
