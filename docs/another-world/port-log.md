# Another World / Pocket — port log

Working log for the `aw` core: what has been built, what has actually been
verified, what broke, and what is next. Kept separate from
[problem-analysis.md](problem-analysis.md) (the up-front analysis) and
[feasibility-probes.md](feasibility-probes.md) (the measurements) because this is
the part that changes daily.

Nothing in here claims a thing works unless a tool said it did, and the command
that said it is written next to it.

---

## Status at a glance

| | |
|---|---|
| Bitstream | builds green, full Quartus flow, timing closed (`build/aw/report.txt`) |
| Clocks | PLL produces exactly 24.75 / 24.75 @90° / 49.5 MHz (fit report, below) |
| Framebuffers | map to M9K blocks: 1,283,328 of 3,153,920 memory bits in 169 blocks |
| Simulation | **ROM path passes**: full 2 MB pack loaded over a bridge model and read back byte-exact, 383 checks / 0 errors, plus the overflow tripwire. **Whole design runs** (`tb_soc`): pack loads, VM boots, video times 320x200 @60 Hz, every byte the ROM hands the VM matches the image - and the **screen is black**: the VM stops asking for bytes after 224 |
| Hardware | never run. No Pocket in reach this session |
| Audio | silent by scope decision (S1), the template's I2S silence generator stays |

The ROM path is now the best-understood part of this port: it is the only piece with a
testbench, and that testbench found twelve defects that the build reported as success (see
*Simulation found what Quartus could not*). Everything else is still believed rather than
verified - which is why the next thing after the rebuild is `tb_soc`, not more RTL.

The tree **has** been through Quartus since then: build12 is a full compile with the
rewritten ROM, the `vm_running` gate and the corrected PSRAM constraints - 0 errors, worst
slack +0.133 ns, `bitstream.rbf_r` 1,355,424 bytes, and `scripts/check_build.py` exits 0.

---

## Verified, with numbers

**Full compile** (Quartus 22.1std.2 Lite, device 5CEBA4F23C8, `./docker/run.sh
scripts/build.sh cores/aw --no-sigtap`, 140 s):

```
                                     current tree          first green build
Logic utilization (in ALMs) : 3,510 / 18,480 ( 19 % )        2,993 ( 16 % )
Total registers             : 3,508                          3,129
Total block memory bits     : 1,101,888 / 3,153,920 ( 35 % ) 1,283,328 ( 41 % )
Total RAM Blocks            : 146 / 308 ( 47 % )             169 ( 55 % )
Total PLLs                  : 1 / 4
bitstream.rbf_r             : 1,355,424 bytes
worst slack                 : +0.133 ns                      +0.112 ns
```

The block-RAM figure fell even though the ROM got more logic because the stream FIFO went
from 256 words to 64 (see *Simulation found what Quartus could not*) - the look-ahead that
looked generous was the thing making every restart slow.

1,283,328 memory bits is four pages × 64,000 pixels × 4 bits plus the VM's own
BRAMs — the per-pixel framebuffer shape (probe C2's conclusion) did land in block
RAM rather than fabric.

**Timing**: every clock closed. Worst number in the report is **+0.112 ns**, a
hold check on `clk_core` in the Fast 1100mV 0C corner. Setup on `clk_core` has
23.3 ns of slack, `clk_psram` 7.7 ns.

**Clocking** (`aw.fit.rpt`, PLL summary) — hand-written `altera_pll` parameter
list, because Quartus Lite ships no `ip-generate-cli`:

```
PLL Type                     Integer PLL
Reference Clock Frequency    74.25 MHz
PLL VCO Frequency            346.5 MHz
out0  24.75 MHz   0 deg      C=14    design + pixel clock
out1  24.75 MHz  90 deg      C=14    video_rgb_clock_90
out2  49.5  MHz   0 deg      C=7     ZBT PSRAM controller
```

24.75 MHz is also the pixel clock, so 825 × 500 total is exactly 60.000000 Hz
with 320 × 200 active and 60 % of the frame blanked (upstream gets 15 %). That
blanking is not cosmetic: the rasterizer and blitter may only touch the displayed
page while nothing is being displayed, so blanking is the only time they make
progress.

**Pack format**, checked against the file rather than against my notes:

```
part size          2,097,136 bytes = 0x1FFFFF0 = 2 MiB − 16
trailer (4 × u32)  at byte 0x1FFFE0 = (1<<21) − 32   ← vm.si's own first read
part1 offsets LE   [0, 9445, 4321, 11493]
last 16 bytes      00000000 e5240000 e1100000 e52c0000
```

**ROM contract** (from `vm.si` / `a5k.si`, since the port has to reproduce it):
`in_ready` is a *pulse* for single-byte reads — `readByte()` sets it for one cycle,
drops it while waiting for `busy` to fall, then takes `mem.data`; and it is *held*
for the 64-byte preload loop, which counts `data_available` cycles. So: deliver at
least one byte per acceptance, keep going while `in_ready` is high, and make
`data_available` exactly one cycle per byte — the preload advances its write
pointer on it, so a stray pulse shifts the whole buffer.

---

## Corrections — three earlier beliefs in this project were wrong

Kept here because they look self-evidently right and will be re-broken otherwise.

1. **vm.si's frame wait is not a bug, and is no longer patched.**
   `while (~pause[23,1])` — Silice ranges are `[start,width]`, so this is bit 23
   of a value that never reaches bit 23. The countdown stops when the subtraction
   wraps through zero: an exact `slices × 393216` cycles, two longer than it looks.
   393,216 cycles is shorter than one frame both upstream (420,000) and here
   (412,500), so the `while (~vblank)` that follows is what actually paces the
   game: one frame per slice, exactly 60 Hz.
   An earlier revision of this port "fixed" the constant to 491,520 cycles/slice,
   which is *longer* than a frame and would have run the game at about 50 Hz.
   `scripts/pocket_translate.sh` now copies vm.si verbatim; the only thing it
   rewrites is include paths. (rawgl sleeps `slices × 20 ms`, which tempts the
   same change — rawgl's 20 ms is itself clamped by its vsync, so the number to
   match is the frame, not the constant.)

2. **The trailer is at 0x1FFFE0, not 0x1FFFFE0.** An extra `F` that survived into
   two files. Caught by `iverilog`'s "extra digits given for sized hex constant",
   confirmed against vm.si's `(1<<21) - 32` and against part1.bin's size and last
   16 bytes. Fixed in `aw_rom.v` and in the comment in `scripts/extract_packs.sh`
   (which also said big-endian; the offsets are little-endian, and each byte the VM
   reads is shifted in at the top, so the first byte read ends up in `[7:0]`).

3. **clk_74a is 74.25 MHz, not 74.325 MHz.** Two independent places in the APF
   template agree on 74.25 (the PLL's `reference_clock_frequency`, and the audio
   accumulator's `742500` divisor that yields exactly 12.288 MHz from 74.25). At
   74.25 the /3 gives a pixel clock that divides to exactly 60 Hz, which is the
   whole reason for choosing 825 × 500.

### Silice semantics, learned from the generated netlist

Recorded in `cores/aw/src/si/aw_pocket.si` comments where they matter, because
they are not guessable:

* an assignment inside `always` to a signal that is a pure function of other
  signals becomes a **combinational macro**, not a register. `active_d1 = active;
  active_d2 = active_d1;` delays nothing at all.
* `::=` is a registered assignment; `<::` is a combinational alias. The pixel
  pipeline needs exactly **two** `::=` stages (framebuffer read, palette read)
  before the output port, which is itself registered. Verified in the generated
  file: `active`/`active_v`/`show_page1` are `<::`, `active_p1`/`active_p2`/
  `swap_p1` are `::=`, and `_q_video_de` ends up aligned with the colour that
  left the palette RAM two cycles after the address was issued.
* statements in an `always` block see the **most recent** value (blocking
  semantics), so the display counters are advanced last and `y` reads `x` first —
  upstream's order, which is easy to "tidy" into a picture one pixel out of step.
* a unit may have `always`, or `{always_before, algorithm, always_after}`, never a
  mix. The joystick delay is `::=` inside the single `always`.
* `bram ... = 0` is a syntax error; use `uninitialized`. A real initializer is
  emitted as a 64,000-entry list per page: 5 MB / 263,098 lines of Verilog instead
  of 157 KB / 7,081. Zeroing is kept for `$$if SIMULATION` only.
* `-a no-pin-check` is required: the design's ports are the Pocket's (byte-stream
  ROM port, DE/HS/VS video bus), none of which exist in a Lattice pin file.
* the generated file needs SystemVerilog (sized casts like `12'(...)`) → listed as
  `SYSTEMVERILOG_FILE`, and listed last because it sets `default_nettype none` and
  never restores it.

---

## Report audit — a green build that could not have run

The first complete build had **zero errors** and could not have worked: one signal
driving the ROM read stream had no driver at all. Quartus said so, two hundred
warnings deep:

```
Warning (18550): Found RAM instances implemented as ROM because the write logic
                 is always disabled
    Atom "...aw_rom:u_rom|aw_fifo:u_rqfifo|altsyncram:mem_rtl_0..."
; aw_rom:u_rom|p_want_s[0..2] ; Stuck at GND due to stuck port data_in ;
```

That is why `scripts/check_build.py` exists. Four real defects came out of it and
the sim linters:

| found by | defect | effect had it shipped |
|---|---|---|
| Quartus map (18550 + stuck) | `core_want` declared, never driven | read stream dead; VM waits forever at boot |
| Quartus map (stuck) | `ld_full` was an undriven wire — `aw_fifo` had no `wr_full` output | bridge writing faster than the chip drains would silently drop bytes with no diagnostic |
| Verilator unused-bits | alignment test read `ld_q[1:0]` (the payload) instead of `ld_q[33:32]` (address bits) | an unaligned bridge write would be written at the wrong addresses |
| Verilator SYNCASYNCNET / dead reg | `rst_bridge` used as async reset in one block, sync in others; `aw_psram.addr` dead after a restructure | reset-tree smells; dead state that reads as intentional |

Lint commands, all in the Silice image:

```
./docker/run-silice.sh iverilog -o /dev/null \
    cores/aw/src/fpga/core/{aw_fifo,aw_psram,aw_rom}.v
./docker/run-silice.sh verilator --lint-only -Wall --top-module aw_rom \
    cores/aw/src/fpga/core/aw_rom.v cores/aw/src/fpga/core/aw_fifo.v \
    cores/aw/src/fpga/core/aw_psram.v
python3 scripts/check_build.py --core-dir cores/aw --expect-clock 24.75,24.75,49.5
```

`iverilog` alone was not enough: it simulated the undriven `core_want` as zero and
reported nothing. Verilator found two things Quartus did not, Quartus found two
things Verilator could not know.

---

## Files

Silice side:

* `cores/aw/src/si/aw_pocket.si` — the SoC top: owns the display timing, the
  framebuffer arbitration, the palette, the ROM port; `include`s upstream `vm.si`
  and `clean_reset.si` unmodified.
* `scripts/pocket_translate.sh` — stages sources next to each other, rewrites the
  two include paths, runs `silice-make.py -b icebreaker -p basic --no_build
  -a no-pin-check`, strips the Lattice board top, writes
  `cores/aw/src/fpga/core/aw_pocket_build.v`.

Verilog side (`cores/aw/src/fpga/core/`):

* `aw_pll.v` — `altera_pll` from 74.25: 24.75, 24.75 @90°, 49.5. Hand-written
  parameters (no `ip-generate-cli` in Lite).
* `aw_fifo.v` — gray-pointer clock-crossing FIFO with conservative `wr_free` /
  `rd_level`, `wr_full`, and a `flush` level that needs both sides halted.
* `aw_psram.v` — ZBT cellular-PSRAM controller: ADV-muxed address on the data bus,
  one word per two cycles, byte enables, WAIT# honoured, level handshake so
  requests go back to back.
* `aw_rom.v` — the pack ROM. Bridge→PSRAM loader, the byte-stream provider that
  replaces upstream's Quad-SPI reader, the halt/flush handshake between
  acceptances, and the boot check that reads the trailer through the real read path
  before `rom_ready`. Bad or absent data leaves the design in reset and sets
  `rom_error`.
* `core_top.v` — clocking and staged reset, d-pad→jstick repacking, the
  waiting/error screen (blinking white block = waiting for the pack; red = trailer
  not a pack; purple = bridge overflow; blue = transfer stopped early), `M_main`
  and `aw_rom`. The template's test pattern and the whole `mf_pllbase` IP tree are
  gone.
* `aw.qsf` — file list; generated file last, as SystemVerilog.
* `core_constraints.sdc` — clock groups by PLL output-counter name. **Not done:
  the PSRAM input/output delays are currently ignored** (`clk_psram could not be
  matched with a clock`); they need
  `ic|u_pll|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk`.

Simulation (`cores/aw/src/sim/`, plus `scripts/sim_rom.sh` and `scripts/sim_write.sh`):

* `tb_write.sv` - 256 bytes in, 272 back, in seconds. Written after it took four minutes
  per attempt to learn that nothing was being written; this is the test that finds that in
  a few seconds, and it reads somewhere it never wrote (0x100..) to prove an empty memory
  does not pass. Covers single-byte `readByte` reads and the held 64-byte preload.

* `aw_psram_model.v` — behavioural 8 MB ZBT part, including the two things a
  controller gets wrong: address and data sharing a bus behind ADV#, and the read
  result appearing one cycle after the address is taken.
* `tb_rom.sv` - a real 2 MB pack in over the modelled bridge, then read back the way the
  VM does: held-`in_ready` preloads at even and odd addresses, pulsed single-byte reads,
  the trailer, transitions between the two patterns, and a byte-exact comparison against
  the file it came from. Clocks start at unrelated offsets with unrelated periods, so the
  crossings are exercised as asynchronous rather than as a tidy 2:1 dance. `+TRIPWIRE`
  runs the opposite case - a bridge writing every cycle - and passes by *reporting* the
  loss. `+PACE=n` sets how many idle bridge cycles the modelled host leaves between writes,
  which is the only way to say "a plausible load" without hardware to measure. Reports
  cycles per accepted byte and preload bytes per design cycle.
* `docker/Dockerfile.silice` now installs `iverilog` and `verilator` — before this
  session the repo had no simulator at all.

---

## Simulation found what Quartus could not

`scripts/sim_write.sh` (256 bytes in, 272 bytes back, seconds to run) and
`scripts/sim_rom.sh` (a real 2 MB pack, every VM access pattern, a few minutes) between
them found every defect in this path. The first group all had the same shape: **the read
path worked, so the boot check passed, while nothing was being written.** That is why the
first test written for this path writes bytes and reads them back, and why it also reads
somewhere it never wrote.

| defect | what the chip actually did | how it was found |
|---|---|---|
| ADV# still low during the data phase | the part took the write data as another address; nothing was written | trace of the chip's own accesses: writes appeared as `ADV`, never as writes |
| `we_n <= is_write` | write enable asserted on every *read*, disabled on every write | same trace, `we_n` column |
| `oe_n` taken from the same term | both `we_n` and `oe_n` asserted at once: part and controller drove the bus together during every write | `dq=feff` on a write of `0xa4a5`, i.e. contention |
| `wr_be` polarity: `2'b00` meant "whole word" | `ub_n = ~be[1]`, `lb_n = ~be[0]` ⇒ both lanes disabled ⇒ a whole-word write wrote no bytes | `lb=0 ub=0` on a write |
| loader wrote word = byte address, reader read word = byte address >> 1 | every byte would come back from the wrong address | byte-exact readback comparison |
| the consumer took the FIFO's `rd_q` in the cycle it popped | `rd_q` is registered: it holds the word pulled by the *previous* pop. A stream therefore started from wherever the last stream had left `rd_q`, then skipped a word every two bytes | held-stream test: `got a1 a0` where `a7 a6` was wanted |

The second group only appears once the *pattern* is right, and none of it fails a build
either. These are listed because each cost real time and each suggests a test:

| defect | what the chip actually did | how it was found |
|---|---|---|
| the boot check swallowed a concurrent VM acceptance | the byte went into the check's shift register instead of to the caller, and `busy` - held high by the check - never fell | `tb_write` with a trailer written, so a check actually runs; without a trailer no check ever runs, and the bug sleeps |
| the rewind re-fired every cycle | each re-fire bumped the generation, so the producer could never tag a word with what the consumer was looking for: the ROM went quiet with `busy` held | full-pack run: eight bytes of stale memory delivered as if they were the trailer, then a stall |
| entries tagged with a per-acceptance generation counter | the consumer's counter and the producer's are in different domains kept in step by a pulse, and *two* things restart a stream (acceptance, rewind), so a restart could be missed and no tag ever matched again | same; fixed by tagging entries with the **address** each word was read from instead |
| the address tag was 20 bits wide | the producer speculates past the end of the 2 MB window; `0x100000` aliased onto `0x00000`, so a word read from *outside* the pack was delivered as byte 0 of it | byte-exact readback of byte 0, and nothing else |
| the restart was a rising edge on `c_run` through a two-flop synchroniser, with the honest minimum gap of one core cycle | one core cycle is exactly two producer cycles: the edge was missed often enough to see, and when missed the stream continued from the *previous* stream's address | odd-start stream test; fixed with a `C_GAP` state that holds `c_run` low for a guaranteed width |
| the FIFO was 256 words deep and the producer filled it | every restart had to seek past ~250 stale words; a single byte cost 513 cycles and a 64-byte fill ran at 0.11 bytes/cycle | measured, not guessed: `tb_rom` reports cycles per acceptance and fill throughput |

The last one is a design lesson rather than a bug: at full rate the memory supplies
exactly one word per core cycle and the VM consumes exactly one word per core cycle, so
the buffer is the *entire* margin. What matters is having a fill's worth of it buffered,
not having a lot of it. Look-ahead is now 40 words, depth 64.

The last one is the reason `aw_fifo`'s header states the read latency in words: the
symptom is a stream that is correct for one word and wrong after that, which points at
nothing in particular unless you already know the FIFO's read is registered. The byte
consumer is now two stages (`n_word` prefetch, `c_word` hand-off) with the hand-off
allowed in the same cycle the current word runs out, taking the landing word directly.
That bypass is not an optimisation: without it there is one empty cycle every two bytes,
and the VM's preload treats any empty cycle as a reason to restart its fill - so the
stream would restart forever and never load.

The `aw_psram_model` was wrong too, in the direction that hid the problem: it started
driving the bus after every ADV without looking at OE#, so it fought the controller during
writes. A model that contends with the design cannot detect contention. The driver is now
gated combinationally on OE#, with the reason in the file.

### The testbench was wrong twice, and each time it looked like a design bug

Worth recording because both wasted hours on a design that was fine:

**Verilog task locals are `static` unless declared `automatic`.** `tb_rom`'s read helpers
kept their `guard` and `got` counters in static storage, so a counter from a previous call
came back. Once one wait hit its 20000-cycle limit, *every subsequent call* reported
`STALL: busy never dropped` on a memory that was answering in ten cycles - a cascade that
looked exactly like an intermittent design fault and sent a rewrite of the reader in the
wrong direction. The trailer test also reported `only 64 of 16 bytes`, which is the same
bug announcing itself arithmetically. All tasks in both testbenches are `automatic` now.

**The expectations assumed the pack filled the window.** A pack is 2 MiB − 16 bytes, so
`0x1FFFF0..0x1FFFFF` are outside it and read back as whatever the memory holds; the test
asked for the last byte of the *window* and called the answer a mismatch. Reading past the
end is a legitimate thing to test - it is what tells you the read path is not inventing
data - but it needs its own helper with no expectation, which `tb_rom` now has (`peek_one`).

### Two facts about the bridge, established rather than assumed

**`dataslot_allcomplete` exists in this APF revision** - it comes from
`core_bridge_cmd.v`, a single cycle in `clk_74a`, and `core_top` passes it to `aw_rom`. But
a file written into a bridge window need not be accompanied by the command that produces
it, so the design cannot depend on it. A check is therefore requested by that pulse, *or*
by "writes reached the trailer area and then went quiet for ~10 ms", *or* by an ~84 ms
retry timer, and retried until the trailer reads back sensibly. Failing the check does not
abort the loader: a half-written trailer is indistinguishable from a bad one, and aborting
would guarantee it never completes. `rom_error`'s `ERR_TRAILER` clears when a later check
passes; `ERR_OVERFLOW` and `ERR_WAIT` do not, because nothing gets better by asking again.

**There is no flow control on this bridge**, and the arithmetic does not work out:

```
bridge, one 32-bit write per cycle      297 MB/s
x16 ZBT, one access per two cycles       99 MB/s   (the chip)
this loader, sustained                   ~40 MB/s   (one entry per ~5 cycles)
```

so a host writing flat out cannot be absorbed by anything downstream, at any FIFO depth.
The design therefore has a 512-entry absorber and a loud tripwire, and `tb_rom` runs
`+TRIPWIRE` as part of the suite: a full-rate load must *report* the loss (it does, after
593 words) rather than play it back as a corrupt game. If hardware shows the purple
overflow screen, the ladder is: deeper loader FIFO (2048 entries is 6 M9K blocks of the
308 available), then striping the pack across `cram0` and `cram1` to double the drain, then
chunked loading with an explicit handshake. **This is the number most in need of measurement
on a real unit.**

### The VM's gap rule, which the ROM contract turns into a requirement

The 64-byte preload at `vm.si:483` is

```
while (data.addr != 63) {
    data.addr    = data.wenable ? (data.addr + 1) : 0;
    data.wenable = mem.data_available;
}
```

so a cycle without `data_available` sends the buffer's write pointer back to 0. Once a
held acceptance has delivered its first byte, the rest of the fill has to be gapless, or the
thread's instruction buffer is written in the wrong order. The reader handles it in two
parts: while `in_ready` is still high when the first byte would go out, it waits until 32
words are buffered (a pulsed single-byte read has by definition no cycles to wait, so the
fast path is unaffected), and if a gap happens anyway it rewinds its own address to the
acceptance's start and discards the generation - mirroring what the VM does, which is what
makes a stall harmless instead of silently corrupting.

`readByte()` (`vm.si:55`) turned out to need the opposite of the obvious thing: it raises
`in_ready` for one cycle and then waits for `busy` to fall *with `in_ready` low*, so the
byte has to be delivered after the request has gone, and `busy` must already be high the
cycle after the pulse - sooner than any memory can answer. Hence `mem_busy` has a
combinational term in the request itself, and the consumer keeps one byte owed until it is
delivered.

### Where the ROM path stands

`scripts/sim_rom.sh` on `part1.bin`, against a behavioral ZBT model:

```
tripwire:  full-rate bridge load reports ERR_OVERFLOW after 593 words     PASS
load:      2,097,136 bytes over the bridge, rom_ready, rom_error = 0
trailer:   reads back 00000000 000024e5 000010e1 00002ce5  (9445/4321/11493)
patterns:  64-byte fills at 0x0, 0x1 (odd), 0x2a00; 16-byte fill of the trailer;
           40 single-byte reads, repeats, last pack byte, first trailer byte;
           fill -> single byte at an unrelated address -> fill
result:    383 checks, 0 errors                                           PASS
```

Measured costs, which are the numbers to optimise against if the game turns out to run
slow: **94 core cycles per single-byte read**, **0.40 bytes per core cycle during a
64-byte fill**. The first is mostly the seek past up to 40 stale words; a synchronous
FIFO flush on restart would take it to ~15 and the fill to ~0.9 bytes/cycle. That is safe
to attempt *because* entries are address-tagged: a flush that lets a spurious word
through is caught by the word's own label, which is not true of a generation counter.

## Next, in order

1. **Find why the VM stops asking for bytes.** `tb_soc` shows it receives 224 correct bytes
   and then issues no further requests, with the screen black and `leds=00001110` frozen. The
   ROM is exonerated (every byte it delivered matched the image). The candidates are the VM's
   `while (rasterizer_busy | blitter_busy) { }` waits - `op_drawString` has one, and the intro
   draws text immediately - and the shared memory port, whose last address seen (0x2010d6) is
   above the 2 MB image and matches neither of `vm.si`'s two address constructions. Approach:
   trace `rasterizer_busy`, `blitter_busy`, `page_swap` and `out_vblank` in `tb_soc` against
   the VM's opcode stream, rather than touching `aw_rom`, which is now the best-tested thing
   in the tree.
2. **Then, and only then, look at the picture.** The S1 bar is the intro screen rendering;
   `tb_soc` writes PPMs, so the check is a real image, not a pixel count.
3. **Package the core**: `cores/aw/data.json` for the data slot (intended:
   `filename: "{osd_origin}/{osd_filename}"`, `extensions: ["bin"]`, `address: "0x10000000"`,
   `size: "00200000"`, `ways`, `onlaunch`, `timeout_ms`), `core.json` metadata, and a
   `Platforms/*.json` entry. The schema is still believed rather than verified -
   `developer.analoguecs.com` was not reachable - so treat the first hardware load as the
   test of it. `savestate_supported` stays 0: a save state cannot capture PSRAM contents
   through this architecture.
4. **Measure the bridge on hardware.** `sim_write`/`sim_rom` show the drain absorbs one 32-bit
   word every ~10 bridge cycles (~25 MB/s) and reports `ERR_OVERFLOW` past that; the real
   bridge has no flow control and no measured rate. If it writes faster than ~25 MB/s the
   ladder is: loader FIFO deeper (2048 entries = 6 of 308 M9K blocks), then stripe the pack
   across `cram0` and `cram1` to double the drain, then chunked loading with an explicit
   handshake. The purple screen tells you which world you are in.
5. **Stream-path latency, if the game turns out memory-bound.** 94 core cycles per single-byte
   read and 0.40 bytes/cycle on a 64-byte fill, both dominated by seeking past stale buffered
   words. A synchronous FIFO flush on restart should take those to ~15 and ~0.9; it is safe
   specifically because entries are address-tagged, so a spurious word is caught by its own
   label.
6. Keep `docs/another-world/port-log.md` honest as any of the above changes.

## Commands

```bash
./docker/run-silice.sh scripts/pocket_translate.sh          # .si -> aw_pocket_build.v
./docker/run.sh scripts/build.sh cores/aw --no-sigtap       # Quartus full flow -> rbf_r
python3 scripts/check_build.py --core-dir cores/aw \
        --expect-clock 24.75,24.75,49.5                     # audit the reports
./docker/run-silice.sh scripts/sim_rom.sh [pack.bin]        # ROM path simulation
make package CORE=aw                                        # -> build/sd + zip
```

Environment facts worth repeating: Quartus Lite has no `ip-generate-cli` (hence
hand-written PLL parameters, verified afterwards in the fit report);
`developer.analoguecs.com` is unreachable (JSON schema unverifiable); there is no
simulator in the Quartus image — `iverilog` and `verilator` live in
`local/ap-silice` and that is where design-side checks run.


---

## tb_soc: the whole design, and the bug only it could find

`cores/aw/src/sim/tb_soc.sv` + `scripts/sim_soc.sh` put the VM, the ROM, the ZBT model and
the bridge model in one simulation, release reset when the pack verifies, and write the
video pins out as PPMs. It was written to answer "does the intro render?", and the answer is
not yet - but it paid for itself before it ever drew a frame.

**The core as it stood could never have booted on hardware.** `M_main` drives
`out_mem_in_ready` **high while it is held in reset** - it is the VM's "I am ready for a
byte" default, not something its reset clears - and `core_top` holds that reset until
`rom_ready`. So `aw_rom` saw a request from a VM that did not exist yet, started streaming,
shared the ZBT with the loader, the load never finished, and the design reported
`ERR_OVERFLOW`. Every module was behaving correctly; only the combination was wrong, and
only a simulation with the VM, the ROM and the reset sequencing together could show it.
`aw_rom` now takes `vm_running` (driven from `design_reset_n` in `core_top`) and ignores
`mem_in_ready` until the VM is really running. The reasoning is in the port comment, because
the next person to read `aw_rom` will otherwise be tempted to call that port redundant.

**What it says now.**

```
pack loads, rom_ready, rom_error=0
video: 320 x 200, 40 frames captured, vsync and de well formed
rom:   every byte delivered to the VM equals the image byte at that address (checked)
vm:    224 bytes received, then no further requests - starving=0, so it stopped asking
       last mem_addr seen: 0x2010d6, leds=00001110, never changes again
screen: all 40 frames black -> FAIL, correctly reported
```

That is a useful place to be: the ROM's side of the contract is exonerated by an oracle
(`stream_base` recorded at each acceptance, each delivered byte compared against the image),
and the failure is that the VM stops issuing requests. `0x2010d6` is above the 2 MB image and
cannot come from either of `vm.si`'s two address constructions (`(1<<21)-32` for the trailer,
`(1<<20) | ...` for the pre-rendered strings), which suggests it is the *other* user of the
shared memory port - the blitter, which `a5k.si` says can read "from the front" - and that the
hang is on the VM's `while (rasterizer_busy | blitter_busy) { }` in `op_drawString`. That is
where the next session starts: trace the rasteriser/blitter busy flags, not the ROM.

The first version of this test *passed* with 40 black frames, because its pass condition was
"four frames and no mismatches". A test that reports success on a core that shows nothing
forever is worse than no test, so the condition is now "at least one non-black frame", and
the black case prints how many bytes reached the VM.

---

## The cram0 timing saga: a constraint that asked for a long wire

Worst slack on the PSRAM clock went from +0.1 ns (build4, pins unconstrained) to -3.3, then
-38.7, then -43.2 as the constraints got "better". The failing paths were always the same
shape and impossible on paper: **a register driving an output pin, zero logic levels, and
47.2 ns of interconnect** - to a pin three columns away, on a 20.2 ns period.

The cause was `set_output_delay -min -6.0`, which I had added to describe hold. Against a
same-clock model, a negative minimum output delay is a demand that the data path be at
least that long, and the fitter obediently made routes longer to comply. Removing the `-min`
lines took the worst path from -43 ns to -5.9 ns and the register-to-pin delay from 55.5 ns
to 10.5 ns. A `set_max_delay` that had been added to fight the symptom then became the
remaining violation - it applies to the data path alone, leaving 4.6 ns against a 6.96 ns
path which is roughly what this interface should cost - so it went too.

What remains, and why it is the honest model:

* The ZBT captures what the FPGA drives on the edge **after** the one that launched it, so the
  real launch-to-capture budget is a full period more than a same-clock `set_output_delay`
  assumes. That pessimism is kept deliberately: it is the difference between a build that
  reports a design which cannot work and one that lets the fitter scatter a source-synchronous
  interface across the die.
* `set_output_delay -max 3.0` on the address, control and data pins: the part's setup time plus
  a guess at trace and clock-skew on a board whose trace lengths are not published.
* `set_input_delay -max 12.0` on `cram0_dq`/`cram0_wait`: tCOV plus board.
* No minimum output delay. Hold here is not an in-FPGA question.
* Clock names: the generated-clock names must be spelled as the tool names them
  (`ic|u_pll|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk`); `[get_clocks clk_psram]`
  matches nothing and Quartus drops the constraint with only a 332049 warning.

**Result: full compile clean, worst slack +0.133 ns across all clocks, and
`python3 scripts/check_build.py --core-dir cores/aw --expect-clock 24.75,24.75,49.5` exits 0
with "no dead logic in the core's own modules". The cram0 output paths themselves sit at
+2.6 ns with a register-to-pin delay of ~7 ns. The number to watch is that
register-to-pin delay: if a change moves `aw_psram` away from the cram0 pins, it will show
there first. `scripts/worst_path.tcl` prints the paths the plain `.sta.rpt` only summarises:

```
./docker/run.sh sh -c "cd cores/aw/src/fpga && quartus_sta -t /work/scripts/worst_path.tcl"
```
