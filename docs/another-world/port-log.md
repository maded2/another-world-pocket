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

---

# 2026-10-01: the design reset was backwards, and that was the whole intro

The black screen had nothing to do with the ROM. `M_main.reset` is **active high** — the
generated code says `_q_count <= (reset) ? 0 : _d_count` — and `core_top` drove it with a
signal called `design_reset_n`, which is active **low**. So from the moment `rom_ready` went
up, the rasterizer and the blitter were held in permanent reset, and the only reason the core
did not look completely dead is that upstream ties the VM's own reset to constant 0
(`uint1 vm_reset(0)`), because upstream's ROM is SPI flash and is readable from the first
clock after configuration. A VM running against a frozen blitter stops asking for bytes at the
first `while (rasterizer_busy | blitter_busy) { }` (`vm.si:267`, and four more copies), which
is how "the ROM stopped answering" looked from outside.

The fingerprint, from tracing the generated netlist: inside `M_blitter_M_main_blit`, `count`
and `prev_count` sat at 0 while `busy` sat at 1 and `src_addr` (which is `_d_count`, the
*next* value, not gated by reset) sat at 1. Reset held, combinational logic alive, one
register with no reset term (`_q_busy <= _d_busy`) stuck set.

| | before | after |
|---|---|---|
| bytes to the VM in 120 frames | 224 | 124,205 |
| blitter | busy forever, never counted | completes at exactly 64,000 cycles |
| palette | — | 30 of 32 entries loaded, RGB565 values match the pack |
| page swap | none | 60 swaps, `show_page1` toggling |
| screen | black | still black |

**The lesson is not "check your polarity".** It is that a name ending `_n` connected to an
active-high pin is invisible to every test that does not instantiate the design. `tb_write`
and `tb_rom` passed throughout, honestly, because neither contains `M_main`. The bug was only
reachable with the VM, the design reset sequencing and the video pins in one simulation —
which is the entire justification for `scripts/sim_soc.sh`.

`aw_rom`'s `vm_running` gate stays, and is now correctly understood: the VM cannot be held in
reset by `M_main.reset` (its reset pin is wired to 0 inside the generated netlist), so
declining its memory requests until the pack is loaded is the only way to keep it off the
ZBT during the load. The earlier "M_main drives mem_in_ready high while in reset" note was
this same bug seen from the other end: it was not in reset.

## Tracing a generated netlist, and validating the probe first

Verilator resolves hierarchical references, so a testbench can read the generated design
directly: `_w_*` wires at `M_main` level (`_w_rast_busy`, `_w_blit_busy`, `_w_vm_blitter_src`,
`_t__page1_wenable`), `_q_`/`_d_` registers inside submodules, and the RAM arrays themselves
(`u_soc.page1.__mem__pixels.buffer[i]`). Before believing a single number read that way,
**round-trip a sentinel** — `tb_soc` now writes `4'hE` into `page1.buffer[123]` at start-up and
says so. A diagnosis built on a hierarchical read that silently reads a copy is worse than no
diagnosis.

What the probes established, in order:

1. `blit_busy` rises at byte 156 and never falls; `rast_busy` never rises. (pre-fix)
2. After the reset fix: blit completes, VM runs, palette loads, but `page0..3` contain **zero
   non-zero pixels** after 240 frames.
3. Not a missing write: `wen p1=1.9M, p2=2.0M` — millions of write enables reach the page
   modules, and `in_wenable` at the memory instance itself pulses 896,014 times.
4. `wdata_or = 0`: **every one of those writes carries the value 0.**

So the write path is sound and the content is the question. `src vm=64000` is one full-screen
write from the VM's own pixel port (a screen clear), and each blit is exactly 64,000 writes —
copies of a page that is itself empty. The intro is clearing and copying and drawing one
polygon in four seconds; the probe now running separates the two remaining explanations:
the game asking for colour index 0 (nothing in the pipeline is wrong, the game is in a state
where it has nothing to draw), or pixel addresses at or above 64,000 being dropped silently —
`buffer` has 64,000 entries but the address is 16 bits, so an out-of-range write disappears
without an error. `roob`/`boob`/`amax` are those counters.

## My own harness was lying three times

Each of these looked like a design bug first. All three were the test infrastructure.

* `docker/run.sh` and `docker/run-silice.sh` forwarded no environment, so `TRACE=1` and
  `FRAMES=8` were silently dropped: a trace run came back with no trace lines and still
  captured forty frames. Both wrappers now forward a documented set (`TRACE FRAMES PACE JOBS
  SIGTAP QUARTUS_ARGS`) when set.
* `sim_soc.sh` wrote its frames into `${TMPDIR:-/tmp}`, which inside the container is the
  container's own `/tmp` — every "go and look at a frame" instruction pointed at files that
  vanished when the container exited. Frames now default to `build/sim/soc-frames`, which is
  on the mount and gitignored.
* `tb_write`'s new WAIT test reported a design failure that was its own: it read `rom_error`
  on the same clock edge that observed `stall_wait`, and `rom_error` follows it through
  `aw_rom`'s status block one cycle later. Eight cycles of patience, and the design is correct.

## Two failure paths that had never run

* **`cram0_wait`.** `aw_psram_model` declared `wait_hi` and never drove it, so the design saw
  `x`, and `if (psram_wait)` reads `x` as false: `aw_psram`'s WAIT counter, its `stall_wait`
  output and `aw_rom`'s `ERR_WAIT` were dead code — in the one signal whose *polarity* is an
  assumption (the Pocket calls it `cram0_wait`, no bar, and this APF revision never uses it).
  The model now has a `force_wait` hook and `tb_write` holds it: `stall_wait` after 65,536
  psram cycles, `rom_error = 3`, `busy` correctly stays high instead of handing out a stale
  byte, and the bus recovers afterwards while the error stays painted (by design: a part that
  did this is not something to hand the game).
* **Everything at and above 1 MB.** `op_drawString` reads the pre-rendered string table at
  `1<<20`, and the intro draws text before anything else, yet every address `tb_rom` used sat
  below the window start. That is exactly where the 20-bit-tag bug lived (`0x100000` aliasing
  onto `0`), so it is now covered: index base, base+1, a 64-byte preload there, the byte
  before it, 0x180000, and a run up to the trailer. `tb_rom`: **484 checks, 0 errors**.

## Controls: believed, named, and one place to change

`cont1_key`'s bit positions come from Analogue's controller-word spec, which is documented
nowhere in this tree and could not be fetched. The code previously used upstream's *Lattice*
button indices, which are certainly wrong for the Pocket, and no simulation could ever show it
because `tb_soc` drives `jstick` itself and never goes through `core_top`'s packing. The five
bits are now `` `AW_KEY_RIGHT/LEFT/DOWN/UP/B `` (12/13/14/15/0, A as a second fire at 8),
overridable with `-D`, with the packing left alone because *that* is verified against
`a5k.si`'s MCH2022 mapping: `[0] right [1] left [2] up [3] down [4] fire`.

Symptom if the belief is wrong: the game runs, the intro plays, no button does anything, and
these five defines are the whole fix. `tb_soc` now also drives the stick the way upstream's
simulation does (`a5k.si:870`: up until cycle 70,217,342, then right) so that "nothing
renders" and "nobody pressed a button" are no longer the same test. `+NOINPUT=1` pins it low.

## Packaging content, and what is still believed

The metadata was template stubs; it is now real, and the packager checks it.

* `video.json`: **320x200**, matching `$$H_ACTIVE`/`$$V_ACTIVE`. It said 320x240, which makes
  Analogue OS rescale pixels it was never told about.
* `data.json`: one data slot — `{osd_origin}/{osd_filename}`, `.bin`, address `10000000`, size
  `00200000`, loaded on launch, `savestate_supported` false (a savestate cannot capture PSRAM
  contents in this architecture). The core only uses `bridge_addr[20:0]`, so any 2 MB-aligned
  window address works; `size` is the whole window rather than the pack's `0x1FFFF0` so a
  user's 2 MiB dump is not rejected.
* `core.json`: real shortname/description/author/date. `url` points at the upstream Silice
  design this is a port of, for attribution — point it at your own repository when there is
  one.
* `input.json` deliberately still declares no controllers: on the Pocket the mapping lives in
  the platform file and a plain gamepad works from the OS defaults. Inventing a `controllers`
  block in an unverified schema would be more likely to break input than to enable it.

`make package` is fixed in two ways that both matter. Each core now packages into
`build/sd/<core>` instead of a shared `build/sd`, and the zip is built from the manifest of
what this core owns instead of walking the output tree — previously `author.aw-0.1.0.zip`
contained twelve foreign files, including `Developer.CoreTemplate` *with its bitstream* and
`Platforms/ex_platform.json*. It is now 11 files, this core only. The packager also gained the
checks that would have flagged the stubs: a data slot list that is empty is an error in
`--release` (`the OSD cannot offer a file, so nothing is ever loaded`), and `video.json` is
cross-checked against the design's own `$$H_ACTIVE`/`$$V_ACTIVE`, which is the check that
turned the resolution mismatch from a review comment into a build error.

Still believed rather than verified: the data-slot field names (the Analogue developer docs
were unreachable all port; the first hardware load is the test), and the `cont1_key` bit map
above. Everything else in this file is backed by a simulation, a fit report, or a Quartus log.

## Make targets added

`make check-build`, `make worst-path`, `make sim`, `make sim-write`, `make sim-rom`,
`make sim-soc`, `make pocket-translate`. `scripts/sim_rom.sh` had been advertising
`make sim-rom` for weeks; it now exists. `scripts/build.sh` also gained a pre-flight check of
every source file named in the qsf, because Quartus answers a missing generated file with
"Can't resolve module name M_main" several minutes later, which points nowhere near the cause.

## Frame 230: the game is in a black-screen loop, and my probe had a bug too

Corrected probe (the trace line had 26 arguments against 22 format specifiers, so every field
after `wdata_or` was reading the wrong value — including the "rasterizer emits address 0" claim
in the section above, which was never actually measured). With the arguments fixed, at frame
230 (~4 s of game time):

```
nz p0=0 p1=0 p2=0 p3=0 | wen p0=66297 p1=3.6M p2=3.9M p3=0
src vm=64000 rast=2296 blit=7.5M | rpal_or=0 roob=0 amax=1d1f bdata_or=0 boob=0
```

What that says, and what it rules out:

* Addresses are fine: the rasterizer's pixel addresses run up to `0x1d1f`, and nothing goes out
  of range (`roob=boob=0`), so no write is being dropped for want of a valid address.
* The write path is fine (established earlier): enables pulse at the memory port itself.
* **The content is colour 0**: `rpal_or=0` and `bdata_or=0` - every pixel the rasterizer and the
  blitter has ever emitted carries palette index 0.
* The counters that matter are *frozen*: `vm=64000` and `rast=2296` have not moved since roughly
  frame 1 and frame 30 respectively, while `blit` keeps growing by 64,000 every frame or two.
  `wen p0=66297` is also frozen - page 0 was written once (a clear) and never again.

So the picture is: page 0 was cleared to index 0, and every frame the game blits page 0 onto the
displayed page. That is not a broken draw - it is a game in a black-screen state, running its
frame loop at real 60 Hz pace (about 1,000 ROM bytes and one blit per frame, which is the main
loop's housekeeping). The single polygon it did draw asked for `color=0`.

Next experiment, and it is the one that separates "my SoC top differs" from "the data pipeline
differs": run **upstream's own** simulation with the same pack (its README: `make simul1`, "no
need for an actual FPGA, this will run the intro in simulation"). If the same bytes draw content
there within a few seconds, the difference is in `aw_pocket.si` - and the first thing to test is
that upstream's main SoC block is `always_before` while mine is plain `always`, which in Silice
changes the evaluation order of exactly these muxes. If it stays black there too, the question
moves to the pack layout and the intro's own waiting conditions.

## The addresses the game asks for are above the pack window, and my mask hides it

Per-frame acceptance probe (25 specifiers, 25 arguments, checked): every **second** frame the
VM performs exactly **1152** acceptances over the range **0x20009e..0x2010cd**, identical
forever. That is a hard loop, and it is not the engine's frame housekeeping - because **no
address construction in vm.si can produce a value ≥ 0x200000 for this image**:

    mem.addr = segBytecode + threadsData.rdata      segBytecode is hard-wired 0 (vm.si:132)
    mem.addr = (1<<20) | (stringId<<1)              ≤ 0x12FFFE
    mem.addr = (1<<20) | (start<<8)+(start<<6)      string/pixel region
    mem.addr = (1<<21) - 32                         the trailer, 0x1FFFE0

But the observed range is exactly `(1<<21)-32` **plus the part1 segment offsets**:

    0x20009e - 0x1fffe0 = 0x9e    (trailer offset word 0 = bytecode, value 0, + the read walk)
    0x2010cd - 0x1fffe0 = 0x10ed = 4333  ≈ 4321 = part1's segCinematic

So the engine is reading at `trailer_address + segment_offset` - addresses past the end of the
2 MB window - and `aw_rom` answers them by **folding `mem_addr[20:0]`**, so `0x20009e` is served
from pack offset `0x9e`. The bytes are real, the oracle is satisfied, and the game is reading the
wrong place. "Byte-exact against the image" was never the same as "answers the question asked",
and a silent fold is exactly the mechanism that makes the two look identical.

This is now the prime suspect for the black screen, and it reframes it: not "nothing draws", but
"the engine is pointed at the wrong window, and the fold makes it look plausible". Two things
follow:

1. Find out which is true - the pack's base is 0 and these are out-of-range reads that upstream
   satisfies from a bigger/second flash region, or the pack is meant to be mapped at `1<<21` and
   the trailer walk in vm.si starts from there. Dump `segOffsets` as the VM actually loaded them
   and compare with the trailer bytes; the answer decides whether the fix is in the pack layout
   or in the address map.
2. **A fold must not be silent.** `aw_rom` should treat `mem_addr[23:21] != 0` the way it treats
   an overflow - report it (`ERR_RANGE`) rather than alias it. This bug would have been a status
   code on the first frame instead of four days of black-screen archaeology.

## A held-off slave must answer "busy" - and answering it exposed the next bug

`vm.si` opens with `while (mem.busy) {}` and then loads the segment table straight off the
byte bus:

    while (mem.busy) {}
    mem.addr = (1<<21) - 32;   ...   segOffsets = {mem.data, segOffsets[8+:120]};

`aw_rom` gated only `req` on `vm_running`, so during the pack load `busy` **fell to 0**. The
VM's wait passed and it latched whatever was on the bus as its four segment offsets, then ran
its whole life computing addresses from them - which is where the `0x20009e..0x2010cd` loop
and the `addr=3fffe0` readings come from: `0x3fffe0` is `(1<<21)-32` **with the garbage base
already folded in**. `tb_soc` has printed `in_ready=1 addr=3fffe0 busy=0` since the day that
line was added; it was the evidence, printed and not read.

`mem_busy` now includes `~vm_running`. Two things came out of it:

* The line changed to `in_ready=0 addr=200000 busy=1`: the VM waits, as it should, and no
  longer poisons itself. `data_available` pulses while the VM is held off: **0**, now a
  permanent check in tb_soc - the boot check does not leak bytes.
* **And the core then delivers nothing at all: 0 bytes.** With `busy` correct, the very first
  request after release is never served. So the garbage-boot was the only thing that had ever
  made the reader serve in the assembled design, and a second bug sits behind it.

That second bug is the next thing, and it is now precisely framed: with `busy` held high
during the load and released with `vm_running`, trace the first request - does `in_ready`
rise, is the consumer FSM still in `C_IDLE`, does `take` fire? The existing benches cannot
see this: `tb_write` and `tb_rom` tie `vm_running` high before the pack is loaded, so the
busy-held-during-load state has never been exercised anywhere but `tb_soc`. Note also that
the boot check is already gated with `!rom_ready`, so a check in flight is not the cause.

The ordering lesson is the one worth keeping: fixing a handoff bug can make a system visibly
worse, because the bug was load-bearing. `0 bytes` is a better place to be than `garbage
bytes`, but it does not look like it from the screen.

## Task 12: the packs are correct - verified against the program that makes them

The oracle for the game data is `Resource::dumpDataPack()` in the vendored forked
interpreter (`upstream/BUILD/Another-World-Bytecode-Interpreter/src/resource.cpp`), which is
what upstream's `ROMs/%.raw` rule runs. It writes:

1. the loaded RAM segments **reordered**: bytecode, cinematic, palettes, video2;
2. zero pad to `1<<20`;
3. `stringtable.raw` appended (so the pre-rendered strings live at >= 1 MiB);
4. zero pad to `(2<<20) - 32`;
5. 16 bytes of little-endian offsets: `bytecode=0`, `palettes`, `cinematic`, `video2`.

That is `2 MiB - 16 = 2,097,136` bytes, which is exactly the size of our packs, and the offset
block starts at `len - 16 = 0x1FFFFE0 = (1<<21) - 32` - exactly the address `vm.si` reads at
boot. The whole convention is the producer's, not ours.

Checks run:

* **Reproducibility**: two independent extractions (one into the tree, one into
  `build/packs-recheck` via `PACKS_OUT`) are **byte-identical to the packs already in the
  tree, 8/8 parts**. The packs are the tool's output, unmodified.
* **Trailer formula**: recomputed from the source and matched. `part1`: `data.si` gives
  `segBytecode=5124, segPalettes=9445`; the trailer holds `bytecode=0, palettes=9445,
  cinematic=4321, video2=11493`, and `9445-5124 = 4321` is `byteCode_size` in exactly the
  position the formula says.

So **the black screen is not bad packs**. This replaces my earlier praise of the pipeline,
which rested on a self-consistency rule; now it rests on the producer's own output.

### The part numbering has been off by one

`extract_packs.sh` loops `for n in 0..9` and writes `part$((n+1)).bin`, so
**`partN.bin = --extract=(N-1)`**. Upstream's rule is `ROMs/%.raw: ./raw --extract=$*`, so
`make simul1` runs `--extract=1` = our `part2.bin`. With the README's "the famous intro
section is the second part (the first is the protection screen)", the intro is
**`part2.bin`**, and every simulation run so far has been the **protection screen**.

### And the address map is pack-relative

The trailer sits at `len - 16` and the strings at `(1<<20) | x`, i.e. both are **pack
offsets**. The `iceprog -o 2M` / `send.py 2097152` in upstream's flow is the board's SPI
layout, not the design's address map. So the design's window is `0x000000..0x1FFFFF`
pack-relative; `aw_rom`'s 21-bit fold is accidentally right, and the `0x3fffe0` reading was
the poisoned segment base, not a second region. Task 17 makes that explicit and replaces the
silent fold with a reported error.

### Harness bug fixed

`docker/run-extract.sh` forwarded **no** environment, so `PACKS_OUT=...` was silently ignored
and a re-extraction wrote straight over the packs in the tree. Harmless here (packs are
regenerable and gitignored), but it is the same class as `run.sh` dropping `TRACE`/`FRAMES`:
a wrapper that drops the environment turns an override into surprise writes. It now forwards
`GAMEDATA` and `PACKS_OUT`.

## Task 13: the golden reference runs - and it says part2 is the intro

`scripts/setup_ref.sh` copies the pinned design to `build/ref/` (the pinned tree stays
untouched, `build/` is gitignored), translates `a5k.si` and builds Silice's Verilator
simulator. `scripts/ref_sim.sh PART=<pack>` runs it with one of our packs, captures the sim's
stdout and screenshots the VGA window, and reports colour statistics per frame. Also as
`make ref-setup` / `make ref-sim`.

    ./docker/run-silice.sh scripts/setup_ref.sh
    PART=/work/ports/another-world/packs/part2.bin SECS=24 SHOTS=3 \
      ./docker/run-silice.sh scripts/ref_sim.sh

Same design, same build, only the pack changes:

| pack | offsets the **design** reports | screen |
|---|---|---|
| `part1.bin` (`--extract=0`) | `0, 9445, 4321, 11493` | 0.0-0.2 % non-black, 3-4 colours |
| `part2.bin` (`--extract=1`) | `0, 75101, 9871, 110291` | 47-61 % non-black, 20-27 colours, changing frame to frame |

So **`part2.bin` is the intro and `part1.bin` is nearly black in the reference too**. Our port
has been staring at the protection screen and calling it a rendering bug. The S1 bar is now
`part2.bin`.

Two more things the reference gave up immediately:

* **The boot trace prints the segment offsets the design actually loaded.** That is the single
  best oracle for task 15: run the same pack through both and compare the printed line before
  anything else. `part1` matches our trailer exactly, all four words.
* **`segVideo2` is a 17-bit field and `part2` overflows it.** Our trailer holds
  `video2 = 241363`; the design reports `110291`, and `241363 - 65536*2 = 110291` - i.e.
  `mod 131072`, exactly the producer's own `offs_max = 1<<17` limit, which it checks and
  bypasses when `_segVideo2` is NULL. Task 17 should record that as an upstream limitation,
  not a bug of ours.

Harness notes found on the way:

* `silice-make.py` **exits 0 even when the make it launches fails**: a missing `GL/gl.h`
  produced `rc=0` and no executable. `setup_ref.sh` therefore tests for the binary instead of
  trusting the status code.
* The Silice Verilator framework needs `GL/gl.h` and `GLFW/glfw3.h`, and GLFW needs an X
  server: the image now carries `libgl1-mesa-dev libglu1-mesa-dev libsdl2-dev libglfw3-dev`
  and `xvfb x11-apps netpbm`, and frames are grabbed with `xwd | xwdtopnm`.
* `xwdtopnm` emits **PAM (P7) with 16-bit samples**, not PPM. A P6-only parser produced
  garbage statistics until fixed - a stats bug that would have made every frame look alike.
* The sim reads `../data.raw` relative to its cwd (`verilator_data.cpp`), so the pack goes one
  level above `obj_dir`.

## The VM boots and the pages fill: what the black frames turned out to be

With the `busy_q` deadlock gone (previous entry), running the intro pack through our own
testbench:

```
TRACE f6 : nz p0=59071 ... blit=251076 memwen1=128002 bdata_or=2
TRACE f9 : nz p0=58037 p1=0 p2=58037 ... rpal_or=7 amax=f8ea bdata_or=7
TRACE f13: nz p0=58037 p1=58037 p2=58037 ... wdata_or=7
frame 14: 320x200 colours=7 nonblack=64000 mean=13.3/145.4/51.7
```

So: pages are written with real data, the rasterizer draws at valid addresses (`amax=f8ea`),
the palette is live (`rpal_or=7`), and **pixels reach the screen**. The first non-black frame
is frame 14, roughly a quarter second after boot - which is why 20-frame runs looked hopeless
and 40-frame runs did not.

What is left is not a black screen. It is an alternating one:

| frames | `show1` | screen |
|---|---|---|
| 22-25, 30-33, 38-41 | 1 | colours=7, 64000/64000 non-black |
| 26-29, 34-37 | 0 | colours=1, fully black |

Every four frames the display select flips: three of the four frames show an empty page, one
shows the drawn one. The same four-frame period shows `acc=0 range=ffffff..000000` on three of
its frames - the VM makes no memory requests at all on those - which is the game's 15 fps
pacing (60 Hz / 4) showing up as it should. So the design is drawing once per game tick and the
**display mux is showing an empty page during the three idle frames of each tick**, instead of
holding the frame that was just drawn.

That is a much smaller claim than "black screen", and it is testable against the reference: the
question is what `_w_show_page1` does during the idle frames in upstream's build, and which page
module it selects there. Our probe counts `nz p0..p3` by module name, and the module name and the
display index are not obviously the same thing - that correspondence is the first thing to
nail down, with a sentinel, before any further reasoning about which page is blank.

Also confirmed by measurement, for task 17: the first acceptance after release is
`addr=3fffe0`, i.e. `(1<<21)-32 + 0x200000`. The SoC presents **flash-absolute** addresses with
the 2 MB base included - matching `iceprog -o 2M` - and `aw_rom`'s fold to `[20:0]` lands exactly
on the trailer. The fold happens to be right; it still needs to become an explicit, reported
address map rather than a coincidence.

## The intro renders: palette bank was tied to the page select

The 4-frame flicker was a porting error, found by reading upstream rather than by more
probing. `a5k.si:793`:

    palette.addr0 = {vm.pal_swap,4b000} | (vm.page_swap ? page1.rdata : page2.rdata);

which **page** to read is `page_swap`; which 16-entry **palette bank** to use is `pal_swap`.
`aw_pocket.si` used `swap_p1` for both, so the bank tracked the page - and only one bank is
live at a time, because `vm.si:759` writes an incoming palette to `{~pal_swap,...}` (double
buffered). Every frame displaying the other page looked up an empty palette. Fix: register
`pal_swap_p1` alongside `swap_p1` and take the bank from it.

`busy_q` needed a second, narrower fix. Clearing it when the consumer parks was wrong twice,
and both times a bench caught it rather than reasoning: without `c_served` it cleared between
acceptance and byte landing (`tb_rom` read `5a`, the unloaded-fill value, then drifted a byte
per read, 22 errors); with `c_served` it never fired at all, because the check exits through
`rewind`, which clears `c_served` on the way to `C_IDLE` (back to total deadlock, 0 bytes). The
claim that actually needs holding is that the **check's last byte lowers busy**:

    busy_q <= chk_active ? (chk_cnt != 5'd1) : host_rdy;

Bench results after the change, all three green:

| bench | result |
|---|---|
| `tb_soc` (part2 / intro) | 44 frames, **34 non-black**, 20,176 bytes to the VM -> **PASS** |
| `tb_rom` | **484 checks, 0 errors**, 0.40 B/cycle preload |
| `tb_write` | 0 errors, `rom_error=3` WAIT path covered |

Synthesis gate after the netlist change: build rc=0, `check_build.py` rc=0, minimum setup slack
across all reports **+2.541 ns**, hold +0.354 ns, 3,561 ALMs (19 %), 1,101,888 RAM bits (35 %),
`make package CORE=aw` -> 11 files, this core only, 0 errors / 0 warnings.

**What "renders" does not yet mean.** Our frame 40 is 7 colours dominated by greens
(`#088221` 36 %, `#10c342` 30 %); the reference screenshots show dark blue/grey tones. That is
*not* a colour comparison: the reference frames were grabbed at 8-24 s of wall-clock, far later
in the intro than our 44 frames (0.7 s). The next check should be oracle-based, not visual -
dump the 32 palette entries from the simulation and compare against the pack's palette region
decoded from RGB565 in python, at a matched game frame - and the reference should then be run to
the same frame count for an actual image diff.

## Task 20, part 1: segment table and palette both verified against the pack (and one false alarm of mine)

`tb_soc` now prints both, at the end of every run:

    SEGOFFSETS 00000000 0001255d 0000268f 0003aed3   (want 0,1255d,268f,1aed3 for part2)
    PALETTE32 1101 0008 2401 3501 4602 5703 7905 ab07 800b 000f 900c a00d c00e e00f f70f fa0f
            0000 ... (bank 1 all zero)

* **The segment table matches the reference exactly.** The golden sim prints
  `Hello Another World (offsets: 0, 75101, 9871, 110291)` for `part2`; `0x1255d = 75101`,
  `0x268f = 9871`, and the fourth field is the known 17-bit case (`241363 mod 131072 = 110291`) -
  our register keeps the full word, the reference's `__display` reads the 17-bit wire. That is
  also the sentinel for the probe itself: `u_soc.vm._q_segOffsets` is only trusted because it
  returns four numbers the reference agrees with. (`u_soc._q_segOffsets` does not exist; the VM
  instance is `u_soc.vm`.)
* **The palette is byte-exact correct - and my first check about it was wrong.** I wrote the
  entry below claiming the palette "cannot have come from the pack". It had. `vm.si` loads
  `mem.addr = segPalettes + (paletteId[8,8]<<5)`, 32 bytes = 16 little-endian RGB565 words into
  `{~pal_swap,...}`, and `paletteId[8,8]` is the **high byte**: the design loads a *numbered*
  palette block, not necessarily block 0. My check compared bank 0 of the palette RAM against
  `pack[segPalettes + 0*32]`, found 0/16, and reported a colour-path bug. The bytes were at
  `0x1257d`, which is `segPalettes + 32` - **palette #1**, and it matches **16/16 words**.
  Palette #0 is all zeros, which is exactly what an intro that fades up from black needs.

  The forensics that settled it cost no simulation at all: take the 32 bytes of our palette RAM,
  search for them in the pack, and read the displacement. `0x1257d - 0x1255d = 32 = one block`.
  When a value looks impossible, find where it actually is before concluding the producer is
  broken - the third time this effort produced a confident bug report against correct code, and
  the second time it was my own comparison that assumed an index.

So the memory path, the segment table and the palette are all verified against the pack, and the
only thing still unverified about colour is **frame parity**: our greens come from palette #1 of
`part2`, the reference's dark blues come from a screenshot taken seconds later in the intro. The
remaining check is to run both to the same game tick and compare, not to compare a frame at 0.7 s
with one at 8 s and call the difference a bug.

Also landed while here: `tb_soc`'s S1 bar now requires a *rich* frame and defaults to the intro
pack, both validated in each direction (`part2` PASS with 30 rich frames; `part1` FAIL "no rich
frame" despite running 90,721 bytes). A gate that cannot fail is not a gate.

## Task 16 answered, and it was not inert: the display overrides writes, mine does not

Asked whether upstream's `always_before` on its top block matters against my plain `always`.
The cheapest honest answer was to compare the two **generated** netlists - both builds already
exist - by counting the assignments to one shared signal, because Silice emits sequential
assignments and *last one wins*.

    upstream build.v                          mine aw_pocket_build.v
    _t__page1_addr = rast/blit src        (1)  _t__page1_addr = read_page1 ? fb_addr : src_addr
    _t__page1_addr = waddr        (write) (2)  _t__page1_addr = waddr          (write)
    _t__page1_addr = display addr     (3)      (no third assignment)

    _t__page1_wenable = 0   (default)
    _t__page1_wenable = 1   (write)
    _t__page1_wenable = 0   (display, LAST)    <-- absent in mine

Upstream's display stage is emitted last, so for the page under display it overrides **both**
the address (to the scan address) **and the write enable (to 0)**. That is the designed semantic:
*writes aimed at the page currently being scanned out are dropped.* Mine has no such override -
the write is emitted last, so the write wins, the address port goes to the write, and the display
gets a wrong pixel for that cycle while the write lands.

Both pages the display can show (`page1`, `page2`) receive writes in our runs - `tb_soc` measured
`wen p1=193814`, `wen p2=129813` - so this is not a corner case on our path. It is a credible
contributor to the remaining picture difference against the reference, and it is exactly the
class of thing that "the design renders something, so the port is fine" hides.

Note the shape of the finding: the question was "does block ordering matter", the answer is
"ordering *is* the semantics here", and it came from diffing generated output rather than reading
either source for intent. The follow-up task carries the exact change (base address, then write,
then a display override that clears `wenable`) and the verification it needs - matched-frame
comparison against the reference, benches green - because a page-arbitration change can regress
the render, and a regressed render plus a faithful rule is worse than faithful-and-aware.

### Follow-up landed (task 21): the arbitration is now upstream's

Implemented as specified and measured. Netlist shape matches (three `page1_addr` assignments with
the display last; `page1_wenable` 0/1/0 with the display last). Effect at frame 13, same pack and
run length: **page2 write-enable pulses 129,813 -> 65,812** - the fraction of time page2 is under
scan - while `nz`, colour count and mean brightness are unchanged and `tb_soc` still PASSes with
30 rich frames. So the game really was writing the page under display, and we really were
honouring writes upstream drops. Synthesis: rc=0, min setup slack +2.537 ns, ALMs down 26 (the
address mux is gone). Commit `04d188c`.

The picture did not change in these 44 frames, which is worth saying plainly rather than as a
disappointment: it narrows what can still differ from the reference to **frame parity** (task 20),
and it removes a class of divergence that would otherwise have surfaced later, in content the
intro's first second does not exercise.

## The packaged core was shipping a stale bitstream

Auditing the artifact rather than the code found it: `build/aw/bitstream.rbf_r` (the design with
the page-arbitration fix) is 1,339,248 bytes from 21:29, while the bitstream inside
`EddieChan.AnotherWorld-0.1.0.zip` was 1,338,484 bytes from 13:18. `make package` does not build,
and every check in the packager validates *what* it copies - file presence, JSON magic, resolution
against the design, this-core-only contents - never *how old it is*. So a core packaged before a
rebuild keeps shipping the old design with a clean report, indefinitely. Re-packaged and verified:
packed `sha256` now equals `build/aw/bitstream.rbf_r` (`3f5bf2d5…`), 11 files, 0 errors.

`package_core.py` now compares the bitstream's mtime against the newest file under `src/si` and
`src/fpga` and warns when the bitstream is older. `src/sim` is deliberately excluded: a
testbench cannot make a bitstream stale, and a freshness check that cries wolf on every edit gets
ignored, which is how such checks die. Verified in both directions - clean run 0 warnings; after
touching `aw_pocket.si` the warning fires (`1 warning(s)`); mtime restored to its recorded value
and the run is clean again.

Also corrected `date_release` (2026-10-01 -> 2026-10-03): the field describes the bitstream being
shipped, not the day the metadata was first written. `core.json` itself is otherwise sound - my
first audit pass reported it missing its identity fields, which was my check looking for
`core_id`/`core_name` at top level when Pocket nests them under `core.metadata` and
`core.cores[]`. Wrong check, not wrong artifact; noted here because the two look identical from
the output.

## Input path: proven from pin to game variable - and it exposed a hole bigger than the test

Nothing asserted anything about input until now. `tb_soc` drives `up`, then `right`, because the
opening scene waits for the player, but no test checked the VM noticed: "a button was pressed" and
"the game responded" are different claims, and for an action game only the second one matters. My
earlier note that the testbench "never drives jstick" was itself wrong - the signal is `js`, not
`jstick`, and a grep for the latter missed it.

The test asserts at two levels. Hard: `u_soc.vm.in_jstick` must equal what the tb drives, covering
the SoC port, the `jstick_delay` register and the wire into the VM. Softer but more meaningful:
`vm.si`'s per-frame input block writes the pad into the game's own variable RAM - `vmVars` at
0xE5 up/down, 0xFC left/right, 0xFD mask, 0xFA action, 0xFE action|0x80 - and `vm.h` in the
reference interpreter agrees with `vm.si` on every address. If those track the pad then the whole
path is proven, in the game's terms rather than mine. Result: **7/7 patterns** (none, right, left,
up, down, fire, right+fire).

Two things that looked like design bugs and were mine:

1. `m = {12b0, jstick[2], jstick[3], jstick[1], jstick[0]}` puts **UP in bit 3 and DOWN in bit 2**
   - swapped relative to the `lr`/`ud` decode three lines above it, which uses `jstick[2]` for up.
   I expected the sensible thing and got `mask=8` for up.
2. `jstick[4]` (fire) is **not in `m` at all**. Fire is OR-ed in as `0x80` *after* `HERO_POS_MASK`
   has been written, so 0xFD never shows fire; only `HERO_ACTION` (1) and `HERO_ACTION_POS_MASK`
   (`m|0x80`) do. Expected `0x10`, saw `0x00`.

Both are upstream's code, and reproducing them bit-for-bit is the requirement. This is the third
time in this port that "the design is wrong" turned out to be "my expectation was reasoned rather
than copied"; the fix in every case was to read the reference.

The first version of the test sampled the variables **once** at the end of the window and reported
that `right` and `up` did nothing while `left` worked. Both readings were true: the VM's input
block runs periodically (matched after ~702k cycles, ~1.7 frames), so a single-instant check passes
or fails on where the sample lands. Each pattern is now held for 8 frames while the variables are
watched every cycle for the first match - which asserts only what is guaranteed, and reports the
cadence for free.

### A FAIL verdict did not reach the process

To prove the test can fail, I injected a fault: the VM instance's `.in_jstick(_q_jstick_delay)`
tied to `6'b000000` in the generated netlist. The test behaved correctly - every non-zero pattern
failed, `tb_soc: FAIL - 12 errors` - but **the run exited 0**. `tb_soc` printed a verdict and
`scripts/sim_soc.sh` checks only `rc`, so a design failing every one of these checks was a green
build. The verdict is now a `s1_pass` flag and a failure calls `$fatal`, which exits non-zero.

Verified both directions: clean run `95 frames, 80 non-black, 76 rich -> PASS`, rc=0; faulted run
`FAIL - 12 errors`, rc=134; netlist restored by checksum afterwards.

Still not proven, and not provable from here: the Pocket `cont1_key` bit numbers behind `AW_KEY_*`
in `core_top.v`. `tb_soc` drives the SoC's jstick port directly and never passes through that
mapping, so the bit positions remain a belief - symptom if wrong is exactly "game runs, intro
plays, no button does anything". That belongs to the metadata check and the hardware checklist.

## Part numbering aligned with the game, and the `packs.txt` column that was noise

`make simulN` is upstream's simulation target and its README says "use N=1 for the intro"; it runs
`--extract=N`. Our extractor wrote `part$((N+1)).bin`, so **every part number in this repo was one
away from upstream's and from the game's**. That single off-by-one is what made the protection
screen the default test target and cost two wrong conclusions earlier. Files are now named by the
extractor index:

| new | old | extract | what it is |
|---|---|---|---|
| `part0.bin` | `part1.bin` | 0 | copy-protection screen — near-black in the reference sim too |
| `part1.bin` | `part2.bin` | 1 | **the intro** — upstream's `make simul1`, the S1 target |
| `part2..part7.bin` | `part3..part8.bin` | 2..7 | later parts |

The rename was checked, not assumed: hashes were recorded first, and the re-extracted set is
byte-identical to the recorded set (the producer is deterministic across runs, which is worth
knowing about the extractor). Log entries above this line keep the old names because they are the
record of what was run at the time; this table is the mapping.

**`packs.txt`'s `segVideo2` column was garbage.** It was scraped from the extractor's `data.si`,
and `$$segVideo2` is uninitialised there: extract 1 printed `-644595728`, `-730292240` and
`-831914000` on three runs of identical input, while the pack trailer held `241363` every time. The
other three columns were right, which is exactly how a broken table survives — and I had quoted the
video2 numbers in earlier reports. All four offsets now come from the pack trailer (last 16 bytes,
4 LE uint32s), which is what the VM reads at boot, so the table reports what the design receives.
Regenerated, it now cross-checks against the golden reference for both parts where we have
independent data: `part0` → `0, 9445, 4321, 11493` and `part1` → `0, 75101, 9871, 241363` (the
reference reports 110291 for the last one, being 241363 mod 2^17 through its 17-bit field).

`make packs` is also new: `extract_packs.sh` had advertised it in its own usage line since it was
written, and no such rule existed, so following the script's help produced
`No rule to make target 'packs'`.

Verified end to end after the change: default pack is `part1.bin`, role line reads *"intro - the
S1 target, upstream's make simul1"*, run `95 frames, 80 non-black, 76 rich -> PASS` rc=0;
`part0.bin` gives *"no rich frame (best 1 colours, 0 non-black, 110717 bytes to the VM)"* rc=134 —
the protection screen is still a failure by the S1 bar, now with an exit code that says so.

**What a first-time user should load: `part1.bin`.** They will see the intro sequence; the pad is
proven to reach the VM's own hero variables in simulation, but the Pocket's `cont1_key` bit numbers
are still unverified, so a real device may need `AW_KEY_*` corrected before buttons do anything.

## The controller mapping was wrong, and it was checkable the whole time

`cont1_key`'s bit positions had been left as a belief because they were assumed unfetchable. They
are on Analogue's own developer docs (Bus Communication page, fetched 2026-10-04):

```
[0] dpad_up   [1] dpad_down  [2] dpad_left   [3] dpad_right  [4] face_a  [5] face_b
[8..13] triggers   [14] face_select   [15] face_start
```

`core_top.v` had `RIGHT=12 LEFT=13 DOWN=14 UP=15 B=0 A=8` — APF-era community numbering, which
predates this word. Those bits are `trig_l3`, `trig_r3`, `face_select`, `face_start`, `dpad_up` and
`trig_l1`. On a real Pocket: the **d-pad does nothing**, **START walks the hero** (read as
`AW_KEY_UP`), SELECT reads as down, and d-pad-up fires. A second, independent bug sat in the same
expression: the packing put RIGHT in bit 4 and FIRE in bit 0, while vm.si reads bit 4 as fire and
bit 0 as right.

Both were invisible for the entire port because `tb_soc` drives the SoC's `jstick` port directly and
never traverses this mapping — the one untested link in the chain was exactly the link that decides
whether a button does anything. That is the argument for the fix being structural rather than a
two-line edit: the mapping is now its own module, `cores/aw/src/fpga/core/aw_keys.v`, with its own
testbench, `make sim-keys` (`src/sim/tb_keys.sv`, `scripts/sim_keys.sh`).

13 checks: every d-pad direction, both face buttons as fire (one action verb), combinations, all six
held, **start/select and shoulders/sticks producing nothing**, and the 3-deep synchroniser depth
(nothing at 2 clocks, updated at 3). Negative control: restoring the old bit numbers fails 7 of 13
and exits non-zero. `core_top.v` elaborates against verilator afterwards; only the Altera megacells
(`altera_pll`, `altsyncram`) stay unresolved there, which is expected.

Worth naming the failure mode: the previous comment block explained at length that the numbering was
a belief and where to change it. Being explicit about an unverified assumption is good practice, but
it is not a substitute for checking it — the network was available, the page was linked from the
vendored template's own README, and nobody fetched it. Two lessons: when a fact is load-bearing,
spend one HTTP request on it; and when a piece of logic is unreachable from the testbench, the fix is
usually to move the logic where it can be reached, not to note that it is untested.

Full field-by-field status of every declaration this core makes — including which `data.json` and
`core.json` fields are **not** defined on Analogue's pages and remain community practice — is now in
`docs/another-world/pocket-metadata.md`.

## Bring-up kit written (so the hardware session has a sequence, not vibes)

`docs/another-world/hardware-bringup.md` + `scripts/hw-bringup.sh` (a worksheet, `--save` to write it
to `build/`). No device was involved; this exists so the first one gets used properly.

The useful content came from what the core already reports rather than from invention: before
`rom_ready` the placeholder screen distinguishes black-no-sync, a white blink (alive, waiting for a
pack), **red** `ERR_TRAILER` (the offsets at `len-16` are not a pack), **purple** `ERR_OVERFLOW`
(the bridge outran the chip) and **amber** `ERR_WAIT` (the chip never accepted anything). That
legend plus the step order is what makes a blank screen answerable, and it also separates loader
starvation from a VM hang: still on the placeholder means the pack never verified; a held game frame
means it did and the VM stopped after that.

Eight steps, each stating what to do, what should be seen, what it proves and what failure implies.
Two are load-bearing for decisions already made:

- **timing the `part1.bin` load** (file confirm → first picture) is the effective data-slot rate
  that task #18 (direct random access) was explicitly gated on. The kit asks for seconds so that
  gate can actually be evaluated instead of argued.
- **START must not move the hero.** That is the hardware half of `25fd5ee`; simulation verified our
  mapping against the documented word, and this checks the word itself.

Also records that `part0.bin` being near-black is by design (the reference sim is equally dark), so
nobody opens a bug for it at 1am, and asks for five specific answers to report back: load seconds,
failure colour, input table outcome, soak result, whether parts 2 and 5 run on the same bitstream.

## Gate re-run 2026-10-08 (post controller fix) — all commands, all results

Rebuilt from the current tree rather than trusting the previous build, then every bench, then
packaged. Recorded with commands so it is reproducible, and the numbers compared against the last
gate rather than eyeballed.

| step | command | result |
|---|---|---|
| synthesis | `DETACH=1 RUN_NAME=aw-build ./docker/run.sh scripts/build.sh cores/aw --no-sigtap` | rc=0, `Full Compilation was successful` |
| timing | from that build | worst setup **+2.610 ns** (was +2.537), hold +0.120, pulse width +1.443 |
| utilisation | from that build | **3,523 ALMs / 18,480 (19 %)** — was 3,535, so `aw_keys` cost −12; 1,101,888 RAM bits (35 %) unchanged |
| report check | `./docker/run.sh python3 scripts/check_build.py --core-dir cores/aw --expect-clock 24.75,24.75,49.5` | rc=0, three PLL outputs as expected, no dead logic |
| write path | `scripts/sim_write.sh` | `rom_error=3 rom_ready=1, 0 errors -> PASS` |
| controller map | `scripts/sim_keys.sh` | **13 checks, 0 errors -> PASS** |
| ROM path | `scripts/sim_rom.sh` | tripwire fired **PASS**; **505 checks, 0 errors -> PASS** |
| SoC, intro | `scripts/sim_soc.sh` (`part1.bin`) | `95 frames, 80 non-black, 76 rich (best 10 colours), 45396 bytes to the VM -> PASS` rc=0 |
| SoC, protection | `scripts/sim_soc.sh ports/another-world/packs/part0.bin` | `FAIL - no rich frame (best 1 colours, 0 non-black, 110717 bytes to the VM)` rc=134 |
| package | `make package CORE=aw` | 11 files, 0 errors, **no staleness warning**, packed `sha256` == `build/aw/bitstream.rbf_r` (`0dfcd087…`) |

Two of those rows are negative controls, and they are the reason the rest means anything: `part0.bin`
**must** fail the rich-frame bar (it is the copy-protection screen, near-black in the reference too),
and `tb_keys` was checked against a mutant before being believed. The `rc=134` on part0 is new
behaviour and the point of the exit-status fix — a failing run can no longer be read as a green one.

`date_release` refreshed to 2026-10-08 to match the bitstream actually shipped, not the day the
metadata was first typed.

## Decision: one bitstream, part selection is data

Upstream compiles a design per game part with the section offsets compiled in, and its `variants`
machinery reflects that. **We ship one bitstream and treat the part as data**: `variants.json` has an
empty `variant_list`, and the part comes entirely from the pack's own trailer — the four little-endian
uint32s at `len−16` that the VM reads at boot — which is why no per-part rebuild is needed.

Supporting evidence, as opposed to argument: the same netlist boots `part0` and `part1` and behaves
differently in exactly the way the data says it should (part1 renders richly, part0 stays dark as the
reference does); `SEGOFFSETS` read back from the design equal the trailer/reference for both; packs
reproduce byte-identically across extractions; and `sim_soc` runs any part given as a path with no
rebuild. Cost is one 2 MB slot and a boot-time trailer read; benefit is one core folder, one
bitstream to test, and progress being a file swap rather than a re-flash.

The one part of this that remains reasoning rather than measurement is the device side, and the
bring-up kit makes it a single step: **load part1, then part2, then part5 without re-flashing**
(step 7 of `docs/another-world/hardware-bringup.md`).

Still open after this gate, stated plainly: everything above is simulation and a Quartus compile —
**no Pocket has run this core yet** — frame-level parity against the reference at a matched game tick
(task #20) has not been done, and the effective data-slot rate on device (task #18's gate) is still
unmeasured.

## Full-core simulation gate 2026-10-25 (tb_top + protocol-safe mux switch)

The biggest coverage gap so far was that **no bench ever instantiated `core_top`**: the idle
screen, the idle→game video mux, the final APF video pins, the audio pins and the full host
boot sequence were never simulated together. That is now closed by `tb_top`
(`cores/aw/src/sim/tb_top.sv`, run via `make sim-top`), which powers the whole core on from
t=0 and checks, in order: idle-screen palette (black / white blink / the red trailer-error
grid the retry check paints), APF video protocol on the idle stream, debug-UART behaviour
(traffic allowed, but TX may never stick low >3 ms), host status before load, a synthetic
pack trailer written through the real bridge window at the documented ~75-cycle pace,
`rom_ready` rising (trailer check against PSRAM readback), Reset Exit → `design_run`, the
mux switch to game video, 59 frame boundaries with at most one phase-jump frame, host status
after load (`{0x4F4B, idle}`), and audio pin rates (MCLK 122,880 edges / LRCK 480 rises in a
10 ms window, DAC silent). A self-checking APF protocol monitor
(`cores/aw/src/sim/apf_video_check.sv`, rules R1–R5 from the openFPGA video contract) is now
instantiated on the muxed output in `tb_top` **and** on the game pins in `tb_soc`.

### Design change: the mux switch is now protocol-safe (core_top.v)

Switching exactly when `rom_ready` rises was never safe: both rasters run free on `clk_core`
with a fixed but unpredictable phase offset, so a naive switch can glue an idle sync pulse to
a game sync pulse into a two-cycle pulse (R1 violation), and the line containing the switch
cycle carries the idle remainder of its line plus the game beginning — any partial mix is an
R5 violation. The switch now waits for a provably clean cycle:

- `i_x` counts cycles since the idle hs pulse; the idle DE window sits at `i_x [214, 533]`
  (measured in sim, not assumed). `i_safe = (i_x < 215) || (i_x > 533)` — landing there means
  the idle remainder of the transition line is exactly 0 or a full 320 DE cycles.
- `pulse_safe` uses one-cycle-delay copies of the idle pulses (geometry-free glue guard).
- The game side of the transition line is suppressed (DE and RGB forced to 0) until the next
  game hs, so that line carries exactly what the idle remainder had: one blank line in the
  first game frame instead of a mixed pixel count.
- Liveness: `i_safe` holds ~504 consecutive cycles every line and the pulse guard can block at
  most two of them, so the switch always resolves within one line.

### Bug found by the new bench: a dropped latch (and why the build report matters)

The first green run never came because an edit had silently dropped the
`always @(posedge clk_core) if (switch_now) video_sel_r <= 1'b1;` block, leaving `video_sel_r`
undriven. Verilator elaborated it as constant 0 with no warning under `-Wno-fatal -Wno-lint`,
so the mux flickered game/idle every line and the monitor reported "line carried 319 DE
cycles" on one drifting line per frame (319 = exactly the width of the unsafe `i_x` window —
the fingerprint that the excluded region itself was being output). **Quartus had warned about
it** ("object video_sel_r used but never assigned" in `aw.map.rpt`); the lesson is to scan
synthesis warnings, not just success/failure. Restored the latch; everything went green.

### Gate results (current tree)

| step | command | result |
|---|---|---|
| synthesis | `DETACH=1 RUN_NAME=aw-build ./docker/run.sh scripts/build.sh cores/aw --jobs 16` | rc=0, Fitter Successful |
| timing | from that build | worst setup **+1.261 ns** (PSRAM domain), hold +0.301, TNS 0.000 all corners |
| utilisation | from that build | **3,583 ALMs / 18,480 (19 %)**; RAM 35 % unchanged |
| full core | `make sim-top` (`tb_top`) | **all checks passed -> PASS** (idle palette, APF protocol clean across the mux switch with 0 phase-jump frames, pack→rom_ready, Reset Exit, host status, audio rates) |
| write path | `scripts/sim_write.sh` | PASS (make sim reached later targets) |
| controller map | `scripts/sim_keys.sh` | PASS (ditto) |
| ROM path | `scripts/sim_rom.sh` | 505 checks, 0 errors -> PASS |
| IV path | `scripts/sim_iv.sh` | 24 accesses, 0 X cycles -> PASS |
| reset gen | `scripts/sim_reset.sh` | all checks passed -> PASS |
| SoC + protocol | `scripts/sim_soc.sh` (part1) | 95 frames, 82 non-black, 78 rich -> PASS, **zero APF protocol violations** |

The transition frame landed on a clean raster boundary in this run (0 phase-jump frames);
the check accepts 0 or 1 because the offset is set by pack-load duration and is not
deterministic across boots.

Still open: no Pocket has run this core yet; frame-level parity against the reference at a
matched game tick (task #20) and the effective data-slot rate on device (task #18's gate)
remain unmeasured — both are bring-up-kit steps, not simulation gaps.

## 2026-10-29: read of `analogue-pocket-utils/mem/psram.sv` — the read bug was the byte enables

Nine hardware builds of silent reads, and the answer was in the known-good driver the whole
time. Diffed `aw_psram.v` against `ip/mem/psram.sv` from
[agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) (MIT) — same
cellular-RAM part, same Pocket mainboard, in users' hands as cartridge save RAM — and found
four real defects, one of which explains every address-echoing readback since build 1027.

**1. `UB#`/`LB#` are output enables, and reads never asserted them (the bug).** The reference
asserts both byte enables on the *read* branch too, held from the ADV# edge through the
capture. Ours asserted them only for writes. On this family of parts OE# low with both
enables high is *output deselect*: the part obeys the address and drives nothing. A floating
DQ keeps whatever was last driven on it, and the last thing driven is always the address, so
every read returned its own address — which is precisely what the self-test reported
(`T=f000`, `D=0000`) on every address, both dies, and every read timing tried. It was never a
timing problem, which is why no amount of re-timing changed it. Reads now assert both enables
on the same edge as CE# and the address and hold them to the capture; `aw_psram_model` now
models per-byte output deselect, so a controller that forgets them fails 510 checks in
simulation instead of passing all of them.

**2. The reference does *not* sample at ~75 ns, and the comment that said it does was the
reason a too-fast read looked validated.** Our notes recorded "the known-good reference
samples at ~75 ns with OE# low ~45 ns". It does not: its read states run from
`READ_INITIAL_COUNT = 20` to `STATE_READ_DATA_RECEIVED = 20 + TOTAL_READ_CYCLE_COUNT = 30`,
so it samples **thirty** cycles (225 ns at 133.12 MHz) after ADV# and holds OE# low eight of
them (~60 ns). Believing the bad number is what made seven cycles (75.4 ns) look like proven
practice. Worse, seven cycles was a violation even at 70 ns: the capture at sequence edge N
only asks the part for `N x 10.77 − 12` ns once this fabric's measured 7.4 ns clock-to-pin on
the cram0 outputs, ~1 ns of trace each way and ~2.5 ns of capture setup are counted — so the
seven-cycle read asked 63 ns of a part whose budget starts at 70, and STA cannot see it
because there is no clock at the part. Reads now run twelve cycles: ~117 ns of window at the
chip's pins against a 70 ns maximum, OE# low ~86 ns (more than the reference's proven 60 ns).
Writes stay at seven cycles — nothing is sampled there, so the clock-to-pin cancels, and the
upload drain needs the rate.

**3. A stale prefetch used to lock the read bus (`aw_rom`'s pop gate).** `pop` in C_RUN asked
`~n_v` instead of `~n_keep`. A seek leaves the prefetch register holding a word from the
search, so the reader entered C_RUN with `n_v=1` pointing at the wrong address: no pop could
be issued, nothing could land, no handoff could happen, and a fill rewound with 32 perfectly
good words sitting in the FIFO behind it. Invisible while the producer was accidentally
near-matched to the consumer's rate; fatal the moment a read cost 140 ns. A prefetch you
cannot use is the same as no prefetch — which is already the condition the landing handler
uses to replace it.

**4. The prefill gate was keyed to the wrong readiness signal.** `prefill_ok` tested `inr[0]`
(the VM's `in_ready`) with `chk_active` exempted, but the boot check's readiness is `chk_cnt`,
not `inr[0]` — so the check saw "host not ready", skipped the prefill, served byte 0 from a
drained FIFO, could not have word 1 two core cycles later, and rewound into the same
`chk_data` shift register forever: `rom_ready` never rose no matter how correctly the chip
answered. It now gates on `host_rdy`, whoever is asking. The reader's own ceiling is a pop
every two core cycles (the FIFO read is registered, `pend` is a register), so with one chip
access at 140 ns the buffer is not a margin, it is the entire mechanism; both comments now
say so with the arithmetic.

**Testbench defects found on the way** (`tb_iv_check`, the four-state contention bench):
`st_cfg` was left unconnected, so `(st_cfg == 2'd2)` was undefined and propagated X into
`CE0#`/`CE1#` — the model saw an unselected chip and drove nothing, so the bench was testing
nothing. Its stimulus also raced the design: blocking assignments from a process woken by
`@(posedge clk)` are sampled in arbitrary order, and it showed up as the model latching one
access's address with the *next* access's write data. Both fixed (tie `st_cfg`, drive with
nonblocking assignments), phase 1's payload now advances on the handshake rather than on a
fixed six-cycle step that skipped requests, and phase 2 now drops `rd_req` on the take instead
of one edge late, which had been issuing a duplicate read per iteration. Tag equality is
checked, not just data.

### Gate results (this tree)

| step | result |
|---|---|
| `scripts/sim_write.sh` | `rom_error=0 rom_ready=1, 0 errors -> PASS` |
| `scripts/sim_rom.sh` | **510 checks, 0 errors -> PASS** (self-test now: normal `a5a5`, byte-lane `a55a`, other die `a5a5`, CRE `a5a5`, pack word 0 matches the file) |
| `scripts/sim_iv.sh` (Icarus, four-state) | **24 accesses, 0 X cycles on DQ -> PASS**, tags checked |
| `scripts/sim_keys.sh` | 13 checks, 0 errors -> PASS |
| `scripts/sim_reset.sh` | all checks passed -> PASS |
| `scripts/sim_dbg.sh` | PASS (boot tag `AW 1035a up`) |
| `scripts/sim_soc.sh` (part1) | 95 frames, 79 non-black, 75 rich (best 9 colours) -> PASS, SEGOFFSETS correct |
| `make sim-top` (`tb_top`) | all checks passed -> PASS |
| Quartus (build 1035a) | clean: worst setup **+0.335 ns**, hold +0.143, pulse width +1.346, TNS 0.000 in every corner; **4,113 ALMs / 18,480 (22 %)**; `bitstream.rbf_r` sha256 `cab279d61af3a2df5ca6e72b12b855e77c5292b81486a6a74e26583a4ee51d64` |
| `scripts/check_build.py` | ok no dead logic; **ok every SDC constraint matched something** (the new 332049 check — the cram0 bounds had been silently dropped in every previous build) |

Self-test probe B was repurposed: "byte enables held low through the read" is no longer a
hypothesis worth testing on hardware (it is how the part works), so B now writes the scratch
word **with only the low byte enabled** on top of probe A's `A5A5` and expects `A55A` — the
only readback that proves the write mask masks, which the loader depends on for every
upload entry that straddles a word boundary. CHK line format is unchanged:
`C<err>:<32 hex> <match>/<all> S<status> D<d> B<b> N<n> R<r> P<p>`, expected `a5a5 a55a a5a5
a5a5 <pack0>`.

---

## 2026-10-29 (later): 1035a on hardware — the chip answers. What was left was byte order

First read-back this PSRAM has ever given. Boot tag `AW 1035a up`, and a CHK line every
second on the debug UART:

```
AW 1035a up
C1:d3ae03008f2600005d25010000000000 0007fffc/00080030 S47ff Da5a5 Ba55a Na5a5 R0000 Pe700
```

* **`D=a5a5`** — the byte-enable fix works: the part drives DQ and a round trip through it
  returns what was written. Nine builds of `Tf000`-style echoes, and that was the whole
  chip story.
* **`B=a55a`** — both byte lanes are live and the write mask masks.
* **`N=a5a5`** — the other physical die is alive too.
* **`R=0000`** — with CRE driven high the part stays mute. That is the answer to that
  probe: async mode wants CRE low, which is what normal operation does. Not a fault.
* **`0007fffc/00080030`** — 524,284 matched writes, 524,336 writes seen. The file is
  2,097,136 bytes = 0x7FFFC words, so **every word of the pack arrived inside the window**,
  and the 52 extra writes are the loader's command traffic. The upload is complete.
* **`C1`** = `ERR_TRAILER`, and `P=e700`.

The CHK field's variation from line to line (`d3ae0300…5d2501000003 0000` one second, clean
the next) is the console sampling `chk_data` while the check re-runs: it retries while
`rom_ready` is low, so it is mid-shift when the 66-byte line goes out. Not corruption — the
steady value is the one to read.

### The remaining bug: `bridge_wr_data` carries the lowest-address byte in its top byte

The 16 trailer bytes in the chip were the file's, but with each 32-bit entry's four bytes
reversed, so `offs_ok` compared `off3 = 0xd3ae0300` (the correct `0x0003aed3` written
backwards) against `< 0x200000` and failed. Byte-swapping the four groups of the read-back
gives exactly `[0, 0x1255d, 0x268f, 0x3aed3]` — part1's real segoffsets. `P=e700` is the
same fault: part1's first bytes are `04 00`, little-endian word `0x0004`, and `0xe700` is
the reversed entry's first half.

`aw_rom` took `bridge_wr_data[7:0]` as the byte for the lowest address. The APF wire is the
other way round: `core_top` ties `bridge_endian_little = 0` (the template default, a core's
declaration of what it wants, consumed by `core_bridge_cmd`'s swap mux), and the proven
loader in `analogue-pocket-utils/ip/data_loader.sv` — whose own testbench runs with
`bridge_endian_little = 0` — maps `bridge_wr_data = 32'hAABBCCDD` at address `C` to
`C<-AA, D<-BB, E<-CC, F<-DD`. Measured hardware agrees with the reference, not with us.

Fix (`aw_rom.v`): reverse the payload word once, where it is taken from the load FIFO
(`ld_wire`), and take both the byte-masked and the whole-word paths from it.

**Why 510 checks missed it**: the benches fed the design the order it assumed. So the swap
now lives in the benches' model of the framework (`tb_write.wr32`, `tb_rom.bridge_write32`
and `load_full_rate`, `tb_soc.wr32`, and a new `tb_top.slot_write32` — host commands at
`0xF8000000` keep their own path through `core_bridge_cmd` and are deliberately untouched),
and the design reads the word the way the wire delivers it. Negative control: putting the
little-endian reading back, with the benches still modelling the framework, makes
`scripts/sim_write.sh` fail with 506 errors and `rom_ready=0`. A DUT/bench agreement is not
evidence; the reference and the hardware are.

### Gate results (1036a tree)

| step | result |
|---|---|
| `scripts/sim_write.sh` | `rom_error=0 rom_ready=1, 0 errors -> PASS`; **with the little-endian reading restored: 506 errors, rom_ready=0 -> FAIL** |
| `scripts/sim_rom.sh` | 510 checks, 0 errors -> PASS |
| `scripts/sim_iv.sh` | 24 accesses, 0 X cycles on DQ -> PASS |
| `scripts/sim_keys.sh` / `scripts/sim_reset.sh` | 13 checks / all checks -> PASS |
| `scripts/sim_dbg.sh` | PASS (boot tag `AW 1036a up`) |
| `scripts/sim_soc.sh` (part1.bin) | `rom_ready=1 rom_error=0 after 162 cycles`; 95 frames, 79 non-black, 75 rich; `SEGOFFSETS 00000000 0001255d 0000268f 0003aed3` -> PASS |
| `make sim-top` (`tb_top`) | all checks passed -> PASS |

**What 1036a should say on the wire** (`scripts/sd_install_1036a.sh`, identity
`Eddie Chan.AW 1036`, refuses the 1035a SHA `cab279d6…`):

```
AW 1036a up
C0:000000005d2501008f260000d3ae0300 <match>/<all> S<status> Da5a5 Ba55a Na5a5 R0000 P0004
```

and the idle grid should switch to the game. `rom_ready` rising is the milestone; the trailer
and `P=0004` say the bytes in the chip are the bytes in the file.

## 2026-10-31: the game runs on hardware, in the wrong colours — palette is 12-bit nibbles, not rgb565

1037a showed the first animated picture on a Pocket panel. The counters said everything a
raster can say:

```
C0:0003aed30000268f0001255d00000000 0007fffc/00080030 S47ff Da5a5 Ba55a Na5a5 R0000 P0004
  V0008e8 F0fa00 L0fa00 Y00128d97 X6d   ->   V0010e0 ... Y0031ba69
```

`V` +2040 frames in 34.5 s = 59.1 fps against a 60.000 Hz design; `F=0xfa00` = a full
320x200 window scanned every frame; `Y` grew ~59 kB/s, so the VM was executing and fetching,
and with a 2 MiB pack it was re-reading scripts the way a bytecode VM does; `X=0x6d` =
saw_hs, saw_vs, design_run, video_sel, rom_ready all set, suppress and inmenu clear.
The user's report: "it is running ... but the color seems off".

The palette bank the VM had loaded, read back out of the SoC's BRAM in simulation:

```
PALETTE32 1101 0008 2401 3501 4602 5703 7905 ab07 800b 000f 900c a00d c00e e00f f70f fa0f
```

Decode those as the game does and they are the crash sequence: a blue ramp
`0x2401 -> 0xab07` stepping (16,32,68) to (116,168,184) for the night sky, and a fire ramp
`0x800b -> 0xfa0f` going (184,136,0) red-orange through (252,236,0) to (252,252,168) near
white. `aw_pocket.si` was reading the entry as rgb565 - R = bits 4..0, G = 10..5, B = 15..11 -
which turns that blue ramp green (8,128,32) and that fire violet (88,0,128). Recognizable
shapes, wrong everything else. The same misreading explains an old note in this log about
"the greens on frame 40": there were no greens in the intro.

Authority, in order of usefulness:

1. `sysImplementation.cpp::setPalette` in the reference interpreter, which renders *this*
   pack data: with `c1 = p[0]`, `c2 = p[1]`, `r = (((c1&0x0f)<<2)|((c1&0x0f)>>2))<<2`,
   `g = (((c2&0xf0)>>2)|((c2&0xf0)>>6))<<2`, `b = (((c2&0x0f)>>2)|((c2&0x0f)<<2))<<2`.
   12-bit, one nibble per channel, and the low nibble of the first byte is unused.
2. `a5k.si:800` decodes the same three nibbles in hardware, and its comment - like the
   interpreter's - calls the format 565. Both comments are wrong; both implementations
   agree with the numbers above. A comment describing a format is worth nothing next to
   code that consumes the format.
3. The vm assembles the pair as `{second, first}` (`vm.si: clr = {mem.data, clr[8,8]}`), so
   for entry E in the palette ram: **R = E[3:0], B = E[11:8], G = E[15:12], E[7:4] unused**,
   and a nibble n becomes `{n, n[3:2], 2'b00}` - the reference's own 4->8 scaling, full
   scale 252, kept deliberately because it is what reference screenshots are made of.

The oracle that came with the fix is worth more than the fix: `tb_soc` now keeps the set of
decodings of every palette entry the design has ever held, and fails on any colour that
reaches the screen from outside that set. Written first, it failed against the rgb565
netlist with colours like `08a231`; after the fix, 95 frames pass with every colour an exact
nibble decoding. It also caught a second bug on the way: Silice slices are `[start,length]`,
so writing `r4[3,2]` to take the top of a `uint4` reads bit 4, which Silice pads with zero -
the fill bits came out 0 and every channel landed ~4 counts low (0x4602 gave 32/64/96 instead
of 32/68/100). A person describing a screen would not have caught that, and neither would I.

Gate: tb_soc 95 frames / 75 rich / 0 errors, tb_top all checks, tb_dbg (tag 1038a),
tb_write, tb_rom, tb_iv, tb_keys, tb_reset PASS. Build 1038a: no 332049, worst slack
+0.114 ns, 4,278 ALMs (23%), sha256 0694cdae9a... (build/aw/bitstream.rbf_r).

## 2026-10-31 (later): 1038a on hardware — first launch black, relaunch fine; and the census that found why

1038a on a Pocket gave the right colours and a new symptom in one go. First launch after
power-on: black, with

```
F=fa00  L=0   Y climbing ~4.6 kB/frame   (healthy: a full window scanned, all black, ~0.55 kB)
```

Quit and relaunch: the game. A VM executing *something*, a full raster, and the picture only
appears once the pack has been uploaded a second time. Nothing in the design could see the
difference, because the upload's evidence is `dbg_wr_match` — *addresses* seen in the pack
window — plus two real read-backs in the whole 2 MiB: word 0 (`P=0004`) and the trailer
(`C0`). Everything between those two reads had never been checked as a whole.

Two candidates, and the cheap one got tested first: uninitialized BRAM (the palette/pages are
declared `uninitialized` in `aw_pocket.si`) was ruled out with `tb_soc +FUZZ_BRAM=1`, which
paints the four video pages, the palette and the polygon stack with noise before the game gets
them — 87 rich frames, boot unaffected. That left "the upload did not commit", which the
design cannot currently observe at all.

### The instrument: a whole-pack census in `aw_rom`

The write side accumulates every 16-bit word it *commits* (`d_taken`, not `d_act`) — sum, xor,
four quarters — and records the high-water word. Once the pack is in, one read-only sweep goes
back over exactly `0..cw_max` through the self-test's sequencer and accumulates again. Equal
means the chip holds the file; the quarters say where it does not, without a per-word bitmap.
11.1 sequencer cycles per word measured (`365,169` cycles for 32,768 words), so the full pack
is ~11.7 M cycles = **~126 ms with the VM still in reset**, once per power-on. `rom_ready`
waits on it — but only when one was armed, and only until `cen_budget` (~0.67 s) expires,
because a diagnostic that can hold boot is a black screen with extra steps.

### What it found before it shipped: six pack bytes lost per self-test probe round

`wr_taken = wr_req & wr_ready` was shared by the two bus masters. The self-test forces `wr_req`
high for its own probe write while the loader's drain sits in `D_RUN`; the drain saw `wr_taken`,
advanced, and consumed a word whose address and data never went anywhere. Measured in `tb_rom`
at PACE=10: **three 16-bit words missing every 5,520 words (11,040 bytes apart), matching
`ST_PERIOD` = 41,250 cycles ≈ 444 µs exactly.** 510 checks passed it, because none of them read
the whole pack back. Each master takes its own acceptance now (`d_taken`, `st_taken`); dropping
`~ld_abort` from `d_taken` in the process was itself a second bug of the same shape and
`tb_write` caught it (`rom_ready=0`, "busy never fell").

The independent proof is the byte-exactness check in `tb_soc`, which had *never compared a
single byte in any run* (its anchor carried the `+0x200000` bank bit, so the range test was
false from byte zero). Fixing the mask, the 1038a netlist serves the VM 9 wrong bytes, one of
them a run of `5a` — the PSRAM model's power-up pattern, i.e. a region of the chip nobody had
written. The fixed `aw_rom`: none.

### Second finding: the bench accused the ROM of three errors it did not commit

Those nine became three, all of them at `k=0`, and they were the *bench*. The VM changes
`mem_addr` one or two cycles before it raises `in_ready`, and the last byte of the old stream is
delivered in between, so the checker re-based on the new address and compared the old stream's
final byte against it. `+READ_TRACE` (now `READTRACE=1` in `scripts/sim_soc.sh`) settles it in
four lines — the design had taken that byte legitimately one cycle earlier, tag matching,
`rewinds=0`, with its own `ACCEPT addr=0022dd` still one cycle away:

```
R114300350000 TAKE addr=0125a0 byte=00 cw=0f00 tag=0092d0 lvl=25 n_v=0
R114300390000 LAND addr=0092d1 word=00ff st=3 want=0092d0 lvl=25
  ROM GAVE WRONG BYTE t=114300390000 addr=22dd got=00 image=84 (k=0) c_addr=125a1 c_tag=92d0 rewinds=0
R114300511000 ACCEPT addr=0022dd
```

The checker now anchors on the design's own `accept_vm` (new stream) and `rewind` (same stream
from the start again), and ignores `mem_data` while `chk_active` means the bytes are the boot
check's trailer reads. Anchor to the design's events, not to your model of them.

### Third finding, from the build itself: 1039a failed STA, and the census caused it

```
Slack -0.385 / TNS -0.682  (Slow 1100mV 85C)  clk_psram (general[2], 10.774 ns)
  from aw_rom|u_sfifo|rptr_sync2[5]  to  aw_rom|u_psram|psram_lb_n     (6 levels, 56% interconnect)
```

`p_allow` — the stream FIFO's free-space compare, synchronised pointer → grey-to-binary →
subtract → compare — was feeding `rd_req`, and `rd_req` is half of aw_psram's `take`, which is
what loads the chip-facing byte-enable registers. The fifo lives three columns from the cram0
I/O cells and the fitter has no reason to close that gap. One flop (`p_allow_q`) ends the
comparison beside the fifo and leaves one level between the flag and the bus. The cycle of
staleness buys at most one extra accepted read; `FETCH_HEADROOM` is 7 words against at most two
reads in flight, and the request stays a level held until taken, which is the contract
`aw_psram` depends on. It also stops letting the asynchronous `sf_level` sample propagate
through arithmetic into a chip control register. Result: **+1.254 ns** on that clock.

`ST_WAIT` got a timeout in the same pass: the sequencer is shared and `st_active` gates the
producer, so a probe whose readback never arrives does not lose a probe, it starves the ROM path
for the rest of the power cycle.

### Gate and build (1040a)

### Then `make check-build` caught two more, both inside the census

```
map: aw_rom|cw_q[2][*] - Stuck at GND due to stuck port data_in      (64 of these)
map: aw_rom|census_limit[21], census_addr[21] - Stuck at GND
```

The quarter index was written `addr[CEN_QSHIFT+1 +: 2]`. `+:` starts **at** the base bit, so
that is bits [20:19] — and the word address only has bits [19:0]. The index could therefore only
ever be 0 or 1: quarters 2 and 3 were registers tied to zero, and the "which part of the pack
went bad" half of the instrument was quietly two halves. Simulation could not have noticed: the
sums that `Z` reports are computed independently and stayed correct, and a real mismatch would
still have been flagged — just with a map that could only ever name two of four buckets. The
total was never in danger; the *resolution* was, which is the kind of defect only a tool that
reads the design as built sees.

The fix (`addr[CEN_QSHIFT +: 2]`) came with the check that should have had it from the start:
`tb_rom` now fails if any quarter on either side is still zero after a clean sweep, and the
`+SKIP=<word>` negative control asserts that the mask names the quarter holding the withheld
word. Mutation test — putting the `+1` back, same bench:

```
  FAIL: quarter 2 never accumulated (written 00000000 read 00000000) - the range or the index is wrong
  FAIL: quarter 3 never accumulated (written 00000000 read 00000000) - the range or the index is wrong
  tb_rom: 519 checks, 2 errors -> FAIL
```

The two stuck top bits on the sweep registers were the same class of finding and are gone the
honest way: the cursor and its end are `$clog2(CENSUS_RANGE)` bits wide and hold the *last index*
rather than a limit, so nothing in them is unreachable (a 2 MB pack lives in one die, so the
die-select bit was never going to move). "It costs nothing to keep the width" is wrong when the
width is the thing the fitter is complaining about.

### Gate and build (1040a)

| step | result |
|---|---|
| `scripts/sim_rom.sh` | **519 checks, 0 errors** — census `sum_r == sum_w == 1f4b8fbe` over the swept range, `qmism=0`, all four quarters accumulating; `+SKIP=<word>` still flags a withheld write and the mask names its quarter |
| `scripts/sim_write.sh` | `rom_ready=1 rom_error=0`, 0 errors |
| `scripts/sim_soc.sh` (part1) | 95 frames, 82 non-black, 78 rich, **0 errors** with the live per-byte check; `SEGOFFSETS 0,1255d,268f,3aed3` |
| `sim_iv` / `sim_keys` / `sim_reset` / `sim_dbg` / `sim-top` | PASS (dbg tag `AW 1040a up`) |
| Quartus 1040a | **no negative slack in any corner** (psram setup +1.217 ns slow-85C, +0.392 fast-0C; worst anywhere +0.126 ns), no 332049, 4,775 ALMs (26%), `make check-build`: *no dead logic in the core's own modules*, every SDC constraint matched something. `build/aw/bitstream.rbf_r` sha256 `888b1c056d70…` |

Netlist regenerated from the committed `aw_pocket.si` and byte-identical to the one the 11:02
build used, so the palette fix is in this bitstream and was in 1039a's too.

### What 1040a has to say on the wire, and what it settles

The census sums little-endian 16-bit words over exactly the range the upload wrote —
`0xffff8` words for every part file — so **the expected numbers are known from the file before
the card is even made**:

```
AW 1040a up
C0:000000005d2501008f260000d3ae0300 <match>/<all> Da5a5 Ba55a Na5a5 R0000 P0004
    V<frames> F<de/frame> L<lit/frame> Y<rom bytes> X<status> Z.0 dd744c92/dd744c92
```

`dd744c92` = `sum(struct.unpack('<1048568H', open('part1.bin','rb').read())) & 0xffffffff`
(part0 `3d05a6cb`, part2 `cc836d51`, part3 `06e27bde`, part4 `f0f9552e`, part5 `9cace960`,
part6 `fccf3bab`, part7 `7213f501`). `Z.` with both sums equal to the file's means the 2 MiB in
the chip *is* the 2 MiB that was sent, and the black first launch is not the upload: the search
stays on the boot/VM side. `Z!` with the quarter mask names a 512 KiB range (word bits
[19:18]). `ZT` is a stalled sweep — the read path is the suspect. `ZP` forever means no upload
completed. If the first launch is still black while a relaunch works, and Z is `.` on both,
then the pack is identical in both cases and the difference is in what the VM is released with.

---

## 2026-10-31 (late): the text shear — 1041a, and the checker that was mirroring the bug

### The report from the card

1040a ran on hardware with the census reporting the pack intact, and the answer that came back
was about the screen: **the text renders, but every pixel line of it is offset to the left.**

That sentence is precise, and so is the cause. It cost a day to find because the bench had been
agreeing with the design about a bug only the consumer could see.

### Why 270 frames of part1 told me nothing

`vm_pix` (the VM's direct pixel port, the only thing `op_drawString` writes through) had been
`0` in every part1 run. Not a bug: the intro simply does not draw text. The reference trace
(`build/ref/p1trace/trace.log`) has 1,662 `op_drawString` calls with `skip=0`, the first at
cycle 76,226,813 — around frame 181 at the reference's 420 k cycles/frame — and our 95-frame run
was nowhere near it. A 400-frame run reached frame 270 with `vm_pix=0`, `rast=595675`,
`blit=6400100`: an animating game that had not yet drawn a string.

The fast path to the code is **part0** (the copy-protection screen). Its reference trace shows a
full-screen strip drawn almost immediately:

```
[    582808] op_drawString id=  614 x=    0 y=    0 color=65535 start=07ba stop=0882 len=  200 skip=0
```

`len=200` is 200 rows × 320 bytes = **64,000 pixels in one call**, and in our design that strip is
written at **frame 14**. Twenty-five frames and the whole text path has been exercised.

### The design fault

`aw_rom`'s stream reader had one recovery for "the word the consumer wants next is not here yet":

```verilog
wire rewind = (c_state == C_RUN) & want & c_served & ~take & ~handoff;
...
end else if (rewind) begin
    c_addr       <= c_start;      // <-- back to the address the acceptance began
```

For a one-byte `readByte()` that is nearly harmless. For `op_drawString` it is not: the VM sets
`mem.addr` once, holds `in_ready` for the whole strip and advances `pix_waddr` once per byte
(`vm.si`), so **every byte the reader hands out a second time shifts everything written after
it**. Nothing tells the VM a restart happened — there is no signal for it in `mem_io`.

Measured on part0, 25 frames:

```
TEXT strip 1: dst=1 (x=1 y=0) at stream byte 12709 frame 14
STREAM RESTART t=233533241000 mid-acceptance, after 158 bytes (base=19a880)
STREAM RESTART t=233544877000 mid-acceptance, after 316 bytes (base=19a880)
STREAM RESTART t=233556513000 mid-acceptance, after 474 bytes (base=19a880)
TEXT  : 1 strips, 64000 writes, drift=0 value=0 rewinds_in_strip=405
```

Every restart after **exactly 158 bytes**. That number is the stream FIFO emptying: `SDB=6`, so
64 words plus the ones already in the pipeline, drained because a PSRAM word costs ~140 ns while
the VM consumes two bytes every ~80 ns. The producer is slower than this consumer, so on a long
stream the FIFO always ends up empty and the recovery always runs.

So the 200-row strip became **the same 158-byte pattern repeated**, and the row stride is 320:

```
320 = 2*158 + 4      -> each row starts 4 bytes further along the pattern than the row above
```

A leftward drift of ~4 pixels per text line, wrapping every 40 rows. That is what the card
reported, and it is the only mechanism that produces a *shear* rather than speckle: a wrong byte
value can only speckle, and a wrong destination address can only misplace a pixel.

### Why the bench defended it

`tb_soc` has had a per-byte ROM check for days, and it said 0 errors throughout. Its rewind
handler was:

```systemverilog
end else if (u_rom.rewind) begin
    served_k = 0;    // same stream, same base, handed out again from c_start
end
```

Mirroring the design. A re-served byte then compared against the position the design had just
rewound to — and matched, every time. **The oracle had been taught the bug's own idea of the
stream.** `served_k` now advances on every byte and resets only on a new acceptance, which is
how the VM sees it.

A second oracle was added because address and content are different claims. During a strip the
bench now checks, per write:

| check | what it pins | catches |
|---|---|---|
| `drift` | `pix_waddr − base == bytes consumed` | mis-adding the destination (stride/skew) |
| `value` | `palid ⊆ byte[3:0]`, and only ever with `byte[4]` set | enable/colour not the same byte as the data |
| `content` | the byte equals `ref_mem[src + k]` | the stream handing out the wrong bytes |

`content` compares against the **image**, not against anything the design believes.

Writing it also produced the one honest measurement of the VM's own 1-pixel skew: the strip for
`x=0 y=0` begins at destination `1`. `pix_waddr` is incremented by the same clocked assignment
that sets `pix_wenable`, so the pixel from byte *k* lands at `base+k+1` — and that is upstream's
code, compiled by the same Silice, so it is in the reference design too. One pixel, not ours, and
not a shear.

### The fix

```verilog
end else if (rewind) begin
    start_addr_r <= {2'b0, c_addr[20:1]};   // the word containing the byte still owed
```

`c_addr` already names the next byte the consumer has *not* been given, so re-seeking its word
loses nothing. `c_start` lost its last reader and is deleted — a 21-bit register nobody reads is
dead logic, and `make check-build` is right to say so.

The same recovery had been re-feeding the boot check's shift register from the trailer start,
which is one reason the trailer could fail to validate however well the chip answered.

### After the fix, same 25-frame part0 run

```
WRONG-BYTE: 0     (with the byte index no longer resetting on restarts)
TEXT  : 1 strips, 63999 writes, drift=0 value=0 content=0 rewinds_in_strip=405
CENSUS: arm=1 active=0 done=1 timeout=0 at word 2047 qmism=0 sum written=011057d6 readback=011057d6
```

Accounting for every number rather than admiring them:

- **405 restarts still happen** — the throughput deficit is not gone, it just stopped being a
  data fault. Each costs a re-seek (~140 ns), ~0.12 ms over the whole strip: invisible.
- **63,999 counted writes** for a 64,000-byte strip: the monitor's strip-start branch handles the
  first write's cycle and does not fall through to the counter. Byte 0 is now content-checked in
  that branch too, so nothing in the strip goes unexamined. Every byte of the region has `bit4`
  set (`part0` offset `0x19a880` starts `10 10 10 10 11 11 11 11`), so 64,000 opaque pixels is
  exactly right.
- **0 wrong bytes with 405 restarts** is the proof that a restart is now lossless: the byte
  counter never stopped, and never disagreed.

### Negative control: new oracle, old design

`git show HEAD:cores/aw/src/fpga/core/aw_rom.v` (the pre-1041a reader, which restarts at
`c_start`) dropped under the *new* tb_soc, part0, 25 frames:

```
ROM GAVE WRONG BYTE t=233538614000 addr=19a922 got=11 image=10 (k=162)
                                c_addr=19a885 c_tag=cd442 n_addr=cd442 rewinds=1
TEXT CONTENT strip 1 write 162: pixel 163 (row 0 col 162) got 11, image byte 10 at 19a922 (k=162)
wrong-byte lines: 399 (the print cap)   content lines: 6
```

One line carries the whole mechanism: the VM is at byte `0x19a922` while the reader's `c_addr` is
`0x19a885` — **158 bytes apart**, exactly one pattern, starting at the first restart and never
recovering. The same tree with the fix reports 0. So the check does see the fault, and 1041a is
what removes it.

### Two things this leaves open, said plainly

- **The throughput deficit is untouched.** The stream FIFO still drains every ~158 bytes on a
  long strip because the producer (1 word / ~140 ns) is slower than this consumer (2 bytes /
  ~80 ns). It is now a stall instead of a corruption, and 405 stalls cost ~0.12 ms, but the
  asymmetry is real and a faster read cycle would remove the stalls entirely.
- **`make check-build` must be scoped**: `make check-build CORE_DIR=cores/aw`. With no scope it
  also audits `cores/core-template`'s own Quartus reports and reports its
  `vidout_skip`/`vidout_rgb` stuck bits, which are not our netlist at all — `vidout_*` appears
  nowhere in `cores/aw`. Scoped, the answer for this build is *no dead logic in the core's own
  modules*, worst slack **0.129 ns**, clocks 24.75 MHz and 92.8125 MHz, every SDC constraint
  matched, no 332049, no negative slack in any corner. Bitstream `5b7ab7d5e7f0d80b…`.

### Gate for 1041a, and the one number that explains the long silence

| step | result |
|---|---|
| `sim-write` / `sim-keys` / `sim-rom` / `sim-iv` / `sim-reset` / `sim-top` | PASS (tb_rom 519 checks, 0 errors; `all four quarters accumulated on both sides`) |
| `sim_soc` **part0**, 25 frames | strip written at frame 14: **1 strip, 63,999 writes, drift=0 value=0 content=0**, 405 restarts, **0 wrong bytes** with the byte index no longer resetting |
| `sim_soc` **part1** (the intro), 150 frames | **PASS** — 134 non-black, 130 rich, best 16 colours, 0 errors. `TEXT: 0 strips` (the intro draws no text) and **`STREAM: 0 restarts`** |
| census in sim | `arm=1 done=1 qmism=0`, `written == readback` (`011057d6` for part0's swept range, `024c337f` for part1's) |
| `make check-build CORE_DIR=cores/aw` | no dead logic in the core's own modules, every SDC constraint matched, worst slack **+0.129 ns**, clocks 24.75 / 92.8125 MHz, no 332049, no negative slack in any corner |
| bitstream | `5b7ab7d5e7f0d80b…`, installed as `Eddie Chan.AW 1041` (folder == `author.shortname` verified by the installer) |

**`0 restarts` on part1 is the number that matters for "how was this invisible"**: the intro's
reads are short — `readByte` acceptances of one or two bytes — so the FIFO never drains and the
recovery never runs. The fault only exists on *long continuous streams*, and in this game there is
exactly one kind: `op_drawString`. Every part1 run ever done was clean, honestly, because part1
never asks the question.

### Installer bug, found by its own check and worth keeping

`scripts/sd_install_1041a.sh`'s first run printed `DONE.` having failed two things:

1. the `description` I wrote had continuation lines with no closing quotes → Python
   `SyntaxError` → `md["shortname"]` was never set, so the card kept the repo's
   `"Another World"` on a folder named `Eddie Chan.AW 1041`. `folder != author.shortname` is the
   documented way to ship a core the Pocket cannot launch.
2. **the script runs with `set -u`, not `set -e`**, so both python blocks failing printed their
   message and bash walked on — past the identity `FATAL`, through the cache clearing, to `DONE.`
   A safety check that cannot stop the script is a print statement.

Both fixed: the description is properly quoted, and each block now ends
`|| { echo "FATAL: …"; exit 1; }`. Re-run end to end afterwards: `core.json updated:
shortname='AW 1041'`, `identity verified: folder == 'Eddie Chan.AW 1041'`, bitstream sha
`5b7ab7d5e7f0d80b…`, 8 packs present.

## 2026-11-01: the two consumers — why no single resume address can fix both (1042a)

Four builds chased two symptoms that turned out to be one mechanism with two faces. The hardware
table that started it, measured on one Pocket:

| build | resume a stalled stream at | text | intro |
|---|---|---|---|
| 1040 | `c_start`, the acceptance's first address | **sheared** ~4 px/row | **plays** |
| 1041 | `c_addr`, the next byte the VM owes | **straight** | **freezes ~10 s**, same place every launch |

Reading 1041 as a regression of 1040 (or the reverse) was the wrong frame. Both are correct for
one consumer and fatal for the other, and the two consumers are in the same file:

```
vm.si:491   // the 64-byte bytecode fill loop
    while (data.addr != 63) {
      data.addr = data.wenable ? (data.addr + 1) : 0;   // <-- a gap RESETS the write pointer
      data.wdata   = mem.data;
      data.wenable = mem.data_available;
    }
vm.si:935   // op_drawString
    pix_waddr = mem.data_available ? pix_waddr+1 : pix_waddr;   // holds its place across a gap
```

So a cycle without `data_available` in the middle of a fill sends the *consumer's* write pointer
back to 0, and continuing the stream at the next byte owed hands the byte for `base+0x2c` to
`fill[0]`. Every later byte lands shifted, the interpreter executes the tail of the buffer as
opcodes, and the machine stops with opcode `0x80` and no further page swaps — while the delivery
is byte-exact the whole time. `op_drawString` does not care about gaps at all, but it is destroyed
by being served a byte twice: that is the shear, and 320 mod 158 = 4 px/row is its fingerprint.

### The oracle that could see it (a8b93c5)

Every check up to now anchored on the delivery, and the delivery is correct. tb_soc now watches
the consumer's own write port — `u_soc.vm.__mem__data` (module `M_vm_M_main_vm_mem_data`, 64 x 8
bits) — and requires each write to equal the pack byte at `acceptance_base + write_address`.
`data.wenable` is written in exactly one place in vm.si, so every write to that BRAM is a fill
byte and is attributable. Clean part1, 115 frames:

```
tb_soc: diagnostics - bytes to VM 48236 (compared 48232, outside window 4), restarts 0, frame swaps 34 (last at frame 114)
tb_soc: acceptances - bytecode-fill 554 (0 waited for a byte before finishing, 0 early gap cycles of 553 total), tolerant 10405 [5 gap cycles], pulses landing with in_ready low 11518
tb_soc: fill buffer - 35456 writes, 0 landed on the wrong byte of the pack, 0 with no acceptance open
-> PASS
```

Two counters died getting there, both measured rather than argued:

* **"a `data_available` pulse landed while `in_ready` was low" is not a lost byte.** 29904 of
  part1's 121834 bytes were counted that way, and it *gated* the S1 verdict. `readByte` (vm.si:56)
  raises `in_ready` for one cycle and then takes `mem.data` when `busy` falls — it never reads
  `data_available`. That counter was counting the design's most common correct behaviour.
* **"a gap inside a short held acceptance" is not the fault either.** Classified by *length* it
  fired on 558 of 559 fills of the healthy run above — the gap is the tail cycle after the fill
  has finished writing. Classified by what the acceptance **did** (writing the fill buffer is what
  makes an acceptance gap-intolerant) and counted only where a gap could still move a write, the
  same run reports 0. The block stays in the file, disabled, so nobody re-arms it.

### The A/B, with the stimulus proven present

The modelled PSRAM answers fast enough that part1 shows **zero** restarts, so in a normal run every
policy delivers identical bytes and the comparison is a rerun. `STALL=N` makes the wanted word
absent for one core cycle every N delivered bytes — what twelve cycles of tAA does when a successor
misses its landing cycle. `scripts/ab_resume_policy.sh`, part1, `STALL=64`:

| variant | restarts | fill writes / shifted | page swaps | verdict |
|---|---|---|---|---|
| 1040 (`c_start`) | 1919 | 102,370 / **0** | 57, last at frame 175 | FAIL — 105 wrong bytes where the consumer really is positional |
| 1041 (`c_addr`) | 5 | 282 / **121** | **0, ever** | FAIL — no rich frame, 3.27 MB streamed to a spinning VM |
| **1042** | 1911 | 102,114 / **0** | 57, last at frame 175 | **PASS** — 155 rich frames |

1041's first shifted write, spelled out by the bench:

```
FILL SHIFT t=84767208000 fill base=0: the VM wrote fill[0] = 00 but the pack byte at base+0 is 04
(the byte it put there lives at base+50; accepted so far 44, gaps so far 128, rewinds 1, c_addr=2d)
```

That is the freeze: 44 bytes in, one missing cycle, and the byte for `base+0x2c` lands at `fill[0]`.

The middle row of that table was also the check on my own fix. The first version declared
`resume_addr`, documented it, let tb_soc probe it — and left the `rewind` branch resuming at
`c_addr` anyway. Under the same stimulus it produced 121 shifted writes, byte-for-byte 1041's
result. A wire nothing consumes is not a policy, and this is the second time this week a test
caught me describing a change instead of making it.

### The fix (e812baa)

```verilog
wire resume_from_start = ~c_start[20] & (acc_cnt < 7'd64);
wire [20:0] resume_addr = resume_from_start ? c_start : c_addr;
```

`op_drawString` and the boot-header read ask for data with **address bit 20 set** — vm.si builds
them as `(1<<20) | (start<<8) + (start<<6)` and `(1<<21) - 32` — and both hold their own position,
so they continue at the next byte owed and are never served a byte twice. A bytecode fill asks for
a bytecode offset (segBytecode is `off0`, and the boot check requires `off0 == 0`, so it is always
below the megabyte), and its pointer went to 0, so it continues from 0 — where the re-served bytes
are exactly the ones it will write next. Self-healing too: if the restarted fill gaps again its
pointer is already 0, so it restarts from 0 again rather than shifting.

Second half, which is what keeps the rule from ever being needed: `PREFILL_WORDS` was 32 words =
64 bytes for a 63-byte fill — zero margin, none at all for an odd-address start, and the delivery
rhythm (one word per two core cycles, registered pop, handoff bypass) has no slack to absorb a
late arrival. It is 40 now; `LOOKAHEAD` was *already* 40, so the producer had always been willing
to run this far ahead and the gate simply never asked. Cost is ~1.1 us of prefill on the ~4.8 held
acceptances a frame. Measured effect on the copy-protection screen: **405 restarts → 326**.

Clean runs after the fix are unchanged where they should be, which is the check that the margin
costs nothing on the healthy path:

* part1: PASS, same numbers as before the change (48,236 bytes, 0 wrong, 35,456 fill writes / 0
  shifted, page swaps continuing to the last frame).
* part0: PASS, kind=text — 1 strip, 63,999 writes, `drift=value=content=0`, 326 restarts, 37,504
  fill writes / 0 shifted, and **0 wrong bytes**, because a strip is bit-20 and was not re-served.

tb_soc stands aside from the positional byte check for an acceptance that deliberately re-serves
from its own start — that repeat *is* the correct continuation for a fill, and calling it wrong
cost 36,531 phantom errors before the oracle learned the difference. Standing aside is counted and
printed (`stood aside for 759 acceptances ... 38030 bytes`), never silent, and the fill oracle
still checks every byte.

### Said out loud, so the next reader does not find it alone

* **A palette load also sits below the megabyte and does hold its position** (`vm.si:763` keeps
  `n`), so a gap inside one is now re-served and shifts that palette. Cosmetic, needs a gap inside
  a 64-byte read, and the margin is what makes it rare. The alternative corner is a dead machine.
  If the Pocket shows wrong colours and no freeze, this is the cause.
* `check-build` would call the simulation knob's `stall_tick` dead logic, so it moved inside the
  `ifdef AW_STALL`. A test hook that produces a report the flow is there to produce is a bug.
* `da_not_accepted` is still printed, because the older logs count it and it is the size of the
  pulsed-read population. It gates nothing.
* Telemetry (restarts / resume-at-start / held-gap cycles on real hardware) was cut from 1042a on
  purpose to keep its diff and timing risk to the thing it tests. It is task #13 for 1043, and
  until it exists the margin value 8 is a judgement rather than a measurement.

### Gate for 1042a — what the sim and the toolchain answered

Bitstream `build/aw/bitstream.rbf_r`, sha256 `579746d33d45b594…`. Identities it replaces on the
card are archived: 1040 = `888b1c056d70ec4a…`, 1041 = `5b7ab7d5e7f0d80b…` (both also still on the
card on purpose, under `scripts/sd_install_1042a.sh`, which refuses to install if the bitstream it
is given is either of those two).

| step | result |
|---|---|
| `make sim` (unit suite) | `tb_write` PASS · `tb_keys` 13 checks 0 errors · `tb_rom` 519 checks 0 errors, tripwire fired · `tb_iv` 24 accesses 0 X cycles on DQ · `tb_reset_gen` PASS · `tb_top` PASS (59 frame boundaries, MCLK 122880 edges/10 ms, LRCK 480 rises/10 ms) |
| `sim_soc` part1, clean, 115 frames | **PASS** — 103 non-black, 99 rich (best 16 colours), 48,236 bytes to the VM, 48,232 compared, 0 wrong, 35,456 fill writes / **0 shifted**, 34 page swaps with the last in the final frame |
| `sim_soc` part0, clean, 80 frames | **PASS** (kind=text) — 1 strip, 63,999 writes, `drift=value=content=0`, 326 restarts all inside the strip, **0 wrong bytes**, 37,504 fill writes / **0 shifted**, and `stood aside for 0 acceptances`: a strip is bit-20, so nothing was re-served |
| `sim_soc` part1 with `STALL=64`, 175 frames | **PASS** — 1911 restarts, 102,114 fill writes / **0 shifted**, 57 page swaps last at frame 175, oracle stood aside for 759 re-serving acceptances (38,030 bytes) |
| `sim_soc` part1, clean, **655 frames** (~11 s of design time, past the frame 553 where the hardware freeze was first seen in sim) | **PASS** — 636 non-black, 632 rich (best 16 colours), 829,810 bytes to the VM, 827,667 compared, 0 wrong, **31 restarts on the natural path** (so restarts do happen in part1 without the knob, just not in the first 115 frames), oracle stood aside for exactly those 31 fills (2,077 bytes), **676,317 fill writes / 0 shifted**, 240 page swaps with the last at frame 647 |
| same stimulus, 1041's policy | 282 fill writes / **121 shifted**, **0 page swaps ever**, 3.27 MB streamed to a spinning VM |
| same stimulus, 1040's policy | 102,370 fill writes / 0 shifted, but **105 wrong bytes** where the consumer is positional |
| **1041's policy, no knob at all, 600 frames** | **FAIL, last page swap at frame 553** — 56 of 163,525 fill writes landed on the wrong byte of the pack, then 2.17 MB streamed into a spinning VM. Frame 553 is where the freeze was first written down in sim, from the hardware report. The natural restarts plus resume-at-`c_addr` reproduce the reported bug at the reported frame with nothing forced: the knob was never the point, it only makes the wait shorter. First shifted write: `fill base=268b: the VM wrote fill[27] = c8 but the pack byte at base+27 is 08 (the byte it put there lives at base+32; accepted so far 32, rewinds 1, c_addr=26ac)` |
| verdicts shown able to fail, in both directions (`PACK_KIND=` override, no RTL change) | part1 graded as `text` → `FAIL - pack kind is text and 42716 bytes reached the VM, but op_drawString never laid down a single strip in 80 frames`; part0 graded as `rich` → `FAIL - 80 frames, no rich frame (best 1 colours, 0 non-black)`. A per-pack verdict that cannot fail in one direction is only a permission. |
| on the card (`scripts/sd_install_1042a.sh`) | `Eddie Chan.AW 1040` `888b1c056d70ec4a` · `Eddie Chan.AW 1041` `5b7ab7d5e7f0d80b` · **`Eddie Chan.AW 1042` `579746d33d45b594`**, 8 packs present, `folder == author.shortname` verified, `/System` caches cleared after a backup |
| `make build CORE_DIR=cores/aw` | 0 errors; `Fitter (171000) was successful`, `Assembler (11888)`, `STA (335001)` all successful |
| `make check-build CORE_DIR=cores/aw` (scoped) | **worst slack +0.135 ns** (1041a's baseline was +0.129 ns — it got better, not worse), `no dead logic in the core's own modules`, `every SDC constraint in compile.log matched something`, clocks 24.75 / 92.8125 MHz |
| sim knob out of the netlist | `stall_block` / `stall_tick` appear nowhere in `compile.log` or the map report — `AW_STALL` is simulation-only, and `stall_tick` was moved inside the `ifdef` so it cannot become the dead logic check-build exists to find |

Still open, and not hidden here:

* **The hardware answers the two real questions** (intro past a minute; captions straight). Sim
  showed the natural failure all along — it just needed a run long enough to reach frame 553, and
  `0 early gap cycles` in a 115-frame run was never evidence of anything.
* **`PREFILL_MARGIN = 8` is a judgement, not a measurement.** part0's restarts going 405 → 326 is
  the only evidence; without telemetry on the device (task #13) there is no way to tell a margin
  that is enough from one that merely delays the failure.
* **The bench's frame accounting is inconsistent and I did not chase it.** `FRAMES=60` reported 115
  frames, `FRAMES=25` reported 80, but `FRAMES=120` once reported 17 while still PASSing, and the
  600-frame run has passed 695. `run_until_frames` waits on `frames < max_frames`, so the budget is
  evidently not what bounded the short run. Harmless for these verdicts (each is self-consistent),
  but "just run it longer" is how a late freeze gets found, so it needs understanding before it is
  relied on.

### Hardware verdict, 2026-11-01: 1042 plays. Reported from the device, by eye.

`Eddie Chan.AW 1042` — bitstream `579746d33d45b594`, `aw_rom.v` from commit `e812baa` — **works:
the intro plays and the text is straight.** Both symptoms that the two predecessors each traded
against the other are gone, so the per-consumer resume policy is the right axis, and this is the
first build of this port that plays at all.

What that verdict rests on, stated honestly, because two of the three legs are not mine:

* **The measurement is the user's eyes, not my telemetry.** That is the correct instrument here,
  not a fallback: the `C0:` status line has **no page-swap counter**, and the freeze we chased is
  precisely "swaps stop while video keeps ticking at 60 Hz and the VM keeps burning bytes". A
  frozen 1041 and a playing 1042 look identical on UART. So "it is working" could not have come
  from the port, and anyone who reads `V`/`Y` climbing as proof of gameplay is reading a field
  that cannot go wrong.
* **The UART did not, and cannot, confirm which build ran.** `dbg_console.v:65` still hardcodes
  `MSG_UP = "AW 1041a up\n"` — never bumped, so 1040, 1041 and 1042 all print `AW 1041a up`. The
  banner that the comment calls "tag = build id" has been lying since 1041 shipped. Identity in
  this entry is therefore the folder launched plus the hash the installer verified: 1040
  `888b1c056d70ec4a`, 1041 `5b7ab7d5e7f0d80b`, 1042 `579746d33d45b594`.
* **What the 94 s of capture does support:** `V` 3660 → 9300 = 60.0 frames/s monotonic with no
  core reload, `Y` 2.57 MB → 7.23 MB, `err 0`, `R 0000` (no CRE errors), selftest `Da5a5 Ba55a
  Na5a5`, `Z.` (the 2 MiB survived the round trip), `P0004` = part1, and `inmenu` asserting at
  16:59:27 when the game was left. 826 bytes/frame is inside sim's own range for part1 (419 early,
  1267 later), so the device VM and the simulated VM are reading at the same rate. Nothing
  contradicts a healthy run; nothing proves one either.

**Not re-run today, and it should be:** the two controls. The entries `1040 = text shears, intro
plays` and `1041 = text straight, intro freezes ~10 s` come from earlier sessions. They are what
the whole two-consumer theory is built on, and they cost a minute each to re-confirm on this card.
If either behaves differently now, this build's result is not interpretable, and the hash table —
not the label — is how that gets settled.

Three hardware fields were proposed for a 1043 at this point: a page-swap counter (the only field
separating playing from frozen), a restart counter split by resume policy, and a `BUILD_ID`-derived
banner. **Decided later the same day: two of them are dropped, one is deferred, and this is why.**

* **Dropped: the counters.** The argument for them was that only the card could see this bug, and
  that is false. 1041's policy froze at frame 553 in simulation with `AW_STALL` undefined and
  nothing forced, and the fill-buffer oracle named the byte (`fill[27] = c8`, belonging at
  `base+32`). For anything in the ROM stream, sim is the sharper instrument; hardware telemetry
  would have been a worse version of what already exists, aimed at a fault class that is now fixed
  and verified on the device. The `PREFILL_MARGIN` question measures frequency rather than
  correctness: the per-consumer resume holds 0 shifted fills out of 102,114 across 1,911 forced
  restarts, so a too-small margin is survivable by construction.
  **Trigger to revisit:** the first symptom that is *both* hardware-only *and* stream-shaped — then
  add `W%h` (the swap pulse), because at that point we would know it is the right instrument rather
  than a general-purpose hedge.
* **Deferred to the next build anyway: the banner.** `dbg_console.v:65` `MSG_UP = "AW 1041a up\n"`
  is printed by 1040, 1041 and 1042 alike, and it already bought a false suspicion about a fresh
  install. Fix is a string bump; `"AW 1043a up\n"` is still 12 characters, so no `msg_len` or `pos`
  thresholds move and the 148-char `MID_CHK` framing is untouched. Not worth a build on its own —
  fold it into whatever build happens next.

If the two counters are ever wanted, the mechanics are: wire the page-swap pulse (the signal
`tb_soc` already counts) and two counters for `stream_restarts` split by `resume_from_start` into
`dbg_console`'s port list, extend `msg_len` past 148 and shift every `pos` threshold after the
insertion point, update the expected strings in `tb_dbg_console.v` (it asserts on `MSG_UP` today,
so a banner bump edits that file too), keep the line short enough for the existing framing, then
`make sim` plus a scoped `check-build CORE_DIR=cores/aw` — whose dead-logic check is the tripwire
that stops a new counter being optimised away unread.

### Card state, 2026-11-01 17:35: only `Eddie Chan.AW 1042` remains

By the user's decision the two comparison builds were removed from the card once 1042 was confirmed
playing. `Cores/` now holds one folder, `Eddie Chan.AW 1042`, bitstream `579746d33d45b594`, all ten
core files, `Assets/anotherworld/common/part0..7.bin` untouched, and the catalog caches
(`cores_cache`, `corelist_cache`, `core_viewby_platform`, `platforms_cache`,
`platform_viewby_category`) deleted so the Pocket re-enumerates instead of showing ghosts.

This supersedes the instruction repeated through this session — *keep 1040 and 1041 on the card as
the controls*. They are not lost, and nothing here is one-way:

| control | bitstream | recover with |
|---|---|---|
| `AW 1040` | `888b1c056d70ec4a` | `build/bitstreams/Eddie_Chan.AW_1040.rbf_r` (verified byte-identical to the card copy before deletion) + `scripts/sd_install_1040a.sh`; source-era commit `0596839` |
| `AW 1041` | `5b7ab7d5e7f0d80b` | `build/bitstreams/Eddie_Chan.AW_1041.rbf_r` (byte-identical) + `scripts/sd_install_1041a.sh`; source-era commits `aff690e`/`3d44da4` |

Whole folders (configs included) archived to `build/sd/removed-20261101-173500/AW-1040-1041-folders.tgz`,
`/System` backed up to `build/sd/system-backup-pre-delete-20261101-173551` first. `Saves/` was empty
and was left alone.

**The consequence to remember:** the control re-confirmation that this entry flagged as outstanding
— launch 1040, see it shear; launch 1041, see it freeze — can no longer be done by tapping a
second entry in the menu. It now costs a reinstall. If a future symptom ever looks like the shear
or the freeze again, the first move is to reinstall the relevant control, not to reason from
memory about what it did.

### Paging work in flight: what is true, and what `check-build` rightly refuses (2026-11-01)

`99405ee` adds `scripts/build_combined_image.py`: eight packs become a **2.938 MiB** paged image
(93 frames of 32 KiB; one zero frame carries 307 pages; 14 frames shared by all eight parts), and
for every part reassembling its table reproduces `partN.bin` **byte for byte**. `--selftest`
corrupts the image five ways and requires rejection; two of the five are invisible to the view
comparison and only the pool sums catch them.

`16fe39d` adds the core side: upload window 2 MiB → 4 MiB, and a view page table mapping
`psram_word = {page[7:0], word[13:0]}`. The whole unit suite is green and `tb_rom` is up to 550
checks, 28 of them paging — identity, remap page 4 onto 7, neighbours undisturbed, 24 reads across
the remapped boundary byte-exact, restore. That test found a design flaw worth stating: the table
RAM had no defined reset value, so writing one entry silently re-pointed the other 63 pages at page
0 (188 bank-alias mismatches). Fixed by giving the RAM power-up identity, which also deleted the
`tbl_loaded` mux — an unloaded core does the identity map because that is what the RAM *contains*,
not because a case branch says so, and a partial load can no longer disagree with a status bit.
The self-test probe then had to move: `ST_ADDR_D0 = 22'h100000` was "the word past the pack" only
while a pack was 2 MiB, and with a 4 MiB window it is inside the pool, so the periodic A5A5/5A5A
probe would have scribbled on frame 64 of any pool ever loaded. It lives on die 1 now, which a
4 MiB window can never address.

**This is not a shippable build, and `make check-build CORE_DIR=cores/aw` says so: three findings —
`tbl_rdat[6,7]` stuck at GND, `p_addr[21]` lost fanout, and `pgtbl` uninferred ("inappropriate RAM
size", 64×8 becomes registers/MLAB, not M10K). All three follow from one thing: the load port is
tied to 0 in `core_top` because the directory loader is task #18.** So the bitstream this source
produces is functionally 1042 with an identity map, and its slack (worst 0.117 ns here) is *not*
evidence about the timing of real paging hardware. Reading it as such would be the same mistake as
trusting a short clean part1 run. The refusal is the tool doing its job — a table that cannot be
written compiles, places, routes, closes timing and never does anything — and it is recorded here so
the next person does not read a red `check-build` as a regression rather than as a half-built
feature. Nothing was installed on the card from this source; `AW 1042` remains the only build on it.
