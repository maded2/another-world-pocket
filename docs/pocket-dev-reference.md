# Analogue Pocket / openFPGA development reference

Complete digest of [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils)
(IP + wiki), cross-checked against the official
[APF Bus Communication docs](https://www.analogue.co/developer/docs/bus-communication).
Repo cloned at `/tmp/apu` (IP), wiki at `/tmp/apu-wiki` — re-clone if missing.

---

## 1. Pocket hardware facts

| Item | Value |
|---|---|
| Main FPGA | Cyclone V **5CEBA4F23C8** |
| ALMs | 18,480 |
| BRAM | 3,380 Kb M10K + 303 Kb MLAB ≈ **394,240 bytes** |
| DSP blocks | 66 |
| PSRAM | present; driven via the `psram.sv` IP (async/ADV protocol) |
| Screen | 3.5" 1600×1440 LCD (rumored Valve Index panel, capable of 144 Hz — but the Pocket's video path does not reach that) |
| Secondary FPGA | Cyclone 10 10CL016YU256C8G (Analogue-internal; converts pixel stream to 12-bit DDR for display) |

## 2. APF bus architecture (official docs)

Four buses from the FPGA's perspective: **BRIDGE, PAD, VIDEO, AUDIO**. Analogue supplies
integration HDL for BRIDGE and PAD; cores implement VIDEO and AUDIO themselves.

### 2.1 BRIDGE (framework ↔ core, 32-bit address space)

- `0xF8xxxxxx` is **reserved for framework communication**; all other addresses are yours.
- Top-level interface:

```verilog
output wire        bridge_endian_little,
input  wire [31:0] bridge_addr,
input  wire        bridge_rd,
output reg  [31:0] bridge_rd_data,   // may be driven up until the NEXT read strobe (buffered reads)
input  wire        bridge_wr,
input  wire [31:0] bridge_wr_data,
```

- No bus arbitration. Throughput is only a few MB/s; APF pushes one word every ~75 cycles of
  the 74 MHz clock — you cannot consume data slower than that.
- All core nets entering from the framework (bridge, pad, data slots) are synchronized to
  `clk_74a` by the framework.

### 2.2 PAD (controllers)

```verilog
input wire [31:0] cont1_key, cont2_key, cont3_key, cont4_key;   // bit 31:28 = type
input wire [31:0] cont1_joy, ...;                                // analog sticks / scan codes / mouse X
input wire [15:0] cont1_trig, ...;                               // triggers / mouse Y
```

- `type` field (bits 31:28): `0`=none, `1`=Pocket built-in (P1 only), `2`=dock controller digital,
  `3`=dock controller analog, `4`=keyboard, `5`=mouse. **Check type before interpreting data.**
- Key bits: 0=dpad_up, 1=dpad_down, 2=dpad_left, 3=dpad_right, 4=face_a, 5=face_b, 6=face_x,
  7=face_y, 8=trig_l1, 9=trig_r1, 10=trig_l2, 11=trig_r2, 12=trig_l3, 13=trig_r3,
  14=face_select, 15=face_start.
- `joy`: [7:0] lstick_x, [15:8] lstick_y, [23:16] rstick_x, [31:24] rstick_y (8-bit unsigned).
- Keyboard packs into slot 3: up to 6 USB-HID scan codes in `cont3_joy` (order not guaranteed),
  16 modifier bits in `cont3_key[15:0]`.
- Mouse packs into slot 4: buttons + relative X in `cont4_joy`, report counter in
  `cont4_key[15:0]` (compare prev/current to detect new reports), relative Y in `cont4_trig[15:0]`.
- The PAD bus carries a heartbeat; if JTAG dev-reload drops it, the Pocket reloads the core with
  the same start conditions.

### 2.3 VIDEO (official constraints)

| Spec | Value |
|---|---|
| Resolution | 16×16 to **800×720** |
| Refresh | **47 Hz to ~61 Hz** |
| Color | RGB 24-bit 888 (display is 565 internal / 21-bit docked) |
| Pixel clock | 1 MHz to ~50 MHz |

Signals (all synchronous to `vid_rgb_clock`):

```verilog
vid_rgb_clock, vid_rgb_clock_90,   // pixel clock + 90° phase-shifted twin (framework uses it)
vid_rgb[23:0],                     // [23:16] R, [15:8] G, [7:0] B
vid_de,                            // data enable, active high
vid_skip,                          // optional; assert with DE to drop a pixel (e.g. for interlace)
vid_vs, vid_hs                     // single-cycle pulses
```

Hard rules:
- `vs` = exactly **one cycle** per frame; `hs` = one cycle per line.
- `hs` may not come until **≥3 cycles after `vs`**.
- ≥1 clock gap between `hs` and DE assertion, and between DE deassertion and next line's `hs`.
- DE asserted exactly once per line for the active pixel count; RGB must be **0 when DE is low**
  (except while driving feature/endline words).
- Frame feature bits are driven during the VS pulse: `[1]` progressive/interlaced, `[2]` even(0)/odd(1)
  field, `[3]` last field, `[0]` rescan previous frame → **interlace is supported**.
- End-of-line word (after DE falling edge): function code `[2:0]=000` = "set scaler slot" with
  index in `[23:13]` (0–7); the safe value `24'h0` selects slot 0. Multiple set-slot commands in a
  frame: last wins, takes effect next frame.
- Scaler does 90° rotation + per-axis mirroring; max pre-scaled Y is 720 — if you plan to rotate,
  keep the image's starting width ≤720.

agg23 wiki practical notes (on top of the above):
- APF wants **exactly one clock per pixel**; pick your pixel clock so horizontal clocks/pixel is
  exact and frame rate lands in 47–61 Hz. Use <https://tomverbeure.github.io/video_timings_calculator>.
- You do **not** need accurate porches — pixels may start immediately after `hs` deasserts.
- Wrong `video.json` → misaligned video only, not a crash. Correct sync signals + Statistics on in
  Tools gives a green "Sync" indicator.
- ⚠️ Some old arcade cores put `vsync` **mid-`hsync`** — as of fw 1.1-beta-3 this hard-crashes the
  scaler so badly that *no* core produces video until a full Pocket restart.
- Very small resolutions (e.g. 128×64) can get oddly non-integer scaled; integer-scale in your own
  video block and center manually if that's bad (see agg23/analogue-arduboy `video.sv`).

### 2.4 AUDIO (official constraints)

- I2S-compatible, **signed 16-bit stereo, exactly 48 kHz** — sample rate adjustment is not allowed.
- Signals: `aud_mclk`, `aud_dac`, `aud_lrck`, plus `aud_adc` (line-level input from cartridge pin 31).
- **MCLK must always be 12.288 MHz** (256×Fs). SCLK is re-created on the system FPGA at
  3.072 MHz (64×Fs), edge-synchronous with MCLK — not connected, but generate it for debugging.
- Data latched on **rising edge of SCLK**; LRCK low = left, high = right; each channel sends
  16 active bits + 16 spacer bits (first bit delayed 1 clock vs LRCK per I2S).
  64 SCLK / 256 MCLK per stereo sample pair.

## 3. Clocks & CDC rules (wiki — the most important beginner killer)

- Everything from the framework arrives synced to `clk_74a`. Your core's working clock is usually a
  PLL output; **all** crossings into your domain must be synchronized.
- Single bit: 2–FF chain minimum, agg23 uses 3 (`synch_3` in `ip/test/common.v`, with
  `rise`/`fall` edge-pulse outputs for WIDTH=1).
- **Multi-bit: dual-clock FIFO — never a parallel FF chain.** Analogue's own example code does the
  naive thing and it can produce stable-but-wrong values (e.g. see `2'b00 → 2'b10 → 2'b11`).
- Clocks with a common **integer divisor** are effectively the same domain — no sync needed
  (100 MHz ↔ 10 MHz is fine both directions).
- PLL: Integer mode tracks integer multiples accurately; Fractional hits odd ratios exactly but can
  be sloppy on integer ones. Unrelated clocks (11 MHz + 7.578 MHz) → separate PLLs or a common multiple.
- Declare every clock in `core_constraints.sdc`; put async domains in separate
  `set_clock_groups -asynchronous` groups, same-domain clocks in the same group.

## 4. The IP (all MIT, all with testbenches)

### 4.1 `data_loader.sv` — APF writes → memory writes

```systemverilog
module data_loader #(
    parameter ADDRESS_MASK_UPPER_4 = 0,   // only react when bridge_addr[31:28] == this (0xF8 => 15)
    parameter ADDRESS_SIZE = 28,          // width of write_addr output
    parameter WRITE_MEM_CLOCK_DELAY = 4,  // min 4 clk_memory cycles from FIFO pop to write_en
    parameter WRITE_MEM_EN_CYCLE_LENGTH = 1, // how long write_en stays high (min 1)
    parameter OUTPUT_WORD_SIZE = 1        // 1 => 8-bit outputs, 2 => 16-bit outputs
) (
    input clk_74a, clk_memory,
    input bridge_wr, bridge_endian_little, [31:0] bridge_addr, bridge_wr_data,
    output reg write_en, [ADDRESS_SIZE-1:0] write_addr, [8*OUTPUT_WORD_SIZE-1:0] write_data // all in clk_memory domain
);
```

- Internals: 4-deep `dcfifo` of width (WORD_SIZE+28), `clocks_are_synchronized=FALSE`,
  sync delay pipes 5/5. 74a-side FSM pops the incoming 32-bit word into 4 (or 2) sub-writes,
  incrementing the address by OUTPUT_WORD_SIZE each time; memory-side FSM presents each entry with
  `write_en` for WRITE_MEM_EN_CYCLE_LENGTH cycles.
- Endian semantics (TB-verified): **the "first" byte/halfword of the APF word in its declared
  endianness goes to the lowest address.** Big-endian `AABBCCDD` @0xC → `AA`@C, `BB`@D, `CC`@E,
  `DD`@F; 16-bit big-endian → `BBAA`@C, `DDCC`@E. Little-endian: LSB first.
- TB-verified latency: first `write_en` appears ~9 mem cycles after the bridge write (with
  mem clock = 2× the 74a clock in sim).
- Parameter checks via `$error` in an `initial` block (min delay 4, etc.).

### 4.2 `data_unloader.sv` — memory reads → APF read responses

```systemverilog
module data_unloader #(
    parameter ADDRESS_MASK_UPPER_4 = 0,
    parameter ADDRESS_SIZE = 28,
    parameter READ_MEM_CLOCK_DELAY = 1,   // mem cycles for a read to complete
    parameter INPUT_WORD_SIZE = 1         // 1 => 8-bit read_data, 2 => 16-bit
) (
    input clk_74a, clk_memory,
    input bridge_rd, bridge_endian_little, [31:0] bridge_addr,
    output reg [31:0] bridge_rd_data,     // held until next request (matches APF buffered-read rule)
    output reg read_en, [ADDRESS_SIZE-1:0] read_addr,   // clk_memory domain
    input [8*INPUT_WORD_SIZE-1:0] read_data
);
```

- Two 4-deep dcfifos: addresses 74a→mem, data mem→74a.
- TB-verified (little-endian): request @0xC → memory reads C,D,E,F in order; returned bytes
  `AA,BB,CC,DD` assemble to `bridge_rd_data = DDCCBBAA` (lowest address = LSB); 16-bit variant:
  `AABB`@C + `CCDD`@E → `CCDDAABB`. Data is **held** until the next request.

### 4.3 `hex_loader.v` — Intel HEX over APF → bytes

- Instantiates an 8-bit `data_loader_8`, then a nibble-state-machine parses ASCII hex lines:
  waits for `:`, reads byte-count (2 nibbles), base address (4 nibbles), skips record type, pairs
  data nibbles into bytes (`write_en`/`write_addr[14:0]`/`write_data[7:0]`), ignores checksum + CRLF.
- ASCII→nibble: `>0x40 ? c-0x37 : c-0x30`.
- 15-bit output address (32 KB). TB (`hex_loader_tb.vhd`) streams a real ROM image
  (`castleboy.hex`, the CastleBoy NES rom) through the bridge at realistic pacing, writes into a ROM
  entity, re-reads the file and verifies every byte.

### 4.4 `mem/psram.sv` — Pocket PSRAM controller (async/ADV protocol)

```systemverilog
module psram #(
    parameter CLOCK_SPEED = 133.12, // MHz; all timing params are ns, converted to cycles via CEIL
    ... // MIN_ADV_N_PULSE=5, MIN_ADDRESS_SETUP_BEFORE_ADV_HIGH=5, MIN_ADDRESS_HOLD_AFTER_ADV_HIGH=2,
        // MIN_CE_BEFORE_ADV_HIGH=7, MIN_DATA_SETUP_BEFORE_WE_HIGH=20, MIN_DATA_AFTER_ADDR_UNLATCHED=8,
        // MIN_WRITE_PULSE=45, MIN_WRITE_TIME_FROM_ADV=70, MIN_OE_AFTER_ADDR_UNLATCHED=3, MAX_ACCESS_TIME_FROM_ADV=70 (ns)
) (
    input clk,
    input bank_sel, [21:0] addr,
    input write_en, [15:0] data_in, write_high_byte, write_low_byte,
    input read_en, output reg read_avail, [15:0] data_out,
    output reg busy,
    output reg [21:16] cram_a, inout [15:0] cram_dq, input cram_wait,
    output reg cram_clk=0, cram_adv_n=1, cram_cre=0, cram_ce0_n=1, cram_ce1_n=1,
               cram_oe_n=1, cram_we_n=1, cram_ub_n=1, cram_lb_n=1
);
```

- Address/data multiplexed: `cram_a[21:16]` + `cram_dq[15:0]` carry the address during ADV, then data.
- Write FSM (counter-style states, absolute cycle numbers): trigger → assert CE(bank), put addr on
  bus, `we_n=0`, `adv_n=0`, byte enables; release adv after ADV_CYCLE_COUNT; tri-state dq after
  address hold; drive write data; deassert everything at TOTAL_WRITE (~10 cycles @ default params).
- Read FSM: same start, then `oe_n` low after addr unlatch + OE_AFTER_ADDR_UNLATCHED, sample
  `cram_dq` into `data_out` and pulse `read_avail` at READ_INITIAL+TOTAL_READ.
- **The read is 30 cycles, not `TOTAL_READ_CYCLE_COUNT` (10).** `READ_INITIAL_COUNT = 20`, so
  the capture is at state 30 = ~225 ns after ADV# falls at the reference's default 133.12 MHz,
  with OE# low for the last eight (~60 ns). Counting only `TOTAL_READ_CYCLE_COUNT` and taking
  that as "the proven read length" is how this project talked itself into a seven-cycle read
  that was 7 ns short of tAA at the chip pins (builds 1032/1033 - every simulation passed it,
  because the model quantised tAA the same optimistic way).
- **The read branch asserts `cram_ub_n`/`cram_lb_n` low and holds them to the capture.** Byte
  enables are *output enables* on these parts: OE# low with both high is output deselect, and
  the part answers by driving nothing. A floating DQ keeps the last thing driven on it, which
  in an ADV-multiplexed protocol is the address - so the symptom of forgetting this is "every
  read returns its own address", on every timing, which reads like a timing bug and is not.
- `busy` high for the whole operation; one operation at a time (no pipelining), and callers
  respect it, so there is at least one fully deasserted cycle between every access.
- TB (`psram_tb.sv`) walks every FSM state and asserts the exact control-signal sequence
  (ce0/adv/we/dq data, then ce0/adv/oe/data_out+read_avail) using a tri-state PSRAM model.

### 4.5 `sound_i2s.sv` — I2S audio bridge

```systemverilog
module sound_i2s #(parameter CHANNEL_WIDTH = 15, parameter SIGNED_INPUT = 0) (
    input clk_74a, clk_audio,          // audio_l/r may be in ANY clock domain
    input [CHANNEL_WIDTH-1:0] audio_l, audio_r,
    output reg audio_mclk, audio_lrck, audio_dac
);
```

- MCLK 12.288 MHz generated from `clk_74a` with a fractional accumulator (adds 245760/cycle,
  toggles at ≥742500). SCLK = MCLK/4 = 3.072 MHz via 2-bit divider on mclk rising edges.
- Packs L/R into one 32-bit word: signed → L@[15:0], R@[31:16]; unsigned (width 15) → L@[14:0]
  with bit15=0, R@[30:16] with bit31=0. Rejects CHANNEL_WIDTH=16 + unsigned via `$error`.
- CDC: `sync_fifo WIDTH=32` from clk_audio to clk_74a; write_en pulses only when a sample **changes**
  (edge detect), so steady samples cost nothing.
- Shifter: on SCLK falling edge output `sampshift[31]`; lrck_cnt 0..31; at 31 toggle LRCK and
  reload shifter when LRCK goes low; shift only during the first 16 clocks per channel (last bit
  held for the 16 spacer bits).

### 4.6 `sync_fifo.sv` — generic multi-bit CDC

```systemverilog
module sync_fifo #(parameter WIDTH = 2) (
    input clk_write, clk_read,
    input write_en, [WIDTH-1:0] data,
    output reg [WIDTH-1:0] data_s, output reg write_en_s   // read-clock domain
);
```

- 4-deep dcfifo, `use_eab=ON` (block RAM), overflow/underflow checking ON.
- Read side pops one entry when non-empty; after a fixed 2-cycle latency presents `data_s` and a
  1-cycle `write_en_s`. **Depth is only 4 — drain it fast.**

### 4.7 `debug_key.v` — devkit debug key (GB cart)

Hardware: Silicon Labs SI2104 USB-UART (300 bps–2 Mbps), one button, green LED.

```verilog
module debug_key (
    input clk,
    output cart_tran_bank0_dir,  inout [7:4] cart_tran_bank0,
    output cart_tran_bank3_dir,  inout [7:0] cart_tran_bank3,
    output cart_tran_pin31_dir,  inout       cart_tran_pin31,
    input  led,          // drive to light LED
    output button,       // active high (internally inverted)
    input  uart_tx,      // core -> key UART TX
    output uart_rx       // key UART RX -> core (through synch_3)
);
```

- `bank0` driven as output (dir=1): **pin 4 (`bank0[5]`) = LED**, pin 3 (`bank0[6]`) = UART TX.
- `bank3` input (dir=0): **pin 6 (`bank3[0]`) = button** (button is idle-high, output inverted).
- Pin 31 = UART RX, synchronized with `synch_3`.
- **Requires `"cartridge_adapter": 0` in core.json** — otherwise the cart bus isn't powered and the
  key does nothing; also don't ship that flag casually (wastes power).

### 4.8 `ip/test/common.v` — synchronizer primitives

- `synch_2`/`synch_3 #(WIDTH)`: N-stage FF chains with `rise`/`fall` one-cycle edge pulses
  (edge outputs only exist for WIDTH==1). Single-bit use only.

## 5. Link port (wiki)

- Top-level lines: `port_tran_si/so/sck/sd` + `_dir` each; **0 = input, 1 = output**. All four lines
  are bidirectional — the "X is output/input only" comments in the stock `core_top` describe the GBA
  wiring, not the hardware.
- Needs **both** `"link_port": true` **and** `"cartridge_adapter": 0` in core.json (cart port stays powered).
- Measured signal integrity over a link cable: fine to ~**6 MHz**; above that edges degrade badly.

## 6. NTSC/PAL via PLL reconfig (wiki) — and why not to do it on Pocket

- Setup: PLL MegaWizard → enable "PLL Auto Reset" + "Enable dynamic reconfiguration"; instantiate
  `mf_pllcfg` with `mgmt_clk=clk_74a`, connect `reconfig_to_pll`/`reconfig_from_pll`.
- Procedure: snapshot `pll.v`, regenerate for the other standard, diff, feed changed M/N/C counters
  + fractional lo/hi into Intel's PLL Reconfiguration Calculator, then write them via a state machine
  (start: addr 0x0 ← 0x0 = waitrequest mode; end: addr 0x2 ← 0x0 = start reconfig).
- ⚠️ On the Pocket the **74.25 MHz source clock breaks reconfig** subtly (undocumented variables,
  demonstrated on his SNES port). **Ship separate PAL binaries instead.**

## 7. Quartus workflow (wiki)

- Use Quartus only for building/tooling; edit in VS Code. Lite edition is enough for Cyclone V.
- Megafunction wizard version mismatch ("not listed in any wizard.lst"): add your version to
  `.../ip/altera/altera_pll/pll_wizard.lst`.
- Free Quartus can't promote warnings→errors: undefined nets compile with only a warning → **lint externally**.
- **SignalTap**: needs an Intel-approved USB Blaster (Terasic P0302 works; driver install links in wiki).
  Multiple debugger instances; changing trigger *nets* (not AND/OR mode) doesn't require recompile.
  Pocket Tools/Developer menu: **"Pause Core Boot"** and **"Pause Data Load"** — halt boot/data load
  until a button press, so you can catch early-boot glitches.
- Timing failures: Compilation Report → expand timing analysis → click red nets → TimeQuest
  "Report Timing Closure Recommendations".

## 8. MiSTer porting gotchas (wiki)

- `CONF_STR` arrives via the `status` register; decode it with <https://agg23.github.io/mister-config/>.
- `ioctl_addr` points **one past** the last written address when `ioctl_downloading` deasserts —
  don't use the trailing-edge value as your end address (file of size 0x100 ends at addr 0xFF, but
  `ioctl_addr == 0x100`).

## 9. Tools & reference cores (from README)

- CHIP32 VM simulator: [agg23/openfpga-chip32-sim](https://github.com/agg23/openfpga-chip32-sim)
- APF image bin create/extract: [agg23/Analogue-Pocket-Image-Process](https://github.com/agg23/Analogue-Pocket-Image-Process);
  library thumbnails: [codewario/PocketLibraryImageConversion](https://github.com/codewario/PocketLibraryImageConversion)
- Core updaters: RetroDriven/Pocket_Updater (Win GUI), mattpannella/pocket_core_autoupdate_net (C#),
  rivergillis/update-pocket (Python), jgdigitaljedi/pocket-update-notifier (Node)
- Tutorials: [DidierMalenfant openFPGA tutorials](https://code.malenfant.net/didier/openFPGA-tutorials)
  (proper build system + examples — note this project's Docker image is based on his Quartus image)
- Open-source reference cores: agg23's NES/SNES/PC Engine/Arduboy/Pokemon Mini, ericlewis' Genesis +
  arcade set, opengateware arcade set, Mazamars312's Neo Geo. Full inventory:
  <https://joshcampbell191.github.io/openfpga-cores-inventory/analogue-pocket.html>

## 10. Gotcha checklist (quick reference)

1. vsync/hsync exactly 1 cycle; hsync ≥3 cycles after vsync; never mid-hsync (scaler hard-crash).
2. video_de only for declared pixels; vidout_rgb = 0 when de low.
3. Frame 47–61 Hz, 16×16–800×720, pixel clock 1–50 MHz, exactly one clock/pixel.
4. Audio: MCLK exactly 12.288 MHz, signed 16-bit stereo, 48 kHz fixed, 16+16 bits/channel.
5. Multi-bit CDC → dual-clock FIFO only; single bit → 2–3 FFs; integer-divisor clocks need no sync.
6. Bridge: 0xF8xxxxxx reserved; reads may respond up to the next strobe; ~75-cycle write cadence.
7. Debug key & link port both need `cartridge_adapter: 0` (link also needs `link_port: true`).
8. Link port speed ≤ ~6 MHz over cable.
9. Don't do PLL reconfig for PAL on Pocket — separate binaries.
10. Declare all clocks in SDC; async groups via set_clock_groups.
11. MiSTer ioctl_addr off-by-one at end of download.
12. Lint your Verilog — free Quartus won't error on undefined nets.
