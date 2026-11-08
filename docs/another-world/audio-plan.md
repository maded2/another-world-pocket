# Sound effects and music: what the data is, and how to get it out of the Pocket

Status: **plan**. Every number below was measured on 2026-11-08 from `gamedata/memlist.bin` and the
pinned upstream sources in `ports/another-world/upstream/BUILD/Another-World-Bytecode-Interpreter/src/`.
Nothing here is implemented; today the core is silent by construction.

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
