# Sound effects and music: what the data is, and how to get it out of the Pocket

Status: **sound effects and the music tracker are implemented, verified in simulation, BUILT and PROVEN
ON HARDWARE (effects since AW 1050; the tracker since AW 1062, whose capture shows 282 rows, 90 notes and
the oracle's rate increment).** The phase-G acceptance is half met: event-for-event is done, sample-for-sample
against the Python render is not. Widening the harvest (loops, modules 137/138) is still open.
Every number below was measured from `gamedata/memlist.bin`, the pinned upstream sources in
`ports/another-world/upstream/BUILD/Another-World-Bytecode-Interpreter/src/`, or the benches named next to it.

What is DONE (commits `cee7c9c` and after): A extraction, B packaging, C index + sample fetch in RTL, D VM
patch, E mixer, F I2S output, G the RTL music tracker, H the hardware gate (a sound effect and a music cue on
the Pocket). Six benches run under `make sim-audio` and `tb_top`/`tb_soc` exercise the chain inside the core.
What is NOT done: the sample-for-sample half of G, a harvest wide enough to exercise loops and modules
137/138, and the docs pass that this file is part of (updated 2026-11-11; still stale below where it says
"no audio").

## 1. The data

`memlist.bin` holds 146 directory entries; each names a bank file, an offset, a packed size and an
unpacked size (`MemEntry`, `resource.h:34`). Summed by resource type:

| type | id | entries | packed | unpacked |
|---|---|---|---|---|
| `RT_SOUND` | 0 | **103** | 585,052 B | **699,868 B** |
| `RT_MUSIC` | 1 | **3** | 3,540 B | **33,344 B** |
| `RT_POLY_ANIM` | 2 | 12 | 106,676 B | 384,000 B |
| `RT_PALETTE` | 3 | 9 | 11,032 B | 18,432 B |
| `RT_BYTECODE` | 4 | 9 | 136,933 B | 203,546 B |
| `RT_POLY_CINEMATIC` | 5 | 9 | 291,008 B | 365,960 B |
| (untyped) | 6 | 1 | 18,864 B | 25,108 B |

**Audio is 733,212 B = 0.70 MiB.** The packs the core loads today carry palette / code / cinematic /
video2 only (`scripts/extract_packs.sh` header) - no audio at all, which is why a pack plays silently.

Resources are **compressed** in the 13 `bankNN` files whenever `packedSize != size`: `Bank::read`
(`bank.cpp:28`) reads `packedSize` bytes and calls `unpack()` (the Chahi LZ). Unpacked entries are read
straight through. Any extractor must therefore run the same unpacker, not `dd` a byte range.

## 2. Sound effects

`op_playSound` (`vm.cpp:387`): `u16 resourceId`, `u8 freq`, `u8 vol`, `u8 channel`.

* Data at `bufPtr + 8`. Header is `u16 loop_start`, `u16 loop_len` (both in units of 2 bytes), then 4 pad
  bytes (`vm.cpp:763-766`). **Measured, not guessed**: the playable payload is `loop_start + loop_len`, and
  `8 + 2*(h0 + h1)` equals the resource size for **96 of the 102 non-empty sounds exactly**; 6 are empty
  (size 0) and one (res 4) carries 2 bytes beyond its declared payload. That matches how the mixer uses
  the pair - `mc.loopPos = h0*2`, `mc.loopLen = h1*2`, so playback runs 0..loopPos+loopLen and repeats the
  tail - and it replaces an earlier reading of the first field as a total length, which the data
  contradicts for 6 of the first 10 resources checked.
* **11 of the sounds loop** (`h1 != 0`), so the mixer's loop path is not an edge case: a machine gun or an
  engine is one sample. Note `scripts/extract_audio.py` reports these counts on every run, so the numbers
  above are re-derivable rather than remembered.
* Samples are **8-bit signed PCM** - `Mixer::mixCallback` sums `int8_t` with `addclamp` (`mixer.cpp:22`).
* `freq` indexes `frequenceTable[]` and must be `< 40`; `vol` is clamped to `0x3F`; `channel & 3` gives
  **4 channels** (`AUDIO_NUM_CHANNELS`).
* Rate conversion is `chunkInc = (freq << 8) / outputSampleRate` (`mixer.cpp:62`) - Q8 fixed point, so a
  counter accumulator reproduces it exactly in RTL.
* Looping: `loopLen != 0` means loop the whole sample (`mc.loopPos = mc.len`), i.e. `start..len` repeats.

## 3. Music

`op_playMusic` (`vm.cpp:437`): `u16 resNum`, `u16 delay`, `u8 pos`.

* Module header (`sfxplayer.cpp`, `loadSfxModule`): `u16 delay` at `0x00`; then **15 instruments** as
  `u16 resourceId, u16 volume` from `0x02` (60 bytes); `u16 numOrder` at `0x3E`; `0x80`-byte order table
  at `0x40`; pattern data at `0xC0`.
* Patterns: 1024 bytes each = **64 rows x 4 channels x 4 bytes**, at `data + curPos + order*1024`.
* Event: `u16 note_1` (Amiga period; `0xFFFD` is a marker that writes `_scriptVars[0xF4]`),
  `u16 note_2` = sample index in bits 12-15, effect in bits 8-11, volume/param in bits 0-7.
* Rate: `freq = 7159092 / (period * 2)` (`sfxplayer.cpp:198`).
* **Instruments are `RT_SOUND` resources** - the music shares the sound bank and the same mixer.
* Event rate: `delay * 60 / 7050` ms, from the header or the opcode argument.
* Only **3 modules** exist for 10 parts, so most parts reuse one; worth confirming which scripts use
  which before optimising anything.

## 4. What the port does today

```
case 8h18: {          // op_playSound
  // (mem,data,resourceId) = nextWord(mem,data);     <- all five argument reads commented out
  mem.addr = mem.addr + 5;
}
// case 8h19: { } // no longer used, maps to op_drawString instead
case 8h1A: {          // op_playMusic
  mem.addr = mem.addr + 5;
}
```

Both opcodes **skip their five argument bytes**. `audio.json` is `magic`-only, there is no mixer, and
`tb_top` actively asserts the audio pins stay silent. The argument decoding is already written and
commented - re-enabling it is the same surgical `vm.si` patch that worked for `part_req`, applied by
`scripts/pocket_translate.sh` because `ports/another-world/upstream` is gitignored.

## 5. Architecture decisions

**D1 - where the audio data lives.** Two options:

* (a) **One file.** Append an audio section after the game pool in `aw-all.bin`: 2.94 + 0.70 = **3.64 MiB**,
  inside the existing 4 MiB upload window and census range. Reuses the proven single-upload path, needs no
  new bridge window and no new dataslot. Cost: the census/`pool_ok` declaration must then cover the whole
  payload (the builder already computes `wsum`/`wxor` over everything after page 0), and the headroom to
  the 4 MiB window is only ~0.36 MiB.
* (b) **Second dataslot.** Keeps the game image byte-identical and gives unlimited headroom, at the cost of
  a second upload path, a second PSRAM region and a second bridge window decode.

**Recommendation: (a)**, because it reuses the one upload path that is proven on hardware, and 3.64 MiB
fits. Trigger to switch to (b): total payload above 3.9 MiB (e.g. if music is pre-rendered to PCM).

**D2 - music: RTL tracker or pre-rendered PCM. DECIDED (owner, 2026-11-08): RTL tracker.**

The 3 modules are 33 KB of pattern data, so a tracker is small: patterns + order table + 4 voices feeding
the same mixer the effects already need. It also keeps `op_playMusic(resNum, delay, pos)` honest - that
opcode carries a start order position and a tempo override, and pre-rendering to PCM would have to throw
both away and guess. The two rejected alternatives, and why:

* **Pre-rendered PCM** - simplest to play, but discards the start position and tempo override, and real
  music as 8-bit PCM would very likely push the payload past the 4 MiB upload window. It also makes the
  music untestable against the original: a rendered stream can only be compared to itself.
* **Reusing a soft CPU to run `sfxplayer.cpp`** - the original implementation, but there is no CPU in this
  design and adding one to play three modules would be far larger than the state machine it replaces.

Consequence for D1: with a tracker the audio payload stays at **0.70 MiB**, so the second-dataslot route is
not expected to be needed - the trigger below remains as a guard, not as the plan.

**D3 - the output format is fixed by APF**: I2S, exactly 48 kHz, MCLK 12.288 MHz, SCLK 3.072 MHz, 16-bit
stereo, 16 active + 16 spacer bits, LRCK low = left.

## 6. Phases and acceptance criteria

**A. Extraction (host only).** Unpack all 103 `RT_SOUND` and 3 `RT_MUSIC` entries with the same `unpack()`;
emit an audio blob plus an index of `resId -> {offset, len, loopLen, type}`.
*Accept:* every entry's unpacked length equals `MemEntry.size`; the 4 sound header fields look sane for all
103; a spot-check of several samples against the desktop interpreter's own load.

**B. Packaging.** Put the blob in the image (D1a) and extend `build_combined_image.py` to emit the index and
cover the audio in the declared sums.
*Accept:* `--verify` still proves every part's view byte-identical; declared sums cover the whole payload;
image under 3.9 MiB.

**C. Loader/RTL plumbing.** A region in PSRAM the core reads by `resId`, and a small index RAM loaded at
boot from the blob header.
*Accept:* a bench reads back every index entry and a known sample's first/last bytes from the model.

**D. VM patch.** Re-enable the `8h18` / `8h1A` argument fetches and emit `resId, freq, vol, channel` and
`resNum, delay, pos`, exactly like `part_req`.
*Accept:* `tb_soc` sees the right values for a known script location; the patch is applied by
`pocket_translate.sh`, idempotent and anchored.

**E. Mixer (RTL).** 4 channels, 8-bit signed, Q8 rate accumulator, 6-bit volume, loop, sum with clamp.
*Accept:* bit-exact against a Python reference mixer fed the same commands and samples, for single-channel
play, 4-channel mix, loop, and a stop.

**F. APF audio out.** I2S 48 kHz per D3, `audio.json` if it needs more than `magic`.
*Accept:* `tb_top`'s MCLK/LRCK/frame-length checks pass with real samples; the "DAC silent" assertion is
replaced by "the DAC carries the expected samples".

**G. Music player (RTL tracker, per D2).** Pattern/order walk, 15 instruments, Amiga-period notes, tempo
derived from `delay * 60 / 7050` ms, over the same mixer as the effects.
*Accept:* a bench plays a module and matches a Python reference rendering of the same module, event for
event, then sample for sample.

**H. Hardware gate.** On the Pocket: a sound and a music cue at known script points, `AW 1046` as the
control for picture-only behaviour.

## 7. What could bite

* **The unpacker.** If `unpack()` disagrees with these banks, nothing downstream is testable - so A gates
  everything.
* **`tb_top` asserts silence.** That check has been a useful guard while there was no audio; it must be
  *changed*, not deleted, or the suite will fight the feature and the next person will disable it.
* **Rate butchery.** 8-bit PCM at rates well below 48 kHz, resampled by a Q8 accumulator, will alias. The
  reference mixer does exactly the same thing, so bit-exactness is achievable - but "matches the reference"
  and "sounds good" are different claims and only the first is testable here.
* **Volume.** `addclamp` clamps at int8 before the 16-bit output path; four channels at full volume will
  clip the way the original clipped. Faithful is the goal, not clean.
* **Music tempo** depends on a host timer in the original (`sys->addTimer`). The RTL must derive the same
  `delay * 60 / 7050` ms interval from the frame clock, and that derivation needs its own check. This is
  the tracker-specific hazard: a wrong tempo sounds "slightly off" rather than broken, so it will not
  announce itself the way a stuck channel will - count events per second against the reference instead of
  trusting the ear.
* **Tracker state is small but not free.** 15 instrument descriptors, a 0x80-byte order table, 4 channel
  contexts and the pattern cursor must survive a part change without a sweep-level stall; keep it in
  registers plus one small RAM, and do not let the tracker make a PSRAM read it cannot afford.

### First real audio events, harvested from the intro (2026-11-08)

With the VM patch (#35) and a per-event monitor in `tb_soc` (#42), a 60-frame paged part-1 run issued:

```
MUSEVT 0 num=0    delay=0     pos=0  frame=7     <- the documented "stop music"
MUSEVT 1 num=7    delay=15700 pos=0  frame=7     <- module 7, i.e. a real RT_MUSIC entry
SNDEVT 0 res=8    freq=1  vol=45 ch=3 frame=24
SNDEVT 1 res=8    freq=5  vol=45 ch=2 frame=24
SNDEVT 2 res=9    freq=20 vol=30 ch=0 frame=96
SNDEVT 3 res=9    freq=20 vol=63 ch=1 frame=96
```

Three things this settles at once:

1. **The opcodes really execute** - the argument reads added in #35 carry real values into the SoC, so
   #35 is proven end to end rather than only in the netlist.
2. **The ranges are legal** - `res` 8 and 9 are memlist entries, `freq` 1/5/20 are below the mixer's
   `< 40` assertion, `ch` 0..3. That is the check the invalid byte scan failed with freq 255 and
   channel 255, so this is also a positive control on the decode.
3. **The music requirement is concrete**: the intro starts module **7** with `delay=15700`, `pos=0`.
   Module 7 is indeed one of the three `RT_MUSIC` entries (memlist 7, 137, 138). The tempo override is
   therefore load-bearing from the first cue - `15700 * 60 / 7050` = 134 ms per event, so the tracker
   must honour the opcode's delay argument rather than the module header's, exactly as D2 assumed.

Note `delay=0` with `num=0` is the "stop" form, so the tracker's stop path is exercised immediately too.

The harvest is per-event, not sampled: a 10 ms diagnostic interval can contain two sounds, and a sampled
monitor would report the second twice. The VM's sequence counter exists for exactly this.

### Harvested requirement table (8 parts, 25-60 frame runs, 2026-11-08)

`scripts/audio_events.py` turns the `SNDEVT`/`MUSEVT` logs from `tb_soc` into the table the mixer and
tracker are built against. All eight parts harvested; **every event is inside the legal ranges**
(`resId < 146`, `freq < 40`, `ch <= 3`), which is also the positive control on the decode.

| what the game actually asks for | measured |
|---|---|
| distinct sounds (res, freq, vol, ch) | **18 tuples over 11 distinct resources** of the 103 extracted |
| freq indices used | **1, 3, 5, 7, 10, 20, 22, 30, 34** - all below the mixer's `< 40` |
| volumes used | 10, 16, 20, 22, 24, 30, 32, 45, 48, 63 |
| channels used | 0, 1, 2, 3 (all four) |
| channel stops (`vol == 0`) | **16 events, on all four channels** |
| music | module **7** only, `delay=15700` -> 134 ms/event; modules 137 and 138 not yet reached |

Two things this settles for the implementation:

**`vol == 0` is a stop, not a silent play.** `vm.cpp` `snd_playSound` does `if (vol == 0)
mixer->stopChannel(channel); else ...`, and the harvest uses it constantly - `res=106 vol=0` on all four
channels, `res=48 vol=0` on three. A mixer that treated volume 0 as "play inaudibly" would leave channels
running forever and every later sound on that channel would be mixed against a stale one. The stop path is
therefore load-bearing from the first seconds, exactly like the music stop.

**Only 11 of 103 sounds appear in short runs**, so the whole 0.70 MiB is not strictly needed to start -
but later chapters will reach more, and 0.70 MiB fits the window, so ship all of it rather than build a
subsetting step that would need re-doing the moment someone plays further.

`res=88 freq=7 vol=16 ch=0` repeating 13 times is the harvest earning its keep: that is a footstep-like
cue, and a sampled monitor would have reported it once.

### The mixer's arithmetic, and one quirk that must be copied rather than fixed

`scripts/ref_mixer.py` is a faithful transcription of `mixer.cpp` (`Mixer::mix` / `MixerChannel`), built to
grade the RTL against something that is not Verilog. Four C semantics change samples and are reproduced
deliberately:

* `chunkPos` is **16.8 fixed point**: low 8 bits the interpolation fraction, high bits the sample index.
* The interpolated byte `(b1*(0xFF - ilc) + b2*ilc) >> 8` is stored back into an `int8_t`, so it **wraps**
  to 8 bits rather than clamping.
* Volume is `b * volume / 0x40` with C's division, which **truncates toward zero** - Python's `//` floors,
  and the difference shows on every negative sample.
* `addclamp` saturates the running sum to -128..127.

Two properties that will otherwise be mistaken for RTL bugs:

* **A constant full-scale sample does not come out at full scale.** Volume is 6-bit, so `0x40` clamps to
  `0x3F`; and the interpolator multiplies by `0xFF/0x100`. `127` becomes `(127*255)>>8 = 126`, then
  `126*63//64 = 124`. Two separate 1-LSB attenuations.
* **The loop wrap writes a raw sample index into a 16.8 accumulator.** `chunkPos = loopPos`, not
  `loopPos << 8`, so after a wrap the high byte is `loopPos >> 8` and the fraction is `loopPos & 0xFF` -
  the reader lands at the START of the sample with a fractional offset. With data `[10,20,30,40]`,
  `loopPos=1`, `loopLen=2` the model produces `8, 18, 28, 9, 18, 28`. That is almost certainly a bug in
  the original, and it is the behaviour to reproduce: **11 of the 103 sounds loop**, so it is load-bearing
  rather than a corner.

`python3 scripts/ref_mixer.py` runs four hand-checkable cases (full-scale constant, truncation toward zero,
end-of-sample stop, loop wrap) and is the oracle the RTL mixer will be graded against.

### Correction: the audio image did not cause the shifted fills (measured, 2026-11-08)

After packaging the audio into the image I reported 509 shifted fill writes on part 1 and attributed them to
the longer boot census (1.9M words instead of 1.5M). **The control disproves that.** The game-only image,
same part, same frame count, gives the identical result:

| image | bytes to VM | fill writes shifted | frame swaps |
|---|---|---|---|
| `aw-all-audio.bin` (3,813,404 B) | 23,021 | 509 | 18 |
| `aw-all.bin` (3,080,192 B) | 23,021 | 509 | 18 |

So the audio section is not the cause and the "bound the census to the pool" recommendation derived from it
does not stand on this evidence. Recorded rather than quietly dropped, because a plausible causal story with
a number attached is exactly the kind of thing that gets acted on later.

What the comparison does point at: the last *passing* paged part-1 run (41,956 bytes, 0 shifted) predates the
chapter-switch RTL work - the `P_IDLE` streamed-gate removal, the `streamed_q` clear, the restart toggle and
the `rstr_evt` stream reset. Those were introduced together and one of them is the likely regression, so the
next step is a stash-and-rerun bisect rather than an audio change.

One signature worth keeping: the shift reports `gaps=0` and `rewinds=0`, so the stream never broke - it
started misaligned. That is a different shape from the 1040/1041 resume-policy failures and must not be
diagnosed as one.

### The paged regression is real and is NOT audio: bisected (2026-11-08)

With `aw_rom.v` and `tb_soc.sv` reverted to `f69583e` - the last known-good paged state, before the
chapter-switch work - part 1 on the game-only image returns exactly its old numbers:

| code under test | bytes to VM | fill shifted | verdict |
|---|---|---|---|
| HEAD (`5ec0369`) | 23,021 | **509** | FAIL |
| `f69583e` (aw_rom + tb_soc) | **41,956** | **0** | PASS |

So there is a **regression in the paged path** introduced since `f69583e`, and it is not related to the audio
work at all - the audio image and the game-only image behave identically at HEAD, which is what ruled that
out first.

What changed in between, in the two files that were reverted together: the chapter-switch additions to
`aw_rom` (`vm_part_req` input, `rom_vm_restart` output, the `pr_*` stability filter, `view_part`'s second
source, `restart_tog`, the `rstr_evt` fetch reset, the `P_IDLE` streamed-gate removal, the `streamed_q`
clear on a part commit) and the corresponding `tb_soc` changes (audio event harvest, `+VMREQ` injection,
`+SWITCH` machinery, 4 MiB image buffer).

Narrowing it needs one more run, and the halves can be separated cheaply: keep the NEW `aw_rom` and revert
only `tb_soc` (an unconnected `vm_part_req` input is legal and reads as 0). If that passes, the fault is in
the bench; if it fails, it is in `aw_rom`'s new chapter logic.

Why this matters beyond the bug: #36, #37's integration and the tracker (#39) all build on the paged path, so
a 50 % loss of bytecode delivery would have been inherited by every audio test as "mysterious starvation".
The measurement that found it was the plain part-1 run, not any audio bench.

### Resolved: the "regression" was the chapter switch firing - both features confirmed

Bisect, in two runs:

| code under test | bytes to VM | fill shifted | verdict |
|---|---|---|---|
| HEAD (`aw_rom` + `tb_soc` new) | 23,021 | 509 | FAIL |
| `f69583e` both files | 41,956 | 0 | PASS |
| **new `aw_rom` + old `tb_soc`** | **41,956** | **0** | **PASS** |

So the RTL is innocent and the bench was at fault - and the only *behavioural* difference in the new bench is
that it connects the VM's part request to `aw_rom` (`vm_part_req`), where the old one left the input
unconnected and therefore zero. Everything else added there is observation.

That connection is the whole story, because **part 1's own bytecode asks for part 2 during the run**:

```
op_updateMemList(0x3E82) at 0x9B4   -> part 2
op_updateMemList(0x3E82) at 0x9C6   -> part 2
```

and the control-flow walk of part 1 reaches `0x9B8` through a `condJmp` at `0x0087`, so that request is on
the executed path within the first frames. With the input connected, `aw_rom` did exactly what it was built
to do: it moved `view_part` to 2 and pulsed the restart.

**What that proves is worth more than the bug report:**

1. The game-driven chapter change works end to end on the real VM - the request is issued by the script, crosses
   into `aw_rom`, and moves the page table. That is #35 plus the whole `pm_part_req` chain, confirmed by the
   game itself rather than by an injection.
2. The #31 blocker is real and now has its clearest symptom: the VM *resumes* rather than re-reading the
   trailer, so after the switch it keeps executing part 1's bytecode over part 2's bytes. That is exactly the
   509 shifted fill writes with `gaps=0` and `rewinds=0` - the stream never broke, **the view changed
   underneath it**, which is a different failure shape from the 1040/1041 resume-policy faults and must not be
   diagnosed as one.
3. Any bench that runs a part to the point where the script asks for the next one must either expect the
   switch or suppress it. This is now recorded so the next person does not re-derive "the paged path lost half
   its throughput".

So: no regression, no audio fault, and the two half-built features together behave exactly as their separate
diagnoses predicted.

### PSRAM arbitration: measured headroom before designing anything (2026-11-08)

`aw_rom` owns the only PSRAM port, so audio reads have to share it. Before touching that sequencer - the file
that has caused the most regressions in this port - the demand is quantified:

| | reads/s | share of the port |
|---|---|---|
| PSRAM sequencer capacity (92.812 MHz, 13 cycles/read) | 7,139,423 | 100 % |
| audio, worst case (48 kHz x 4 channels x 2 reads: b1 and b2) | 384,000 | **5.4 %** |
| VM bytecode stream, measured (41,956 bytes over 78 frames at 60 Hz) | 32,274 | 0.5 % |
| **combined** | | **5.8 %** |

Per 48 kHz tick: 20.83 us is 1934 PSRAM clocks, and audio needs 104 of them.

So the arbitration does not need to be clever, and it must not be clever: **5.8 % occupancy means the design
should be "serve the audio read when the port is idle, hold a pending latch so a request is never lost"** -
exactly the pattern the sequencer already uses for the self-test probes. A priority scheme that can starve
either side would be solving a problem that the numbers say does not exist, and the census already showed what
happens when a sweep takes the port away from the VM mid-stream: a 126 ms stall, ERR_OVERFLOW on the upload,
and the VM fed zero bytes.

The one quantity that IS constrained is latency: an audio read must complete within a tick (20.83 us) or the
mixer runs out of samples. With 1934 clocks available and a VM burst measured at a few hundred bytes per
frame, that is not close - but it is the thing the integration bench should assert (`bytes_to_vm` climbing,
`starving` at 0) rather than assume.

### The integration's real question: which clock the mixer lives in (answered, 2026-11-08)

Not a wiring detail - a CDC decision that would otherwise be discovered halfway through the edit.

`aw_rom`'s audio port is in **clk_psram** (92.8125 MHz), because that is the clock that owns the chip.
The VM's `snd_*` outputs are in **clk_core** (24.75 MHz). The mixer has to be next to one of them.

**Decision: the mixer lives in clk_core.** Commands (`play`, and its `res/freq/vol/ch`) come from the VM, so
putting the mixer beside the VM means the *command* path needs no crossing at all - and commands are the part
that carries a repeated-identical-request hazard (`snd_seq` exists for exactly that). Only sample BYTES then
cross, and bytes are a simple request/response with no ordering semantics.

Cost, measured: one tick is 516 clk_core cycles. A 4-phase req/ack handshake to clk_psram and back is ~12
clk_core cycles at the slower clock; 8 bytes (4 channels x b1,b2) taken sequentially is **96 cycles = 18.6 % of
the tick**, leaving 420 cycles of slack. So a per-byte handshake is affordable and no FIFO is needed.

The alternative - mixer in clk_psram - would need a CDC on the command path instead, including a sequence
counter crossing, which is strictly worse: it puts the hazard on the side that has ordering meaning.

Corollary for the edit: `aw_audio_idx` also belongs in clk_core (it is driven by the command path), so its byte
reads cross through the same handshake. The PSRAM-side logic stays exactly what `aw_rom` already has: latch a
request, serve when idle, return one byte.

### The last integration finding: the mixer's memory port is fixed-latency (2026-11-08)

`aw_mixer.v` has `rd_addr` out and `rd_data` in, and **no wait/valid**: its sequencer hardcodes the latency in
states (S_RD1 -> S_W1 -> S_RD2 -> S_W2 -> S_W3), tuned to a one-cycle RAM. Its 64/64 bit-exact bench drives
exactly that model.

The real path is nothing like one cycle: a byte goes mixer (clk_core) -> handshake -> aw_rom sequencer
(clk_psram) -> PSRAM access (~12 clk_psram cycles) -> handshake back, i.e. roughly 24+ clk_core cycles, and
variable because the sequencer serves audio only when the port is idle.

So the integration is NOT plumbing. It needs:
* `rd_req` / `rd_valid` on the mixer's memory port, with the fixed wait states replaced by "wait for valid";
* the bench updated to MODEL the new latency (its RAM becomes a delayed responder), because a bench whose
  memory answers in one cycle would pass a design that cannot work on hardware - the exact "preconditions
  differ from the field path" trap this project has a rule about;
* a small CDC shim in core_top doing the 4-phase handshake, with the mixer tolerating a variable number of
  wait cycles rather than a fixed one.

Worth saying plainly: the earlier CDC note (mixer in clk_core, bytes cross by handshake, 18.6% of a tick)
still holds - bandwidth and domain choice are settled. What was NOT settled until now is that the mixer's
interface has to change shape, which is a modification to a verified module rather than wiring around it. That
should be the first task of the next session, with its bench updated in the same pass.

## Implementation notes (2026-11-09): what the integration actually cost

The five phases A-E were graded against oracles before anything was wired together. Wiring them exposed four
things that no module-level bench could have found, and each is recorded here because each one looked like
something else at first.

### 1. The index left the per-lookup path (decision, measured)

`aw_audio_idx` was built to walk the image's index one byte at a time on every lookup. With the index at
`0x1000` and 106 records that is up to `1 + 106*16 = 1697` byte reads for the last record, and in the field
every read is a PSRAM round trip through a clock-domain handshake (~24 clk_core): ~1.6 ms, ~78 dropped mixer
ticks per play - on a channel that may be playing music, competing with the sample fetch for the one PSRAM
port.

It now copies the index out of the image **once, at boot**, into 2 x M10K (`aw_audio_idx`, 2048 x 8) and
looks up locally: ~17 clk per record, 73 us worst case, and **no PSRAM traffic at all per play**. This is
what phase C specified; the walk was the implementation drifting from the plan. Measured in `tb_audio_idx`:
1700 bytes loaded in ~14k clk with a 3-cycle-delayed responder, every byte identical to the image's, all 106
records resolving.

The loader is a 4-phase handshake (`req` raised with a stable address, dropped after `valid`). The first
version held `req` high across bytes and the responder captured the same address twice - `mem[1]` held the
tag again. A level that never falls is not a handshake.

### 2. `aw_rom`'s audio fetch had no way out of `ST_WAIT`

The probe, census and directory captures each release the sequencer when their readback lands; the audio
capture is gated by `!aud_active` (it must not steal their reads), so it could not release it - and nothing
else did. Every audio byte therefore parked the sequencer until the 16-bit watchdog expired.

Measured in `tb_top` before the fix: **~0.9 ms per byte**, the 1439-byte index load taking a second instead
of two milliseconds, and the mixer starving identically on every sample. After adding `aud_captured` to the
`ST_WAIT` branch: the whole load completed inside one 2.7 ms monitor interval.

This is the class of bug a module bench cannot see: `aw_audio_rd`'s responder answers correctly, and the
mixer is bit-exact; only a real `aw_rom` with a real sequencer shows the missing release.

### 3. Reading silent channels was 8.6% of the ticks

The mixer read `b1`/`b2` for all four channels on every tick, active or not. Measured in a 60-frame `tb_soc`
run (part 1 of the audio image, VM streaming bytecode the whole time): **7591 dropped ticks of ~88,680**.
`mixer.cpp` only processes active channels, so the reads were pure cost. Inactive channels now skip straight
to the advance state: reads cost 2 per **active** channel - none in silence, four in the harvest's typical
case. `tb_mixer` is still 64/64 bit-exact after the change.

`aw_mixer` now also exposes a dropped-tick counter, so the integration benches assert it is zero rather than
assuming it.

### 4. The clock crossing, and the I2S alignment

`aw_audio_rd` is the only crossing in the data path: a toggling bit through three flops into clk_psram, one
`aud_req` pulse with the address held, and the acknowledgement toggling back. Tested against a responder
with 4..259 `clk_psram` cycles of latency and 2% of transactions blocked for 400 cycles: 170 issued, 170
returned, 0 errors.

`aw_audio_i2s` keeps the template's MCLK generation (a fractional accumulator on clk_74a - 74.25/12.288 is
not an integer) and runs the whole output stage on MCLK itself: 12.288 MHz / 48 kHz = exactly 256, so SCLK is
MCLK/4 and a frame is 64 SCLK periods. LRCK changes at slot 31 and slot 63, one SCLK **before** the MSB at
slots 32 and 0 - standard I2S, and the same timing the template's `cnt == 31` toggle implied. `tb_audio_i2s`
decodes the pins back to samples: 400 fed, 400 received, 1 underrun at the initial fill, 0 overruns, and
MCLK/SCLK/LRCK measured over a fixed window.

### Build findings

* `aw_rom`'s `pr_done` was driven from two always blocks (a reset in the part-request filter, and its own
  "request applied" block). Verilator warned; **Quartus refused to elaborate** - 18 errors of "Can't resolve
  multiple constant drivers". The first Quartus build after the chapter-switch work therefore did not exist.
  Fixed by giving `pr_done` one driver.
* The four audio modules were not in `aw.qsf` at all: no audio build had ever been attempted, so "it
  simulates" was the whole of the evidence until now.

### The I2S FIFO had no depth (measured, fixed)

The first `tb_soc` run with audio reported **4,124 underruns in 88,000 frames** (4.7%): the frame clock asked
for a sample the FIFO did not have. Both timebases are exactly 48 kHz on average, but they are independent, so
with the FIFO starting EMPTY every phase wobble walks it back to zero and the frame repeats the previous
sample. The stage now waits for four samples before it starts shifting (83 us of latency, inaudible) and the
same run reports **0 underruns**. "Buffer" and "no buffer" are the difference between 4.7% sample repeats and
none, and the counter in `aw_audio_i2s` is what made it visible instead of an impression.

### What `tb_top` now proves

The old check was "the DAC is silent for the whole run", which the template's constant-zero shifter passed -
the assertion could not tell a working chain from a stuck one. It is now: the index was copied out of the
image, 480 ticks and 480 mixer samples and 479-480 I2S pops in a 10 ms window, 0 dropped ticks, **and** the
DAC silent while the script has not asked for a sound (the synthetic pack has no bytecode, so silence is the
correct output - produced by a running chain rather than by a constant).

The window had to move to *after* the index load: the first version opened it four frames in, before the
loader had run, and reported zero mixer samples for a working path.

`tb_soc` is where the real pack runs: it instantiates the same chain against the same `aw_rom`, so a play
issued by the game's own bytecode measures the shipping path, including the added PSRAM traffic.

### Harvest widening, closed by a different route (2026-11-12)

The original plan was to play the game longer and collect more events. That is expensive in simulation
(a part's later chapters are hundreds of frames away) and it depended on the game choosing to ask for
the resources we wanted. The acceptance clause allows the other route, and it turned out to be the
better one: **grade every MUSIC resource in the image directly against the reference**, with the same
bench that grades module 7.

`scripts/sim_audio.sh` now runs `tb_music` three times — module 7 (the intro theme, 1192 events) and
modules **137 (266 events)** and **138 (361 events)** — all event-for-event against `ref_tracker.py`
with 0 errors. Those two modules were never reached by any harvest run, and their instruments **loop**
(`loop=5728+21392` and `3226+3482`), so the looping path the mixer must reproduce is now exercised by
real module data and not only by the mixer's own bit-exact loop case.

What that leaves uncovered is *game-driven* coverage of the 11 looping SOUND resources
(res 1, 3, 8, 16, 89, 97, 102, 104, 106, 132, 139): their loop wrap is byte-identical to the modules'
(mixer, `ref_mixer` bit-exact), but no recorded run has heard them from the game. Reaching them means a
long run into later chapters, which the chapter switch (AW 1065) now makes possible without a relaunch;
it is a cost/benefit question, not a blocker, and this note is the documented reason.
