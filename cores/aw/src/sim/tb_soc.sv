// tb_soc - does the thing render?
//
// Everything else in cores/aw/src/sim answers a small question about one module. This
// answers the only question that decides whether the port works: put a real pack in the
// memory through the bridge model, release the VM, and look at what comes out of the
// video pins. Nothing else exercises the pipeline alignment, the ROM's byte contract and
// the arbitration at the same time - and the bar agreed for scope S1 is the intro screen.
//
// Frames are written as PPMs into +FRAMEDIR (default /tmp/awframes) and summarised on
// stdout: dimensions, distinct colours, non-black pixels, mean brightness. A design that
// is stuck shows up immediately as identical checksums; a design that renders the intro
// shows a small palette and mostly dark pixels, and the pictures can actually be looked
// at.
//
// Run: scripts/sim_soc.sh [pack.bin]
`timescale 1ns/1ps
`default_nettype none

module tb_soc;

    localparam integer PACK_BYTES = 2097136;          // one pack: 2 MiB - 16
    localparam integer PACK_WORDS = PACK_BYTES / 4;
    localparam [23:0]  TRAILER    = 24'h1fffe0;
    localparam integer MAXPIX     = (1 << 21);

    // ---- clocks: 74.25 in from the Pocket, everything else from the PLL. Modelled as
    // independent clocks; the design's clock groups are asynchronous, and if it were not,
    // a coherent-timescale test here would be telling a lie anyway.
    reg clk_core = 1'b0, clk_psram = 1'b0, clk_bridge = 1'b0;
    always#20.20202 clk_core   = ~clk_core;    // 24.750 MHz
    always#5.38720 clk_psram  = ~clk_psram;   // 92.8125 MHz PSRAM sequence clock
    always #6.73400 clk_bridge = ~clk_bridge;  // 74.250 MHz

    reg rst_core = 1'b1, rst_psram = 1'b1, rst_bridge = 1'b1;
    // design_run mirrors core_top: the generated M_main.reset is ACTIVE HIGH, so it is
// ~design_run that goes to the design. Mirroring the polarity wrongly here is what
// hid the frozen-blitter bug for as long as it was hidden.
reg design_run = 1'b0;

    // ---- ROM <-> VM ----
    wire        mem_in_ready;
    wire [23:0] mem_addr;
    wire [7:0]  mem_data;
    wire        mem_data_available;
    wire        mem_busy;

    // ---- video ----
    wire [7:0] game_r, game_g, game_b;
    wire       game_de, game_hs, game_vs;
    wire [7:0] leds;

    // APF scaler protocol monitor on the game's video pins. tb_top checks the muxed
    // core_top output; this one protects M_main itself, so a future .si regeneration
    // that changes raster timing (pulse widths, vs/hs placement, rgb during blanking)
    // fails here instead of garbling or crashing the Pocket's scaler on the device.
    wire [31:0] vid_errors;
    apf_video_check #(.H_ACTIVE(320), .V_ACTIVE(200)) u_vidcheck (
        .clk  ( clk_core     ),
        .rgb  ( {game_r, game_g, game_b} ),
        .de   ( game_de      ),
        .skip ( 1'b0         ),
        .vs   ( game_vs      ),
        .hs   ( game_hs      ),
        .errors ( vid_errors )
    );

    // ---- bridge ----
    reg               dataslot_wr;
    reg  [31:0]       dataslot_addr;
    reg  [31:0]       dataslot_wdata;
    reg               dataslot_allcomplete;

    wire              rom_ready, rom_loading;
    wire [1:0]        rom_error;

    wire [21:0] cram0_a;
    wire [15:0] cram0_dq;
    wire        cram0_wait;

    /* verilator lint_off PINCONNECTEMPTY */
    // Sweeps 2 Ki words rather than the whole pack: this bench is not a pack-integrity test,
    // and a full 1,048,576-read census costs ~135 ms of simulation before rom_ready. The
    // bitstream uses the default (the whole pack); scripts/sim_rom.sh is the bench that
    // verifies the mechanism, including with +SKIP=<word> to lose a write on purpose.
    aw_rom #(.CENSUS_RANGE(22'h000800)) u_rom (
        .clk_core            (clk_core),
        .rst_core            (rst_core),
        .mem_in_ready        (mem_in_ready),
        .vm_running            (design_run),
        .mem_addr            (mem_addr),
        .mem_data            (mem_data),
        .mem_data_available  (mem_data_available),
        .mem_busy            (mem_busy),
        .clk_psram           (clk_psram),
        .rst_psram           (rst_psram),
        .clk_bridge          (clk_bridge),
        .rst_bridge          (rst_bridge),
        .bridge_wr           (dataslot_wr),
        .bridge_addr         (dataslot_addr),
        .bridge_wr_data      (dataslot_wdata),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rom_ready           (rom_ready),
        .rom_error           (rom_error),
        .rom_loading         (rom_loading),
        .cram0_a             (cram0_a),
        .cram0_dq            (cram0_dq),
        .cram0_wait          (cram0_wait),
        .cram0_clk           (),   // the design's own copy of the clock out to the chip
        .cram0_adv_n         (),
        .cram0_cre           (),
        .cram0_ce0_n         (),
        .cram0_ce1_n         (),
        .cram0_oe_n          (),
        .cram0_we_n          (),
        .cram0_ub_n          (),
        .cram0_lb_n          ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    aw_psram_model u_mem (
        .clk     (clk_psram),
        .adv_n   (u_rom.cram0_adv_n),
        .cre     (u_rom.cram0_cre),
        .ce0_n   (u_rom.cram0_ce0_n),
        .ce1_n   (u_rom.cram0_ce1_n),
        .oe_n    (u_rom.cram0_oe_n),
        .we_n    (u_rom.cram0_we_n),
        .ub_n    (u_rom.cram0_ub_n),
        .lb_n    (u_rom.cram0_lb_n),
        .a       (cram0_a),
        .dq      (cram0_dq),
        .wait_hi (cram0_wait)
    );

    // ---- scripted input -------------------------------------------------------------
    // Upstream's simulation block does exactly this (a5k.si:870): up until cycle 70217342,
    // then right. Not because the intro needs a combination of buttons, but because a
    // testbench that never presses anything cannot tell 'nothing renders' from 'nobody
    // pressed a button' - and the opening scene does wait for the player. Bit order is the
    // VM's, from vm.si: [0] right [1] left [2] up [3] down [4] fire [5] unused.
    // +NOINPUT=1 pins it to zero instead (that is what the run that found the frozen
    // blitter used).
    reg [5:0] js = 6'b000000;
    integer noinput = 0;
    longint cyc_run = 0;
    // The input-path test (in_case below) takes the pad over by asserting js_force_en. It has to
    // go through this same process: a second process writing js would race with this one, and
    // the loser would be whichever the scheduler liked less that cycle.
    reg       js_force_en = 1'b0;
    reg [5:0] js_force    = 6'b000000;
    always @(posedge clk_core) begin
        if (design_run) cyc_run = cyc_run + 1;
        if (js_force_en)            js = js_force;
        else if (!noinput && design_run)
            js = (cyc_run < 70_217_342) ? 6'b000100 : 6'b000001;  // up, then right
        else if (design_run)
            js = 6'b000000;
    end

    // ---- input path (task #22) -------------------------------------------------------------
    // Nothing asserted anything about input before this. The run drives up-then-right because the
    // opening scene waits for the player, but no test ever checked the VM noticed, which is the
    // difference between "a button was pressed" and "the game responded". Two levels:
    //   hard:  u_soc.vm.in_jstick must equal what the tb drives - covers the SoC port, the
    //          jstick_delay register and the wire into the VM.
    //   soft:  print the game's own pad variables in vmVars (0xE5 up/down, 0xFC left/right,
    //          0xFD mask, 0xFA action, 0xFE action|0x80; vm.h and vm.si agree on those
    //          addresses). vm.si's per-frame input block writes them, so if the intro never runs
    //          that block they will not move - print first, assert later, because asserting values
    //          I have not measured is how you end up with a test that fails for the wrong reason.
    // Still unreachable from here: the Pocket cont1_key bit numbers (AW_KEY_* in core_top.v). The
    // tb drives the SoC's jstick port directly and never goes through that mapping, so the bit
    // positions stay a belief until checked against the spec and a real pad.
    integer in_checks    = 0;
    integer in_acted     = 0;
    // The first version sampled the pad variables once, at the end of the window, and reported
    // that 'right' and 'up' did nothing while 'left' worked. Both readings were true: vm.si's
    // input block runs periodically, so a single-instant check passes or fails depending on where
    // in the cadence the sample landed. A test that depends on where a sample lands is not a test,
    // so each pattern is now held and the variables are watched every cycle for the first moment
    // they match. That asserts the thing that is actually guaranteed - hold a direction long
    // enough and the game's own variables will reflect it - and it reports the cadence for free.
    localparam integer IN_WINDOW_FRAMES = 8;
    task automatic in_case(input string label, input [5:0] pat,
                           input logic signed [15:0] want_lr, input logic signed [15:0] want_ud,
                           input logic signed [15:0] want_mask,
                           input logic signed [15:0] want_act,
                           input logic signed [15:0] want_amask);
        integer g;
        bit     seen_pad;
        bit     acted;
        integer acted_at;
        js_force    = pat;
        js_force_en = 1'b1;
        seen_pad = 0; acted = 0; acted_at = -1;
        for (g = 0; g < IN_WINDOW_FRAMES * FRAME_CYCLES; g = g + 1) begin
            @(posedge clk_core);
            if (u_soc.vm.in_jstick === pat) seen_pad = 1;
            else if (u_soc.vm.in_jstick !== pat && !seen_pad) begin
                // report once per case, not once per cycle
                if (acted_at == -1 && g > 16) begin
                    $display("  input %-8s FAIL: VM sees %b, expected %b",
                             label, u_soc.vm.in_jstick, pat);
                    errors = errors + 1;
                    acted_at = -2;   // suppress repeats; acted stays 0
                end
            end
            if (!acted &&
                u_soc.vm.__mem__vmVars.buffer[8'hFC] === want_lr   &&
                u_soc.vm.__mem__vmVars.buffer[8'hE5] === want_ud   &&
                u_soc.vm.__mem__vmVars.buffer[8'hFD] === want_mask &&
                u_soc.vm.__mem__vmVars.buffer[8'hFA] === want_act  &&
                u_soc.vm.__mem__vmVars.buffer[8'hFE] === want_amask) begin
                acted = 1; acted_at = g;
            end
        end
        in_checks = in_checks + 1;
        if (acted) begin
            in_acted = in_acted + 1;
            $display("  input %-8s pad=%b -> VM lr=%0d ud=%0d mask=%h act=%h  ok (after %0d cycles, %0d frames)",
                     label, pat, want_lr, want_ud, want_mask, want_act, acted_at,
                     acted_at / FRAME_CYCLES);
        end else begin
            $display("  input %-8s pad=%b -> no match in %0d frames (saw lr=%0d ud=%0d mask=%h act=%h; want lr=%0d ud=%0d mask=%h act=%h)",
                     label, pat, IN_WINDOW_FRAMES,
                     u_soc.vm.__mem__vmVars.buffer[8'hFC],
                     u_soc.vm.__mem__vmVars.buffer[8'hE5],
                     u_soc.vm.__mem__vmVars.buffer[8'hFD],
                     u_soc.vm.__mem__vmVars.buffer[8'hFA],
                     want_lr, want_ud, want_mask, want_act);
            errors = errors + 1;
        end
    endtask

    M_main u_soc (
        .in_mem_data          (mem_data),
        .in_mem_data_available(mem_data_available),
        .in_mem_busy          (mem_busy),
        .in_jstick            (js),
        .out_mem_in_ready     (mem_in_ready),
        .out_mem_addr         (mem_addr),
        .out_video_r          (game_r),
        .out_video_g          (game_g),
        .out_video_b          (game_b),
        .out_video_de         (game_de),
        .out_video_hs         (game_hs),
        .out_video_vs         (game_vs),
        .out_leds             (leds),
        .out_vblank           (),
        .in_run               (1'b1),
        .out_done             (),
        .reset                (~design_run),
        .out_clock            (),
        .clock                (clk_core)
    );

    // ---- memory image, for the bridge loader
    reg [7:0] ref_mem [0:PACK_BYTES-1];
    string    pack_hex;
    // What this pack is supposed to put on screen, from scripts/sim_soc.sh. Not cosmetic:
    // part0 IS the copy-protection screen and is near-black in the REFERENCE simulator too, so
    // a verdict that demands rich frames fails the design for drawing what the pack says - and
    // nobody reads a gate that cries wolf. "rich" = an ordinary intro/gameplay pack (a flat or
    // black screen is a fault); "text" = the copy-protection screen, whose real oracles are the
    // op_drawString strip and the census, and where "no strip was ever written" is the fault.
    string    pack_kind = "rich";
    string    framedir;
    // Pace of the modelled bridge. Measured on this design, one 32-bit write every ten
    // 74.25 MHz cycles (~25 MB/s) is absorbed; every eight (~31 MB/s) overruns the drain
    // into the ZBT and the design reports ERR_OVERFLOW, which is the correct behaviour and
    // is why this test would otherwise sit in reset drawing black frames for no apparent
    // reason. The real bridge's sustained rate is unknown until measured on hardware -
    // see docs/another-world/port-log.md.
    integer   pace = 10;
    integer   max_frames = 40;
    integer   errors = 0;
    reg       s1_pass = 1'b0;   // decides the process exit status, not just the printed verdict

    // d is little-endian (the byte belonging at address a is d[7:0]); the APF wire puts
    // that byte at [31:24] for a core declaring bridge_endian_little = 0, so the word is
    // reversed on the way out. This is the mapping data_loader.sv in
    // analogue-pocket-utils is tested with, and the one build 1035a measured on hardware
    // (file bytes 04 00 e7 00 landed in PSRAM word 0 as 16'he700 with the little-endian
    // reading). Bench and design must not agree with each other and disagree with the
    // framework: while both took the payload little-endian, every byte of a real pack
    // was stored reversed inside its 32-bit entry and this bench still passed.
    task automatic wr32(input [31:0] a, input [31:0] d);
        begin
            // WR high for exactly one cycle, then pace cycles of quiet. Leaving WR high
            // while waiting offers the same word again every cycle - at pace=10 that is ten
            // times the intended traffic, and the design answers by (correctly) reporting
            // that the bridge has overrun the memory.
            @(negedge clk_bridge);
            dataslot_wr    <= 1'b1;
            dataslot_addr  <= a;
            dataslot_wdata <= {d[7:0], d[15:8], d[23:16], d[31:24]};
            @(negedge clk_bridge);
            dataslot_wr    <= 1'b0;
            repeat (pace)  @(negedge clk_bridge);
        end
    endtask

    // ---- frame capture -------------------------------------------------------------
    reg [7:0] fb_r [0:MAXPIX-1], fb_g [0:MAXPIX-1], fb_b [0:MAXPIX-1];
    integer   fbp = 0;             // pixels in the frame being filled
    integer   line_pix = 0;        // pixels in the line being filled
    integer   frame_w = 0, frame_h = 0;
    integer   frames = 0;
    integer   fd;
    // Did the VM read anything, and did it draw anything? A black screen with a design
    // that is stuck looks, from the outside, exactly like a black screen with a design
    // that is thinking, and a test that cannot tell them apart is worse than no test: it
    // reports success on a core that shows nothing forever.
    integer   bytes_to_vm = 0;
    integer   stream_base = -1;
    integer   served_k = 0;
    bit       served_prev = 0;
    // How often the reader had to start its stream over (aw_rom's `rewind`). A wrong byte
    // with rewinds=0 is a delivered word that did not match its tag's neighbourhood; a wrong
    // byte next to a rewind is a stream that restarted, which is a different bug.
    integer   rewinds = 0;
    integer   rewind_reissue = 0;   // restarts that happened AFTER bytes were delivered (see below)
    integer   chk_unchk = 0;        // bytes not comparable (address outside the image window)
    // Pulses the consumer did not take, kept because the older logs count it and because it is
    // the size of the pulsed-read population. It is NOT a fault and no longer gates the verdict:
    // `take` raises mem_data_available one core cycle after deciding, and readByte (vm.si:56)
    // has already dropped in_ready by then, so every single-byte read lands here. Part1 counted
    // 29904 of 121834 bytes this way with nothing lost -- the first version of this check made
    // the S1 target unpassable by counting the design's most common correct behaviour.
    integer   da_not_accepted = 0;
    always @(posedge clk_core) begin
        if (mem_data_available && !mem_in_ready && !u_rom.chk_active)
            da_not_accepted = da_not_accepted + 1;
    end

    // ---- consumer-side acceptance monitor ---------------------------------------------
    // Of the four things that read this bus, only ONE punishes a missing cycle:
    //
    //   readByte      (vm.si:56)  in_ready for ONE cycle, then waits for busy and takes
    //                             mem.data. Never looks at data_available -> a gap is free.
    //   bytecode fill (vm.si:491) holds in_ready for ~64 bytes and runs
    //                             `data.addr = data.wenable ? (data.addr + 1) : 0`
    //                             so A CYCLE WITHOUT data_available RESETS THE FILL WRITE
    //                             POINTER: the next byte lands at fill address 0 and the
    //                             interpreter runs the rest of the buffer shifted. That is the
    //                             Pocket's freeze - opcode 0x80 (not a VM op), page swaps stop,
    //                             same place every launch, ~10 s in.
    //   op_setPalette (vm.si:763) holds in_ready for 64 bytes but keeps `n` across gaps.
    //   op_drawString (vm.si:935) holds in_ready for len*384 bytes and keeps pix_waddr across
    //                             gaps (which is why IT is the consumer that cares about bytes
    //                             being RE-SERVED rather than about gaps - the text shear).
    //
    // An acceptance is therefore classified by what it DID, not by how long it was: writing the
    // fill buffer is what makes an acceptance gap-intolerant. (The first version classified by
    // LENGTH and reported "1 gap in 558 of 559 fills" on a run that was healthy - restarts 0,
    // intro rendering, fill oracle clean. Those gaps were the tail cycle after the fill had
    // finished writing, and length cannot see that. Position and identity can, so this counts
    // writes and counts a gap only where it could still move one.)
    localparam integer FILL_WRITES = 63;   // bytes one bytecode fill writes: the loop runs while
                                           // data.addr != 63 (vm.si:494). Confirmed by measurement
                                           // - 35456 fill writes over 559 fill acceptances.

    integer   acc_bytes   = 0;      // accepted pulses (data_available & in_ready) this acceptance
    integer   acc_fw      = 0;      // writes THIS acceptance made to the VM's fill buffer
    integer   acc_gaps    = 0;      // cycles the consumer waited with nothing to take
    integer   acc_gaps_early = 0;   // of those, ones that fell before the fill finished writing
    integer   acc_gap_pos = 0;      // write index the FIRST gap fell at (position decides all)
    reg       acc_open    = 1'b0;
    reg [20:0] acc_base   = 21'd0;

    // An acceptance that restarted FROM ITS OWN START is not a positional stream any more, and
    // the delivery oracle has to know that. aw_rom does this deliberately for the bytecode fill
    // (see resume_addr): the fill's write pointer reset to 0 on the gap, so the only coherent
    // continuation is from the acceptance's first byte, and the VM's fill loop is about to write
    // those bytes at 0, 1, 2... again. Comparing that against base+k calls correct behaviour
    // wrong - 36,531 times, in the run that proved the mechanism. So the byte oracle stands aside
    // for such an acceptance and SAYS so in a counted number, rather than either crying wolf or
    // being deleted. The fill-shift oracle below still checks every byte, because it checks the
    // address the VM actually wrote to.
    reg       acc_reserve = 1'b0;
    integer   n_reserve   = 0;      // acceptances that re-served bytes on purpose
    integer   reserve_bytes = 0;    // bytes delivered while the positional oracle stood aside

    integer   n_fill_acc  = 0;      // acceptances that wrote the fill buffer: the intolerant ones
    integer   n_fill_bad  = 0;      // of those, ones with a gap that could move a later write
    integer   fill_gap_cycles = 0, fill_gap_early = 0;
    integer   n_tol_acc   = 0;      // tolerant acceptances: pulsed reads, palette, header, strips
    integer   tol_gap_cycles = 0;
    integer   last_bad_base = 0, last_bad_len = 0, last_bad_gaps = 0, last_bad_pos = 0;

    // ---- where the VM's fill bytes actually LAND (the oracle that was missing) ----------
    // Everything above measures the wire. The wire can be byte-exact - part1: 121,830 of
    // 121,834 bytes compared, zero wrong - and the game still freeze on hardware, because the
    // bytecode fill loop writes what it receives into its own 64-byte buffer and its write
    // pointer is NOT the stream position:
    //
    //   vm.si:495   data.addr = data.wenable ? (data.addr + 1) : 0;
    //
    // A cycle without data_available sends that pointer back to 0, so the next byte lands at
    // fill address 0 and everything after it is shifted. The interpreter then executes the tail
    // of the buffer as opcodes - which is exactly what the Pocket shows when it stops: opcode
    // 0x80, not a VM op, page swaps frozen, same place every launch. No address-anchored check
    // on the delivery side can see this, because the delivery is correct; only the landing
    // addresses are not.
    //
    // So check the consumer's own writes. `data` is the fill buffer (module
    // M_vm_M_main_vm_mem_data, 64 x 8 bits) and vm.si writes data.wenable in ONE place - the
    // fill loop at 493-501 (grep: nothing else in vm.si touches data.wenable) - so every write
    // to this BRAM belongs to a fill, and its address must equal the byte's offset from the
    // acceptance base. That makes the check per-byte, exact, and immune to the classification
    // guesswork above.
    integer   fill_writes   = 0;
    integer   fill_shift    = 0;      // writes that landed where the pack says another byte lives
    integer   fill_unbased  = 0;      // writes with no acceptance open (should be impossible)
    integer   last_shift_at = 0;      // the fill address the VM chose, for the verdict line
    always @(posedge clk_core) begin
        if (u_soc.vm.__mem__data.in_wenable) begin
            fill_writes = fill_writes + 1;
            if (!acc_open) begin
                fill_unbased = fill_unbased + 1;
                if (fill_unbased <= 3)
                    $display("  UNBASED fill write #%0d addr=%0d data=%02h t=%0t dir_active=%b",
                             fill_unbased, u_soc.vm.__mem__data.in_addr,
                             u_soc.vm.__mem__data.in_wdata, $time, u_rom.dir_active);
            end
            else if ((acc_base + u_soc.vm.__mem__data.in_addr) < PACK_BYTES) begin
                if (u_soc.vm.__mem__data.in_wdata !== ref_mem[acc_base + u_soc.vm.__mem__data.in_addr]) begin
                    fill_shift = fill_shift + 1;
                    last_shift_at = u_soc.vm.__mem__data.in_addr;
                    if (fill_shift <= 20)
                        $display("  FILL SHIFT t=%0t fill base=%0h: the VM wrote fill[%0d] = %02h but the pack byte at base+%0d is %02h (the byte it put there lives at base+%0d; accepted so far %0d, gaps so far %0d, rewinds %0d, c_addr=%0h) - the fill loop's write pointer reset on a cycle without data_available (vm.si:495)",
                                 $time, acc_base, u_soc.vm.__mem__data.in_addr,
                                 u_soc.vm.__mem__data.in_wdata, u_soc.vm.__mem__data.in_addr,
                                 ref_mem[acc_base + u_soc.vm.__mem__data.in_addr],
                                 find_byte_in_pack(u_soc.vm.__mem__data.in_wdata, acc_base, acc_bytes),
                                 acc_bytes, acc_gaps, rewinds, u_rom.c_addr);
                end
            end
        end
    end

    // Neighbourhood search for the diagnostic above: where in the pack does this byte value
    // occur near the stream position? Only ever a hint (a byte value repeats constantly), but
    // "the byte for base+120 landed at base+0" is the sentence that makes a shift obvious.
    function [31:0] find_byte_in_pack;
        input [7:0] val;
        input [20:0] base;
        input integer near;
        integer k, j;
        begin
            find_byte_in_pack = 32'hffff_ffff;
            for (k = 0; k < 16; k = k + 1) begin
                j = near + 8 - k;
                if (find_byte_in_pack == 32'hffff_ffff && j >= 0 &&
                    (base + j) < PACK_BYTES && ref_mem[base + j] === val)
                    find_byte_in_pack = j[31:0];
            end
        end
    endfunction

    task close_acceptance;
        begin
            if (acc_open) begin
                if (acc_fw > 0) begin
                    // This acceptance filled the bytecode buffer: it is the one consumer whose
                    // landing addresses a missing cycle can move.
                    n_fill_acc      = n_fill_acc + 1;
                    fill_gap_cycles = fill_gap_cycles + acc_gaps;
                    fill_gap_early  = fill_gap_early + acc_gaps_early;
                    if (acc_gaps_early > 0) begin
                        n_fill_bad = n_fill_bad + 1;
                        if (n_fill_bad <= 5)
                            $display("  FILL GAP t=%0t base=%0h: %0d of the %0d cycles this fill waited for a byte fell BEFORE its last write (it had written %0d of %0d, first gap at write %0d, %0d restarts) - a gap there moves the fill's later writes",
                                     $time, acc_base, acc_gaps_early, acc_gaps, acc_fw,
                                     FILL_WRITES, acc_gap_pos, rewinds);
                        last_bad_base = acc_base; last_bad_len = acc_fw;
                        last_bad_gaps = acc_gaps_early; last_bad_pos = acc_gap_pos;
                    end
                end else begin
                    // Tolerant by construction: readByte, the palette load, the boot header read
                    // or a string strip. Their gaps are reported, never failed.
                    n_tol_acc      = n_tol_acc + 1;
                    tol_gap_cycles = tol_gap_cycles + acc_gaps;
                end
            end
            acc_open = 1'b0;
        end
    endtask

    always @(posedge clk_core) begin
        // Counted here rather than in the oracle block so that the write count and the gap count
        // for one cycle are produced by the same statement order: two always blocks on the same
        // edge have no defined order, and "did the gap come before this write" is exactly the
        // kind of question that cannot be answered across a race.
        if (u_soc.vm.__mem__data.in_wenable && acc_open) acc_fw = acc_fw + 1;

        if (u_rom.chk_active) begin
            // The boot check owns the reader here; its trailer read is not the VM's stream.
            close_acceptance;
        end else if (u_rom.accept_vm) begin
            close_acceptance;
            acc_open       = 1'b1;
            acc_bytes      = 0;
            acc_fw         = 0;
            acc_gaps       = 0;
            acc_gaps_early = 0;
            acc_gap_pos    = 0;
            acc_base       = mem_addr & 21'h1F_FFFF;  // 2 MB pack window, same mask as byte check
            acc_reserve    = 1'b0;
        end else if (acc_open) begin
            if (u_rom.rewind && u_rom.resume_from_start && !acc_reserve) begin
                acc_reserve = 1'b1;
                n_reserve   = n_reserve + 1;
            end
            if (mem_data_available) begin
                if (mem_in_ready && acc_reserve) reserve_bytes = reserve_bytes + 1;
                if (mem_in_ready) acc_bytes = acc_bytes + 1;
            end else if (mem_in_ready && acc_bytes > 0) begin
                if (acc_gaps == 0) acc_gap_pos = acc_fw;
                acc_gaps = acc_gaps + 1;
                if (acc_fw < FILL_WRITES) acc_gaps_early = acc_gaps_early + 1;
            end
        end
    end
    integer   chk_compared = 0;     // bytes actually compared: if this is 0 while bytes flowed,
                                    // the oracle compared nothing and '0 errors' means nothing
                                    // (that is what part1's PASS had been saying)
    always @(posedge clk_core) if (u_rom.rewind) rewinds = rewinds + 1;
    // Did the game keep swapping frames? A design can hold 60 Hz video, keep streaming ROM
    // bytes and never paint a new picture again: op_blitFramebuffer (vm.si:852) is the only
    // thing that flips pages, so counting its pulses tells 'running' apart from 'displaying'.
    // A 900-frame part1 run passed on the checks above while the last swap happened at frame
    // 553 and nothing after it ever reached the screen.
    integer   swaps = 0;
    integer   last_swap_frame = 0;
    reg       swap_q = 1'b0;
    // Edge, not level: `page_swap` is a TOGGLE (vm.si:874 does `page_swap <= ~page_swap`), so
    // counting cycles it is high counted 15,801,905 "swaps" in an 80-frame run and the
    // stopped-presenting check below could never have fired. A counter that cannot fail is
    // decoration.
    always @(posedge clk_core) begin
        swap_q <= u_soc._w_vm_page_swap;
        if (u_soc._w_vm_page_swap !== swap_q) begin
            swaps           = swaps + 1;
            last_swap_frame = frames;
        end
    end
    integer   black_frames = 0;
    // "Not black" is not "the game is drawing". Frames 10-13 of the intro are a uniform
    // fill: nonblack=64000 with colours=1. Counting those as success is how a design passes
    // while showing a single flat colour, so the S1 bar is a *rich* frame: several distinct
    // colours over a filled screen.
    integer   rich_frames = 0;
    integer   max_colours = 0;
    localparam integer MIN_COLOURS = 3;
    real      sum_r, sum_g, sum_b;
    integer   nonzero;
    // The game uses at most 16 colours per palette, so the distinct-colour tally is a
    // small linear scan; a wide search here is per-pixel work and dominates the run.
    reg [23:0] seen [0:63];
    integer   nseen;
    bit       fuzz_bram = 0;
    integer   fz_i;
    reg [31:0] fz_seed;

    // ---- colour oracle -----------------------------------------------------------
    // The palette entry is the game's 12-bit format, not rgb565, and the authority on that
    // is the renderer which consumes this exact pack data upstream
    // (sysImplementation.cpp::setPalette):
    //     c1 = p[0], c2 = p[1]
    //     r = (((c1&0x0f)<<2) | ((c1&0x0f)>>2)) << 2
    //     g = (((c2&0xf0)>>2) | ((c2&0xf0)>>6)) << 2
    //     b = (((c2&0x0f)>>2) | ((c2&0x0f)<<2)) << 2
    // The vm stores the pair as {second, first} (vm.si: clr = {mem.data, clr[8,8]}), so for
    // an entry E read back out of the palette ram: R = E[3:0], B = E[11:8], G = E[15:12],
    // E[7:4] unused - and a nibble n becomes {n, n[3:2], 2'b00}, which is the reference's
    // own 4->8 scaling (full scale 252, and it is what reference screenshots are made of,
    // so matching it beats inventing a prettier one).
    // So every colour the SoC puts on screen has to be a decoding of some entry it held.
    // "The shapes are right" and "the colours are right" are different claims: the rgb565
    // reading aw_pocket.si carried passes every shape test this bench has, and on hardware
    // gives a recognizable picture in the wrong colours.
    function automatic [23:0] pal_rgb(input [15:0] e);
        begin
            pal_rgb = { e[3:0],   e[3:2],   2'b00,
                        e[15:12], e[15:14], 2'b00,
                        e[11:8],  e[11:10], 2'b00 };
        end
    endfunction

    reg [23:0] hist_rgb [0:511];   // decodings of every entry the design ever held
    integer    nhist = 0;
    reg [23:0] col_seen [0:127];   // colours already judged
    integer    ncol_seen = 0;
    integer    col_bad = 0;

    task automatic check_colours;
        integer i, k, hit;
        reg [23:0] c, d;
        begin
            // the bank can be reloaded between the pixel and the frame end, so the set is
            // cumulative: the condition stays necessary, and no scene transition is a false
            // failure on a palette that has already moved on
            for (k = 0; k < 32; k = k + 1) begin
                d = pal_rgb(u_soc.__mem__palette.buffer[k]);
                if (^d === 1'bx) continue;
                hit = 0;
                for (i = 0; i < nhist && !hit; i = i + 1)
                    if (hist_rgb[i] === d) hit = 1;
                if (!hit && nhist < 512) begin
                    hist_rgb[nhist] = d; nhist = nhist + 1;
                end
            end
            for (i = 0; i < nseen; i = i + 1) begin
                c = seen[i];
                if (^c === 1'bx) continue;
                if (c === 24'h0) continue;              // black is a legal background
                hit = 0;
                for (k = 0; k < ncol_seen && !hit; k = k + 1)
                    if (col_seen[k] === c) hit = 1;
                if (hit) continue;                      // already judged
                if (ncol_seen < 128) begin
                    col_seen[ncol_seen] = c; ncol_seen = ncol_seen + 1;
                end
                hit = 0;
                for (k = 0; k < nhist && !hit; k = k + 1)
                    if (hist_rgb[k] === c) hit = 1;
                if (!hit) begin
                    col_bad = col_bad + 1;
                    errors = errors + 1;
                    if (col_bad <= 5)
                        $display("  COLOUR %h on screen is not a decoding of any palette entry: channels are not in the nibbles the game uses", c);
                end
            end
        end
    endtask

    task automatic dump_frame;
        integer i, idx;
        begin
            if (frame_w > 0 && frame_h > 0) begin
                fd = $fopen($sformatf("%s/frame%02d.ppm", framedir, frames), "wb");
                if (fd == 0) begin
                    errors = errors + 1;
                    $display("  cannot open frame file");
                end else begin
                    $fwrite(fd, "P6\n%0d %0d\n255\n", frame_w, frame_h);
                    for (i = 0; i < frame_w * frame_h; i = i + 1) begin
                        idx = i;
                        $fwrite(fd, "%c%c%c", fb_r[idx], fb_g[idx], fb_b[idx]);
                    end
                    $fclose(fd);
                end
            end
            $display("  frame %0d: %0dx%0d  colours=%0d  nonblack=%0d  mean=%0.1f/%0.1f/%0.1f",
                     frames, frame_w, frame_h, nseen, nonzero,
                     sum_r / (fbp == 0 ? 1 : fbp), sum_g / (fbp == 0 ? 1 : fbp),
                     sum_b / (fbp == 0 ? 1 : fbp));
            $display("         writes: vm_pix=%0d rast=%0d blit=%0d  pages=[%0d %0d %0d %0d]",
                     vm_pix_we, rast_pix_we, blit_we, pg_we[0], pg_we[1], pg_we[2], pg_we[3]);
            if (nseen >= MIN_COLOURS && nonzero > 0) rich_frames = rich_frames + 1;
            if (nseen > max_colours) max_colours = nseen;
            check_colours;
            $fflush;
        end
    endtask

    // The VM's video is captured on the pixel clock, which here is clk_core.
    // Is the VM asking and not being served? Distinguishes 'the ROM is not answering' from
    // 'the VM stopped asking', which is the first question a black screen poses.
    integer starving = 0;
    // Was the VM's byte stream clean before it was allowed to run? aw_rom serves its own
    // trailer check while vm_running is low; if any of those bytes reach mem_data_available,
    // the VM's preload latches them and its address walk moves before the first real
    // instruction - which is exactly how a boot sequence ends up reading from
    // trailer_address + segment_offset, as measured. Count it, do not reason about it.
    integer tr_da_before_run = 0, tr_acc_logged = 0;
    always @(posedge clk_core) begin
        if (mem_data_available && !design_run) tr_da_before_run = tr_da_before_run + 1;
        if (design_run && mem_in_ready && !served_prev && tr_acc_logged < 12) begin
            $display("  TRACE first acceptance %0d: addr=%h (vm_running just rose, bytes=%0d)",
                     tr_acc_logged, mem_addr, bytes_to_vm);
            tr_acc_logged = tr_acc_logged + 1;
        end
    end

    always @(posedge clk_core) begin
        if (mem_in_ready && !mem_data_available) starving = starving + 1;
        else if (mem_data_available) starving = 0;
    end

    // +ADDRLOG=<n> - the address of every stream acceptance, for diffing against the
    // reference design's `FILL @addr` trace. The bench sees the same thing the VM asked for,
    // so this is the one comparison that needs no SIMULATION build of the SoC: the design is
    // translated for synthesis, which strips the __display lines from vm.si, and only the
    // reference sim can print opcodes. Addresses are the pack offset (bit 20 set = the
    // pre-rendered text area that op_drawString seeks to), so a run that draws text has to
    // show requests up here with bit 20 on - and the run that motivated this showed none.
    // Pixel-side counters for the missing-text investigation. The VM's direct pixel port
    // (`vm.pix_wenable`) is the ONLY user of which op_drawString writes -- sprites and
    // polygons go through the blitter and rasterizer -- so "the game asked for N text pixels"
    // against "page N saw M writes" separates a dead write path from writes that are being
    // dropped by the display-page override (our port matches upstream in dropping those, and
    // dropping them is exactly what a black screen with a happy VM looks like).
    wire        tr_vm_pix_we   = u_soc._w_vm_pix_wenable;
    wire        tr_rast_pix_we = u_soc._w_rast_pix_wenable;
    wire        tr_blit_we     = u_soc._w_blit_dst_wenable;
    integer     vm_pix_we = 0, rast_pix_we = 0, blit_we = 0;
    integer     pg_we[0:3] = '{0,0,0,0};
    always @(posedge clk_core) begin
        if (tr_vm_pix_we)   vm_pix_we   = vm_pix_we   + 1;
        if (tr_rast_pix_we) rast_pix_we = rast_pix_we + 1;
        if (tr_blit_we)     blit_we     = blit_we     + 1;
        if (u_soc._t__page0_wenable) pg_we[0] = pg_we[0] + 1;
        if (u_soc._t__page1_wenable) pg_we[1] = pg_we[1] + 1;
        if (u_soc._t__page2_wenable) pg_we[2] = pg_we[2] + 1;
        if (u_soc._t__page3_wenable) pg_we[3] = pg_we[3] + 1;
    end

    // ---- text strip monitor -------------------------------------------------------------
    // op_drawString writes a text strip straight into a page: one byte off the ROM stream is
    // one destination pixel, and the destination starts at x*8 + y*320 (vm.si:2543), 320 bytes
    // per row. So the write address MUST advance exactly one per stream byte for the whole
    // strip. Gain or lose a byte mid-strip and every later row slides sideways - the hardware
    // symptom "each pixel line of the text is offset to the left" - while a merely wrong byte
    // value could only speckle the glyphs. A rewind (aw_rom re-serving bytes the VM already
    // consumed) does exactly that: the VM keeps advancing pix_waddr over data it has seen.
    // Watch the vm's own write port against the stream and report drift with its row number.
    localparam integer TXT_GAP = 4000;      // this many cycles with no vm write = new strip
    reg      txt_in_strip = 0;
    integer  txt_gap = 0;
    integer  txt_base = 0;                  // destination pixel of the strip's first write
    integer  txt_k0 = 0;                    // bytes_to_vm when the strip began
    integer  txt_off = -1;                  // first (addr - base - k); must stay constant
    integer  txt_strips = 0, txt_writes = 0, txt_drift = 0, txt_val = 0, txt_rewind = 0;
    integer  txt_last_row = 0, txt_f0 = 0, txt_f1 = 0;
    integer  txt_src = 0, txt_cmis = 0;      // source byte of the strip, content mismatches
    integer  txt_acc = 0;                    // acceptances seen inside the current strip
    integer  txt_k = 0;                      // bytes the VM has consumed since the strip began
    reg [7:0] txt_data_d = 8'h0;
    reg       txt_avail_d = 1'b0;
    always @(posedge clk_core) begin
        txt_avail_d <= mem_data_available;
        txt_data_d  <= mem_data;
        if (u_rom.rewind && txt_in_strip) txt_rewind = txt_rewind + 1;
        // The VM's drawString loop sets mem.addr once and then holds in_ready, so an acceptance
        // in the middle of a strip is the reader restarting. Whether that re-serves old bytes or
        // picks up at the byte the VM still wants is the whole question, and this says which:
        // the address on a restart tells it directly.
        if (u_rom.accept_vm && txt_in_strip) begin
            txt_acc = txt_acc + 1;
            if (txt_acc <= 6)
                $display("  TEXT RE-ACCEPT k=%0d addr=%0h (strip src=%0h, expected next byte address %0h)",
                         bytes_to_vm - txt_k0, mem_addr, txt_src, txt_src + (bytes_to_vm - txt_k0));
        end
        if (tr_vm_pix_we) txt_gap = 0; else txt_gap = txt_gap + 1;
        if (tr_vm_pix_we && (!txt_in_strip || txt_gap > TXT_GAP)) begin
            // first write of a strip: the address jumps here, so nothing to compare yet
            txt_in_strip = 1;
            txt_base     = u_soc._w_vm_pix_waddr;
            txt_k0       = bytes_to_vm;
            txt_src      = stream_base;   // the acceptance this strip's bytes come from
            // Byte 0 is compared here as well: this branch is the first write's cycle, and the
            // branch below never sees it. Without this the first pixel of every strip goes
            // unchecked, which is a strange thing to leave out of a content check.
            if (txt_avail_d && txt_data_d !== ref_mem[txt_src]) begin
                txt_cmis = txt_cmis + 1;
                $display("  TEXT CONTENT strip %0d FIRST byte: got %02h, image byte %02h at %0h",
                         txt_strips, txt_data_d, ref_mem[txt_src], txt_src);
            end
            txt_off      = -1;
            txt_f0       = frames;
            txt_strips   = txt_strips + 1;
            if (txt_strips <= 8)
                $display("  TEXT strip %0d: dst=%0d (x=%0d y=%0d) at stream byte %0d frame %0d",
                         txt_strips, txt_base, txt_base % 320, txt_base / 320, bytes_to_vm, frames);
        end else if (tr_vm_pix_we) begin
            txt_writes = txt_writes + 1;
            txt_f1     = frames;
            begin : txt_chk
                integer off;
                txt_k = bytes_to_vm - txt_k0;
                off = u_soc._w_vm_pix_waddr - txt_base - txt_k;
                if (txt_off < 0) txt_off = off;
                else if (off != txt_off) begin
                    txt_drift = txt_drift + 1;
                    if (txt_drift <= 8)
                        $display("  TEXT DRIFT strip %0d write %0d: dst=%0d row %0d col %0d, address moved by %0d for %0d stream bytes (offset now %0d, was %0d) rewinds=%0d",
                                 txt_strips, txt_writes, u_soc._w_vm_pix_waddr,
                                 (u_soc._w_vm_pix_waddr - txt_base) / 320,
                                 (u_soc._w_vm_pix_waddr - txt_base) % 320,
                                 u_soc._w_vm_pix_waddr - (txt_base + txt_off + txt_k - 1),
                                 txt_k, off, txt_off, rewinds);
                end
            end
            txt_last_row = (u_soc._w_vm_pix_waddr - txt_base) / 320;
            // CONTENT, which the address check cannot do: the VM writes byte k of this strip at
            // base+k, so the byte itself has to be the pack's byte at src+k. A stream restart
            // hands out bytes the VM already consumed, which leaves the address arithmetic perfect
            // (drift=0) while the picture painted comes from the wrong offsets - a strip whose rows
            // are pulled sideways. Compare against the image, not against the design.
            if (txt_avail_d && (txt_src + txt_k) < PACK_BYTES) begin
                if (txt_data_d !== ref_mem[txt_src + txt_k]) begin
                    txt_cmis = txt_cmis + 1;
                    if (txt_cmis <= 6)
                        $display("  TEXT CONTENT strip %0d write %0d: pixel %0d (row %0d col %0d) got %02h, image byte %02h at %0h (k=%0d). Image around it: %02h %02h [%02h] %02h %02h. Acceptances since the strip began: %0d",
                                 txt_strips, txt_writes, u_soc._w_vm_pix_waddr,
                                 (u_soc._w_vm_pix_waddr - txt_base) / 320,
                                 (u_soc._w_vm_pix_waddr - txt_base) % 320,
                                 txt_data_d, ref_mem[txt_src + txt_k], txt_src + txt_k, txt_k,
                                 ref_mem[txt_src + txt_k - 2], ref_mem[txt_src + txt_k - 1],
                                 ref_mem[txt_src + txt_k], ref_mem[txt_src + txt_k + 1],
                                 ref_mem[txt_src + txt_k + 2], txt_acc);
                end
            end
            // Value side: palid = color & byte[0:3], and the write only happens when byte[4]
            // is set. A write whose byte has bit4 clear, or a colour with bits outside the
            // byte's nibble, means the enable/colour and the byte are not the same byte.
            if (txt_avail_d) begin
                if (((u_soc._w_vm_pix_palid & ~txt_data_d[3:0]) != 4'd0) ||
                    (txt_data_d[4] == 1'b0)) begin
                    txt_val = txt_val + 1;
                    if (txt_val <= 5)
                        $display("  TEXT VALUE strip %0d write %0d: byte=%h palid=%h dst=%0d (bit4=%b)",
                                 txt_strips, txt_writes, txt_data_d, u_soc._w_vm_pix_palid,
                                 u_soc._w_vm_pix_waddr, txt_data_d[4]);
                end
            end
        end
    end

    integer addrlog = 0, addrlogged = 0;
    reg     inr_log_q = 1'b0;
    always @(posedge clk_core) begin
        inr_log_q <= mem_in_ready;
        if (addrlog != 0 && design_run && mem_in_ready && !inr_log_q) begin
            if (addrlogged < addrlog)
                $display("  ACC @%h", mem_addr);
            addrlogged = addrlogged + 1;
        end
    end

`ifdef SOC_TRACE
    // ---- where the VM is stuck, if it is -------------------------------------------
    // vm.si has five copies of `while (rasterizer_busy | blitter_busy) { }`; the polygon op
    // hits it right after reading numPoints (vm.si:267), which is where the byte count stops.
    // A busy that never falls is indistinguishable from a ROM that stopped answering by
    // looking at the ROM alone, so take the two bits straight out of the generated netlist.
    wire       tr_rast_busy  = u_soc._w_rast_busy;
    wire       tr_blit_busy  = u_soc._w_blit_busy;
    wire       tr_rast_start = u_soc._w_vm_rasterizer_start;
    wire       tr_blit_start = u_soc._w_vm_blitter_start;
    wire       tr_page_swap  = u_soc._w_vm_page_swap;
    wire       tr_pal_swap   = u_soc._w_vm_pal_swap;
    wire [5:0] tr_numv       = u_soc._w_vm_polygon_numv;
    wire [9:0] tr_bbw        = u_soc._w_vm_polygon_bbw;
    wire [9:0] tr_bbh        = u_soc._w_vm_polygon_bbh;

    reg  tr_p_rast, tr_p_blit, tr_p_rstart, tr_p_bstart, tr_p_swap, tr_p_pal, tr_p_leds_seen;
    reg [7:0] tr_p_leds;
    integer tr_rast_high = 0, tr_blit_high = 0, tr_events = 0;
    // Total pixel write pulses reaching the pages. 'nothing on screen' with a blitter that
    // completed 64000 writes is either writes going to a page nobody displays, or writes that
    // never reach a page at all; this counter is the difference, and which of p0..p3 fills up
    // says the rest.
    integer tr_wpulse = 0;
    // Split by source, because 'writes are issued but the pages stay empty' means either the
    // blitter is copying an empty source (its src selector picks a page nobody has painted,
    // or a selector value the read mux has no case for, which reads as 0) or the write
    // enable never reaches the memory. A single OR cannot tell those apart.
    integer tr_w_vm = 0, tr_w_rast = 0, tr_w_blit = 0, tr_blitsrc_hist [0:7];
    integer tr_pagen_w [0:3];
    integer tr_mem_wen1 = 0;
    reg [3:0] tr_mem_wdata_or = 4'h0;
    reg [3:0] tr_rast_pal_or = 4'h0, tr_blit_data_or = 4'h0;
    integer tr_rast_oob = 0, tr_blit_oob = 0;
    reg [15:0] tr_addr_max = 0;
    integer tr_poly_wen = 0;
    integer tr_acc = 0;
    reg [23:0] tr_addr_lo = 24'hffffff, tr_addr_hi = 0;
    always @(posedge clk_core) begin
        if (u_soc._w_vm_pix_wenable)     tr_w_vm   = tr_w_vm   + 1;
        if (u_soc._w_rast_pix_wenable)   tr_w_rast = tr_w_rast + 1;
        if (u_soc._w_blit_dst_wenable)   tr_w_blit = tr_w_blit + 1;
        tr_blitsrc_hist[u_soc._w_vm_blitter_src] = tr_blitsrc_hist[u_soc._w_vm_blitter_src] + 1;
        if (u_soc._t__page0_wenable) tr_pagen_w[0] = tr_pagen_w[0] + 1;
        if (u_soc._t__page1_wenable) tr_pagen_w[1] = tr_pagen_w[1] + 1;
        if (u_soc._t__page2_wenable) tr_pagen_w[2] = tr_pagen_w[2] + 1;
        if (u_soc._t__page3_wenable) tr_pagen_w[3] = tr_pagen_w[3] + 1;
        if (u_soc._w_vm_pix_wenable | u_soc._w_rast_pix_wenable
            | u_soc._w_blit_dst_wenable) tr_wpulse = tr_wpulse + 1;
        // The memory's OWN port, and every data value it has ever been given. 'wen pulses at
        // the page module but the buffer is empty' has one remaining innocent explanation -
        // my probe is not reading the array that is being written - and one very guilty one -
        // the write data is constant 0, which is what a blitter copying an empty page and a
        // VM clearing to colour 0 both look like. These settle it.
        if (u_soc.page1.__mem__pixels.in_wenable) begin
            tr_mem_wen1 = tr_mem_wen1 + 1;
            tr_mem_wdata_or = tr_mem_wdata_or | u_soc.page1.__mem__pixels.in_wdata;
        end
        tr_mem_wdata_or = tr_mem_wdata_or | (u_soc._t__page1_wenable ? u_soc._d__page1_wdata : 4'h0);
        // Every write so far has carried the value 0, which moves the question from the write
        // path to the content: either the game really is asking for colour 0 (a screen clear
        // and blits of an empty page do exactly that), or its pixel address is out of range
        // and the tool drops the write silently - buffer[] is 64,000 entries but the address
        // is 16 bits, so anything >= 64,000 vanishes without an error. These say which.
        if (u_soc._w_rast_pix_wenable) begin
            tr_rast_pal_or = tr_rast_pal_or | u_soc._w_rast_pix_palid;
            if (u_soc._w_rast_pix_waddr > 16'd63999) tr_rast_oob = tr_rast_oob + 1;
            if (u_soc._w_rast_pix_waddr > tr_addr_max) tr_addr_max = u_soc._w_rast_pix_waddr;
        end
        if (u_soc.__mem__polygon.in_wenable1) tr_poly_wen = tr_poly_wen + 1;
        if (u_soc._w_blit_dst_wenable) begin
            tr_blit_data_or = tr_blit_data_or | u_soc._w_blit_dst_data;
            if (u_soc._w_blit_dst_addr > 16'd63999) tr_blit_oob = tr_blit_oob + 1;
        end
    end
    reg tr_p_blen = 1'bx;

    // enabled is (~display_conflict)|vblank; watch it and the counter once a blit is in flight
    always @(posedge clk_core) begin
        if (tr_blit_busy && (tr_blit_high % 20000) == 19999)
            $display("  TRACE blit busy %0d: enabled=%b count=%0d prev=%0d src_addr=%0d dst_wenable=%b",
                     tr_blit_high, u_soc.blit.in_enabled, u_soc.blit._q_count,
                     u_soc.blit._q_prev_count, u_soc.blit.out_src_addr, u_soc.blit.out_dst_wenable);
    end

    always @(posedge clk_core) begin
        if (tr_rast_busy !== tr_p_rast) begin
            $display("  TRACE t=%0t rast_busy %b -> %b (was %0d cycles) bytes=%0d addr=%h",
                     $time, tr_p_rast, tr_rast_busy, tr_rast_high, bytes_to_vm, mem_addr);
            tr_rast_high = 0; tr_p_rast = tr_rast_busy; tr_events = tr_events + 1;
        end else if (tr_rast_busy) tr_rast_high = tr_rast_high + 1;

        if (tr_blit_busy !== tr_p_blit) begin
            $display("  TRACE t=%0t blit_busy %b -> %b (was %0d cycles) bytes=%0d addr=%h",
                     $time, tr_p_blit, tr_blit_busy, tr_blit_high, bytes_to_vm, mem_addr);
            tr_blit_high = 0; tr_p_blit = tr_blit_busy; tr_events = tr_events + 1;
        end else if (tr_blit_busy) tr_blit_high = tr_blit_high + 1;

        if (tr_rast_start && !tr_p_rstart) begin
            // The rasterizer traces whatever is in the polygon RAM; a degenerate draw at
            // address 0 with colour 0 is what an EMPTY polygon RAM looks like from the pixel
            // port, so dump the RAM and the VM's own vertex parameters at the moment it is
            // told to start. If the RAM is zero and polygon_wenable1 never pulsed, the VM's
            // writes are the bug and the rasterizer is innocent.
            $display("  TRACE t=%0t RASTERIZER_START numv=%0d bbw=%0d bbh=%0d zoom=%0d color=%0d px=%0d py=%0d bytes=%0d polywen=%0d",
                     $time, tr_numv, tr_bbw, tr_bbh,
                     u_soc._w_vm_polygon_zoom, u_soc._w_vm_polygon_color,
                     u_soc._w_vm_polygon_px, u_soc._w_vm_polygon_py, bytes_to_vm, tr_poly_wen);
            $display("        polygon[0..7] = %h %h %h %h %h %h %h %h",
                     u_soc.__mem__polygon.buffer[0], u_soc.__mem__polygon.buffer[1],
                     u_soc.__mem__polygon.buffer[2], u_soc.__mem__polygon.buffer[3],
                     u_soc.__mem__polygon.buffer[4], u_soc.__mem__polygon.buffer[5],
                     u_soc.__mem__polygon.buffer[6], u_soc.__mem__polygon.buffer[7]);
        end
        if (tr_blit_start && !tr_p_bstart)
            $display("  TRACE t=%0t BLITTER_START bytes=%0d", $time, bytes_to_vm);
        // The blitter is a counter 0..63999 gated by 'enabled' (a5k.si:122): busy can only
        // fall when prev_count reaches 63999, so a busy that never falls means either enabled
        // never goes true or the counter is not running. These two say which, and they are
        // the difference between a port bug in aw_pocket.si and something deeper.
        if (u_soc.blit.in_enabled !== tr_p_blen) begin
            $display("  TRACE t=%0t blitter enabled %b -> %b  count=%0d prev=%0d",
                     $time, tr_p_blen, u_soc.blit.in_enabled,
                     u_soc.blit._q_count, u_soc.blit._q_prev_count);
            tr_p_blen = u_soc.blit.in_enabled;
        end
        if (tr_page_swap && !tr_p_swap)
            $display("  TRACE t=%0t PAGE_SWAP bytes=%0d frames=%0d", $time, bytes_to_vm, frames);
        if (tr_pal_swap && !tr_p_pal)
            $display("  TRACE t=%0t PAL_SWAP bytes=%0d frames=%0d", $time, bytes_to_vm, frames);
        if (leds !== tr_p_leds) begin
            $display("  TRACE t=%0t leds %b -> %b bytes=%0d", $time, tr_p_leds, leds, bytes_to_vm);
            tr_p_leds = leds;
        end
        tr_p_rstart = tr_rast_start; tr_p_bstart = tr_blit_start;
        tr_p_swap   = tr_page_swap;   tr_p_pal    = tr_pal_swap;
    end

    // The interesting state is the last one, so say it once when the VM has stopped asking.
    always @(posedge clk_core) begin
        if (rom_ready && bytes_to_vm > 0 && tr_events >= 0) begin
            tr_idle = tr_idle + 1;
            if (tr_idle == 200000) begin
                $display("  TRACE idle for 200k cycles: rast_busy=%b (%0d) blit_busy=%b (%0d) rast_start=%b blit_start=%b page_swap=%b leds=%b",
                         tr_rast_busy, tr_rast_high, tr_blit_busy, tr_blit_high,
                         tr_rast_start, tr_blit_start, tr_page_swap, leds);
                $display("  TRACE blitter: enabled=%b count=%0d prev=%0d busy=%b",
                         u_soc.blit.in_enabled, u_soc.blit._q_count,
                         u_soc.blit._q_prev_count, u_soc.blit._q_busy); $fflush;
            end
        end
    end
    integer tr_idle = 0;
`endif

    always @(posedge clk_core) begin
        if (game_de) begin
            if (fbp < MAXPIX) begin
                fb_r[fbp] = game_r; fb_g[fbp] = game_g; fb_b[fbp] = game_b;
                sum_r = sum_r + game_r; sum_g = sum_g + game_g; sum_b = sum_b + game_b;
                if (game_r != 0 || game_g != 0 || game_b != 0) nonzero = nonzero + 1;
                begin : colhunt
                    integer k;
                    bit found;
                    found = 0;
                    for (k = 0; k < nseen && !found; k = k + 1)
                        if (seen[k] == {game_r, game_g, game_b}) found = 1;
                    if (!found && nseen < 64) begin
                        seen[nseen] = {game_r, game_g, game_b};
                        nseen = nseen + 1;
                    end
                end
            end
            fbp      = fbp + 1;
            line_pix = line_pix + 1;
        end
        if (!game_de && line_pix > 0) begin
            // a line just ended; the first one sets the width we write the picture at
            if (frame_w == 0) frame_w = line_pix;
            frame_h = frame_h + 1;
            line_pix = 0;
        end
        // chk_active: while the boot check owns the reader, the bytes coming out are its own
        // trailer reads (TRAILER_ADDR, repeated) and not the VM's stream.
        if (mem_data_available && !u_rom.chk_active) begin
            bytes_to_vm = bytes_to_vm + 1;
            if ((stream_base + served_k) >= PACK_BYTES) chk_unchk = chk_unchk + 1;
            // Every byte handed to the VM, checked against the image. When the game draws
            // nothing this is what tells you whether the ROM lied or the VM asked for
            // something strange: 'the byte was wrong' and 'the address was wrong' look
            // identical from a black screen.
            //
            // served_k advances on every byte and is reset ONLY by a new acceptance - never by a
            // restart inside one. That is the whole point. Mirroring the design's restart here is
            // what let 405 re-served-byte storms read as a clean stream, because a repeated byte
            // compared against the position the design had just rewound to and matched. The VM
            // has no such reset, so this is the check that says whether a recovery was lossless.
            if (served_k >= 0 && (stream_base + served_k) < PACK_BYTES && !acc_reserve) begin
                chk_compared = chk_compared + 1;
                if (mem_data !== ref_mem[stream_base + served_k]) begin
                    errors = errors + 1;
                    if (errors < 400)
                        $display("  ROM GAVE WRONG BYTE t=%0t addr=%0h got=%02h image=%02h (k=%0d) c_addr=%0h c_tag=%0h n_addr=%0h rewinds=%0d",
                                 $time, stream_base + served_k, mem_data,
                                 ref_mem[stream_base + served_k], served_k,
                                 u_rom.c_addr, u_rom.c_waddr, u_rom.n_addr, rewinds);
                end
            end
            served_k = served_k + 1;
        end
        // Anchor on the design's own acceptance and on nothing else. Two wrong anchors have
        // now been measured, and in both cases they framed the ROM for a murder it did not
        // commit:
        //
        //  - served_prev was mem_data_available, so a stream that ended with data still
        //    asserted one cycle into the next request skipped the anchor, and every byte of
        //    the new stream was compared against the previous stream's base: a tidy
        //    'got = image[k-1]' cascade that looked exactly like the ROM being a byte behind.
        //  - "or any address change while the request is low" over-corrected it. The VM moves
        //    mem_addr one or two cycles BEFORE it raises in_ready, and the last byte of the old
        //    stream is delivered in between, so the checker re-based on the new address and
        //    then compared the old stream's final byte against it. Three errors in a 95-frame
        //    run, every one of them at k=0, and +READ_TRACE showed the design had taken that
        //    byte legitimately one cycle earlier (c_addr=125a1, tag matched, rewinds=0) with
        //    its ACCEPT for 0x22dd still one cycle away. The same three errors appear against
        //    the 1038a netlist, so nothing in the census work caused them: the ROM was right
        //    and the bench was early.
        //
        // accept_vm is the design starting a stream from a new address (reset the count);
        // rewind is the same stream started over from c_start (reset the count, keep the base).
        if (u_rom.accept_vm) begin
            // The pack offset, NOT the address on the wire: aw_rom's map puts the image in a
            // 2 MB bank and [23:21] select the bank, so every address this design asks for
            // carries +0x200000. Compared raw, `stream_base + k < PACK_BYTES` was false from
            // the first byte and the check below -- the one that says 'the ROM lied' rather
            // than 'the screen is black' -- had never compared a single byte in any run.
            stream_base = mem_addr & 21'h1F_FFFF;   // 2 MB image window, NOT 22'h1F_FFFF: bit 21 kept the
                                       // +0x200000 base and made the byte check vacuous for
                                       // every part1 address (0x20269d..0x20d51e)
            served_k    = 0;
            // What the interpreter is really doing. If the game runs its frame loop, the
            // addresses it asks for sweep the bytecode segment and the per-frame acceptance
            // count is roughly steady; if it is stuck on one script entry the range collapses
            // to a handful of addresses. 'Drawing nothing' has to be separated from 'running
            // a script that says draw nothing', and this is the cheapest way to do it.
`ifdef SOC_TRACE
            tr_acc = tr_acc + 1;
            if (mem_addr < tr_addr_lo) tr_addr_lo = mem_addr;
            if (mem_addr > tr_addr_hi) tr_addr_hi = mem_addr;
`endif
        end else if (u_rom.rewind) begin
            // This used to reset served_k, on the reasoning "same stream, same base, handed out
            // again from c_start". That is what the DESIGN does, and mirroring it made the
            // checker blind to the one thing that matters: the VM has no idea a restart happened.
            // It keeps its own position (op_drawString keeps incrementing pix_waddr), so every
            // byte the reader re-issues after having already handed one out is a byte the VM will
            // write at the wrong place. The reset was the blind spot, not the truth: measure the
            // stream the way the consumer sees it, and count a rewind that happens after bytes
            // have gone out as the design error it is.
            // A restart is a recovery inside one acceptance: the reader parks and re-seeks.
            // It is only harmless if it resumes at the byte the VM has not been given, so the
            // count is printed and the byte check below is what decides: served_k keeps running
            // across restarts, which is exactly how the VM sees the stream. Before the design
            // fix, restarts after N bytes produced N-byte repeats here; a green byte count with
            // restarts nonzero is the proof that a restart costs nothing but time.
            if (served_k > 0) begin
                rewind_reissue = rewind_reissue + 1;
                if (rewind_reissue <= 3)
                    $display("  STREAM RESTART t=%0t mid-acceptance, after %0d bytes (base=%0h): continuing to compare against src+k, because the VM's position does not reset.",
                             $time, served_k, stream_base);
            end
        end
        served_prev   = mem_data_available;
        if (game_vs) begin
            if (fbp > 0) begin
`ifdef SOC_TRACE
                // 'colours=1, nonblack=0' has three causes and the frame cannot tell them
                // apart: nothing was ever drawn, something was drawn into a page that is not
                // being displayed, or pixels exist but the palette maps them to black. These
                // three numbers do.
                begin : pagehunt
                    integer i, nz1, nz2, nzpal, nz0, nz3;
                    nz1 = 0; nz2 = 0; nzpal = 0; nz0 = 0; nz3 = 0;
                    for (i = 0; i < 64000; i = i + 1) begin
                        if (u_soc.page0.__mem__pixels.buffer[i] !== 4'h0) nz0 = nz0 + 1;
                        if (u_soc.page1.__mem__pixels.buffer[i] !== 4'h0) nz1 = nz1 + 1;
                        if (u_soc.page2.__mem__pixels.buffer[i] !== 4'h0) nz2 = nz2 + 1;
                        if (u_soc.page3.__mem__pixels.buffer[i] !== 4'h0) nz3 = nz3 + 1;
                    end
                    for (i = 0; i < 32; i = i + 1)
                        if (u_soc.__mem__palette.buffer[i] !== 16'h0) nzpal = nzpal + 1;
                    $display("  TRACE f%0d: nz p0=%0d p1=%0d p2=%0d p3=%0d | wen p0=%0d p1=%0d p2=%0d p3=%0d | src vm=%0d rast=%0d blit=%0d memwen1=%0d wdata_or=%h | rpal_or=%h roob=%d amax=%h bdata_or=%h boob=%d | dst=%0d show1=%b pal=%0d | acc=%0d range=%h..%h",
                             frames, nz0, nz1, nz2, nz3,
                             tr_pagen_w[0], tr_pagen_w[1], tr_pagen_w[2], tr_pagen_w[3],
                             tr_w_vm, tr_w_rast, tr_w_blit, tr_mem_wen1, tr_mem_wdata_or,
                             tr_rast_pal_or, tr_rast_oob, tr_addr_max,
                             tr_blit_data_or, tr_blit_oob,
                             u_soc._w_vm_blitter_dst, u_soc._w_show_page1, nzpal,
                             tr_acc, tr_addr_lo, tr_addr_hi);
                    tr_acc = 0; tr_addr_lo = 24'hffffff; tr_addr_hi = 0;
                    $fflush;
                end
`endif
                dump_frame;
                if (nonzero == 0) black_frames = black_frames + 1;
                frames = frames + 1;   // the watchdog watches this counter, not a copy of it
            end
            fbp = 0; frame_w = 0; frame_h = 0;
            sum_r = 0.0; sum_g = 0.0; sum_b = 0.0; nonzero = 0; nseen = 0;
        end
    end

    // ---- sequence ------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("PACK=%s", pack_hex))
            $fatal(1, "tb_soc: +PACK=<pack.hex> is required");
        void'($value$plusargs("PACE=%d", pace));
        void'($value$plusargs("FRAMES=%d", max_frames));
        void'($value$plusargs("NOINPUT=%d", noinput));
        void'($value$plusargs("PACK_KIND=%s", pack_kind));
        void'($value$plusargs("ADDRLOG=%d", addrlog));
        if (!$value$plusargs("FRAMEDIR=%s", framedir)) framedir = "/tmp/awframes";

        // Probe sanity check. Everything the diagnosis below rests on is a hierarchical read
        // of a memory inside the generated design; if that read is not looking at the array
        // being written, every conclusion drawn from it is worthless. So write a sentinel and
        // read it back before anything else happens.
        // Cold-start fidelity. The bench and iverilog both hand the design BRAM that is
        // zero at t=0, and the .si zeroes the video pages under SIMULATION only; a Cyclone V
        // comes out of configuration with whatever its memory cells hold, and a *warm* core
        // relaunch keeps the previous session's contents. The hardware report is exactly
        // that shape - first launch after power-on black, quit and relaunch fine - so make
        // the difference testable: +FUZZ_BRAM=1 paints every ram the design leaves
        // uninitialized with noise before the game gets it. If the boot still works, the
        // init "fix" would be superstition and the cause is somewhere else.
        void'($value$plusargs("FUZZ_BRAM=%d", fuzz_bram));
        if (fuzz_bram) begin
            fz_seed = 32'h5EED1234;
            for (fz_i = 0; fz_i < 64000; fz_i = fz_i + 1) begin
                fz_seed = fz_seed * 32'd1664525 + 32'd1013904223;
                u_soc.page0.__mem__pixels.buffer[fz_i] = fz_seed[ 3: 0];
                u_soc.page1.__mem__pixels.buffer[fz_i] = fz_seed[ 7: 4];
                u_soc.page2.__mem__pixels.buffer[fz_i] = fz_seed[11: 8];
                u_soc.page3.__mem__pixels.buffer[fz_i] = fz_seed[15:12];
                if (fz_i < 32)
                    u_soc.__mem__palette.buffer[fz_i] = {fz_seed[31:16], fz_seed[15:0]};
                if (fz_i < 64)
                    u_soc.__mem__polygon.buffer[fz_i] = {fz_seed, ~fz_seed};
            end
            $display("tb_soc: FUZZ_BRAM on - pages/palette/polygon filled with noise");
            $fflush;
        end

        u_soc.page1.__mem__pixels.buffer[123] = 4'hE;
        if (u_soc.page1.__mem__pixels.buffer[123] !== 4'hE)
            $display("tb_soc: PROBE IS BROKEN - cannot round-trip page1's pixel array");
        else
            $display("tb_soc: probe ok (sentinel in page1.buffer[123] reads back)");
        $readmemh(pack_hex, ref_mem);
        $display("tb_soc: pack %s, bridge pace %0d, frames %0d -> %s",
                 pack_hex, pace, max_frames, framedir); $fflush;

        dataslot_wr = 0; dataslot_addr = 0; dataslot_wdata = 0;
        dataslot_allcomplete = 0;

        #500; rst_bridge = 0;
        repeat (20) @(posedge clk_psram); rst_psram = 0;
        repeat (20) @(posedge clk_core);  rst_core  = 0;

        $display("tb_soc: with the VM in reset, its memory pins are in_ready=%b addr=%h busy=%b",
                 mem_in_ready, mem_addr, mem_busy); $fflush;
        $display("tb_soc: loading %0d bytes through the bridge", PACK_BYTES); $fflush;
        for (integer i = 0; i < PACK_WORDS; i = i + 1)
            wr32(32'h1000_0000 + i*4,
                 {ref_mem[i*4+3], ref_mem[i*4+2], ref_mem[i*4+1], ref_mem[i*4]});
        @(negedge clk_bridge); dataslot_allcomplete <= 1;
        @(negedge clk_bridge); dataslot_allcomplete <= 0;

        begin
            integer g; g = 0;
            while (!rom_ready && g < 6000000) begin @(posedge clk_core); g = g + 1; end
            $display("tb_soc: rom_ready=%b rom_error=%0d after %0d cycles",
                     rom_ready, rom_error, g); $fflush;
            if (!rom_ready) begin
                $display("tb_soc: FAIL - the pack never verified, so the VM stays in reset.");
                $display("          rom_error=%0d (1 bad trailer, 2 bridge overran the drain -",
                         rom_error);
                $display("          lower +PACE, 3) 3 waited the chip). Frames so far are the");
                $display("          idle screen, not the game.");
                $fflush;
                $finish;
            end
        end

        // the screen shows the ROM's state until the pack checks out; from here the VM's
        // own video takes over, exactly as core_top muxes it
        @(posedge clk_core); design_run = 1;
        $display("tb_soc: VM reset released at t=%0t", $time); $fflush;

        // The busy terms, one at a time, right after the release. mem_busy is an OR of six
        // things and the VM sits in `while (mem.busy) {}` until it is low, so "the VM never
        // asks for a byte" is answered completely by naming which term is high. Guessing at
        // this cost two wrong hypotheses; reading it costs one run.
        begin : busy_terms
            integer k;
            for (k = 0; k < 3; k = k + 1) begin
                repeat (100 + k * 1000) @(posedge clk_core);
                $display("  tb_soc busy[%0d]: busy=%b = busy_q=%b inr=%b%b req=%b chk_active=%b chk_cnt=%0d (vm_running=%b rom_ready=%b c_state=%0d in_ready=%b)",
                         k, u_rom.mem_busy, u_rom.busy_q, u_rom.inr[0], u_rom.inr[1],
                         u_rom.req, u_rom.chk_active, u_rom.chk_cnt,
                         u_rom.vm_running, u_rom.rom_ready, u_rom.c_state, mem_in_ready);
                $fflush;
            end
        end

        begin : run_until_frames
            integer c;
            c = 0;
            while (frames < max_frames) begin
                @(negedge clk_core);
                c = c + 1;
                if (c == 250000) begin   // every ~10 ms of design time
                    c = 0;
                    $display("  t=%0t frames=%0d bytes_to_vm=%0d addr=%h starving=%0d leds=%b",
                             $time, frames, bytes_to_vm, mem_addr, starving, leds); $fflush;
                end
            end
        end

        // ---- input path: drive the pad and check the VM sees it (task #22)
        if (rom_ready) begin
            $display("=== input path (VM pad variables; vm.h and vm.si agree on the addresses) ===");
            // Expectations from vm.si's input block, and there are two traps in it that a
            // 'sensible' expectation walks straight into. Both were mine, and the design was right
            // both times - which is why these numbers are copied out of the source rather than
            // reasoned about:
            //   1. m = {12b0, jstick[2], jstick[3], jstick[1], jstick[0]} puts UP in bit 3 and
            //      DOWN in bit 2 - swapped relative to the lr/ud decode just above it, which uses
            //      jstick[2] for up and jstick[3] for down. So HERO_POS_MASK's up/down bits are
            //      the opposite way round from everything else.
            //   2. jstick[4] (fire) is not in m at all. Fire is OR-ed in as 0x80 *after*
            //      HERO_POS_MASK has been written, so POS_MASK never shows fire; only
            //      HERO_ACTION (1) and HERO_ACTION_POS_MASK (m|0x80) do.
            //      lr/ud are +-1 signed.
            in_case("none",    6'b000000, 16'sd0,  16'sd0,  16'h0000, 16'h0, 16'h0000);
            in_case("right",   6'b000001, 16'sd1,  16'sd0,  16'h0001, 16'h0, 16'h0001);
            in_case("left",    6'b000010, -16'sd1, 16'sd0,  16'h0002, 16'h0, 16'h0002);
            in_case("up",      6'b000100, 16'sd0,  -16'sd1, 16'h0008, 16'h0, 16'h0008);
            in_case("down",    6'b001000, 16'sd0,  16'sd1,  16'h0004, 16'h0, 16'h0004);
            in_case("fire",    6'b010000, 16'sd0,  16'sd0,  16'h0000, 16'h1, 16'h0080);
            in_case("rt+fire", 6'b010001, 16'sd1,  16'sd0,  16'h0001, 16'h1, 16'h0081);
            js_force_en = 1'b0;
            $display("  %0d patterns driven, the game's own pad variables reflected %0d of them",
                     in_checks, in_acted);
        end

        $display("tb_soc: data_available pulses while the VM was held off: %0d (must be 0)",
                 tr_da_before_run);
        if (tr_da_before_run != 0) errors = errors + 1;

        // APF protocol violations are a design failure even when every frame looks fine:
        // the scaler's hard rules (one-cycle vs/hs, hsync >= 3 cycles after vsync,
        // rgb=0 while de low, exactly 320x200 of de per frame) are what separate a
        // stream the Pocket accepts from one it garbles or crashes on.
        if (vid_errors != 0) begin
            $display("tb_soc: FAIL - %0d APF video protocol violations", vid_errors);
            s1_pass = 0;
        end

        // Where does a wrong byte live: in the chip, or in the way it gets read out? The
        // delivered-vs-image check cannot tell those apart and they are different bugs -- one
        // is the upload, one is the read path -- so compare the model's memory against the
        // image over the megabyte op_drawString reads. Byte order is the design's: even byte
        // in [7:0], odd byte in [15:8] (see aw_rom's c_byte mux).
        begin : psram_image_cmp
            integer i, bad, firstbad;
            bad = 0; firstbad = -1;
            for (i = 0; i < 65536; i = i + 1) begin
                if (u_mem.mem[22'h8_0000 + i[21:0]] !==
                    {ref_mem[('h10_0000 + i*2) + 1], ref_mem['h10_0000 + i*2]}) begin
                    bad = bad + 1;
                    if (firstbad < 0) firstbad = i;
                end
            end
            if (bad != 0) begin
                errors = errors + 1;
                $display("  FAIL: PSRAM disagrees with the image over the text megabyte: %0d words, first at word %0d (holds %04h, image %04h)",
                         bad, firstbad, u_mem.mem[22'h8_0000 + firstbad[21:0]],
                         {ref_mem[('h10_0000 + firstbad*2) + 1], ref_mem['h10_0000 + firstbad*2]});
            end else
                $display("  ok   PSRAM holds the image across the text megabyte (65536 words)");
        end

        // ---- text verdict ---------------------------------------------------------------
        // The strip monitor above is the answer to "each line of text is offset to the left":
        // op_drawString lays one byte down as one pixel at base+k, so if the vm's write address
        // and the byte stream disagree, every later row of the strip slides sideways.
        $display("TEXT  : %0d strips, %0d writes, drift=%0d value=%0d content=%0d rewinds_in_strip=%0d last_row=%0d (last strip frames %0d..%0d)",
                 txt_strips, txt_writes, txt_drift, txt_val, txt_cmis, txt_rewind, txt_last_row, txt_f0, txt_f1);
        $display("STREAM: %0d restarts, %0d of them AFTER bytes had already been handed to the VM (the VM keeps its own position; those shift everything after them)",
                 rewinds, rewind_reissue);
        if (txt_drift != 0 || txt_val != 0 || txt_cmis != 0) begin
            $display("        => text is NOT laid down byte-for-byte: wrong content at a correct address means the stream was handed out twice, not that the strip was mis-added.");
            errors = errors + txt_drift + txt_val + txt_cmis;
        end
        if (rewind_reissue != 0)
            $display("        %0d mid-acceptance restarts: fine while the byte check stays clean (they cost ~140 ns each), fatal the moment the reader re-issues a byte - that is what sheared the text.",
                     rewind_reissue);

        // ---- pack census (design-side counters, reported the way the CHK line does) ------
        // aw_rom adds every word it commits and, once per power-on, reads the same range back.
        // In sim there is no bridge upload, so the bench fakes the handshake and the sweep then
        // competes with the running VM for the sequencer: report progress, and only insist on
        // the sums when the sweep actually finished. A quarter mismatch is always real.
        begin : cen_report
            $display("CENSUS: arm=%0d active=%0d done=%0d timeout=%0d at word %0d qmism=%0h sum written=%08h readback=%08h",
                     u_rom.vfy_arm, u_rom.census_active, u_rom.census_done, u_rom.census_to,
                     u_rom.census_addr, u_rom.rom_census_qmism,
                     u_rom.rom_census_sum_w, u_rom.rom_census_sum_r);
            // Only judge it once the sweep is over: in sim the VM keeps the sequencer busy, so
            // a pending census is normal and says nothing about the pack.
            if (u_rom.rom_census_qmism != 4'h0) begin
                $display("        => the design's own census says a 512 KiB quarter differs between write and read-back.");
                errors = errors + 1;
            end
            // {timeout, done, gap}: judge the sums only on a completed sweep with contiguous
            // writes, the only state where written and readback have to be equal.
            if (u_rom.rom_census_stat[1] && !u_rom.rom_census_stat[0] &&
                u_rom.rom_census_sum_w !== u_rom.rom_census_sum_r) begin
                $display("        => census done without a flagged quarter, yet the two sums differ: a word changed between write and read-back.");
                errors = errors + 1;
            end
        end

        // The acceptance in flight when the run ends still has to be tallied, or the last stream
        // of every run is missing from these counts.
        close_acceptance;

        // Diagnostics print UNCONDITIONALLY, before the verdict chain. Twice now a check that
        // only fired inside the chain was outranked by an earlier branch and stayed silent: the
        // vacuous-oracle guard sat after `errors != 0`, and the unaccepted-pulse count sat after
        // `rich_frames == 0`, so the one number that explains a black screen never appeared while
        // the run was being read. A number you have to be unlucky enough to see is not a number.
        $display("tb_soc: diagnostics - bytes to VM %0d (compared %0d, outside window %0d), restarts %0d (mid-acceptance %0d), frame swaps %0d (last at frame %0d)",
                 bytes_to_vm, chk_compared, chk_unchk, rewinds, rewind_reissue, swaps,
                 last_swap_frame);
        // Standing aside is a counted, visible act: "the oracle compared nothing" and "the oracle
        // correctly declined to compare a stream that is not positional" must never be the same
        // silence. See acc_reserve above.
        $display("tb_soc: delivery oracle stood aside for %0d acceptances that re-served from their own start (%0d bytes; the fill-shift oracle still checks every byte the VM writes)",
                 n_reserve, reserve_bytes);
        // The consumer-side view of the same traffic. A short held acceptance is the bytecode
        // fill, and a gap inside one shifts the fill (vm.si:496); a long one is a string strip,
        // which survives gaps. `pulsed` is readByte, whose bytes always land with in_ready low
        // and are therefore also what `da_not_accepted` counts.
        $display("tb_soc: acceptances - bytecode-fill %0d (%0d waited for a byte before finishing, %0d early gap cycles of %0d total), tolerant %0d [%0d gap cycles], pulses landing with in_ready low %0d",
                 n_fill_acc, n_fill_bad, fill_gap_early, fill_gap_cycles, n_tol_acc,
                 tol_gap_cycles, da_not_accepted);
        // THE consumer-side verdict: every byte the VM wrote into its own 64-byte bytecode fill
        // buffer, checked against where the pack says that byte lives. This is the quantity the
        // Pocket's freeze depends on, and nothing above it measures it.
        $display("tb_soc: fill buffer - %0d writes, %0d landed on the wrong byte of the pack, %0d with no acceptance open",
                 fill_writes, fill_shift, fill_unbased);

        // A run that produced only black frames is not a pass, whatever else went right.
        // s1_pass is what decides the process exit status (see the end of this initial block):
        // until now the verdict was print-only, so a failing design still exited 0 and
        // `make sim-soc` reported success. Proven by fault injection, see the commit note.
        // This one goes FIRST on purpose. It sat after `errors != 0` for a run, where an
        // unrelated failure reached it first and a vacuous oracle was still hidden: the
        // chain's order is the difference between 'this run says nothing' and 'this run
        // says nothing but something else also went wrong'.
        if (bytes_to_vm > 1000 && chk_compared == 0) begin
            // The oracle must never be silently vacuous. Every byte fell outside the window it
            // compares, so '0 errors' was produced by comparing nothing at all.
            $display("tb_soc: FAIL - %0d bytes reached the VM and the byte oracle compared 0 of them (%0d outside the window); this run says nothing about ROM correctness",
                     bytes_to_vm, chk_unchk);
            s1_pass = 0;
        end else if (frames < 4) begin
            $display("tb_soc: FAIL - only %0d frames; the video never framed anything", frames);
            s1_pass = 0;
        end else if (pack_kind == "text" && txt_strips == 0) begin
            // part0's screen is dark in the reference too, so its content claim is the strip:
            // op_drawString has to lay its ~64,000-byte strip down. Streaming bytes while the
            // page stays untouched is not "drawing the copy-protection screen", it is drawing
            // nothing - which is exactly what this branch is for, since the rich-frame test
            // below cannot say anything true about a pack that is black by design.
            $display("tb_soc: FAIL - pack kind is %s and %0d bytes reached the VM, but op_drawString never laid down a single strip in %0d frames",
                     pack_kind, bytes_to_vm, frames);
            s1_pass = 0;
        end else if (pack_kind != "text" && rich_frames == 0) begin
            $display("tb_soc: FAIL - %0d frames, no rich frame (best %0d colours, %0d non-black, %0d bytes to the VM); a uniform fill is not a rendering",
                     frames, max_colours, frames - black_frames, bytes_to_vm);
            s1_pass = 0;
        end else if (pack_kind != "text" && black_frames == frames) begin
            $display("tb_soc: FAIL - %0d frames, every one of them black (%0d bytes reached the VM)",
                     frames, bytes_to_vm);
            s1_pass = 0;
        end else if (errors != 0) begin
            $display("tb_soc: FAIL - %0d errors", errors);
            s1_pass = 0;
        end else if (fill_shift != 0) begin
            // The consumer-side check. The delivery oracle above can be green while this is
            // red, and that difference IS the hardware bug: right bytes, wrong addresses.
            $display("tb_soc: FAIL - %0d of %0d fill-buffer writes landed where the pack says a DIFFERENT byte lives (last at fill[%0d], %0d restarts). The bytecode fill's write pointer resets on any cycle without data_available (vm.si:495), so a mid-fill gap shifts the rest of the buffer and the interpreter executes ROM data as opcodes - the Pocket's freeze",
                     fill_shift, fill_writes, last_shift_at, rewinds);
            s1_pass = 0;
        end else if (fill_unbased != 0) begin
            $display("tb_soc: FAIL - %0d fill-buffer writes happened with no acceptance open; the bench's acceptance anchor is wrong and this run cannot attribute them", fill_unbased);
            s1_pass = 0;
        end else if (n_fill_bad > n_fill_acc / 2 && 0) begin
            // DEMOTED, deliberately, and the reason is the whole point of the run that produced
            // it: a clean part1 run with ZERO restarts and a working intro had exactly one gap in
            // 558 of 559 fill-class acceptances. So "a gap happened" is not the fault - it is the
            // normal shape of this bus (the fill loop's own multi-cycle body, or the prefill
            // boundary). What matters is whether a gap MOVED A WRITE, which the fill-shift oracle
            // above measures directly. This branch stays here, disabled, so nobody re-arms a
            // counter that has been measured to fire on a working design.
        end else if (frames > 200 && swaps > 10 && (frames - last_swap_frame) > 120) begin
            // Video still counts, bytes still flow, but the page has not flipped for 2 seconds:
            // the picture on screen is a photograph of the last swap.
            $display("tb_soc: FAIL - %0d swaps but the last one was frame %0d of %0d; the game stopped presenting %0d frames (%0d bytes still streamed to the VM)",
                     swaps, last_swap_frame, frames, frames - last_swap_frame, bytes_to_vm);
            s1_pass = 0;
        end else begin
            $display("tb_soc: %0d frames, %0d non-black, %0d rich (best %0d colours), %0d bytes to the VM, %0d compared, %0d frame swaps (last at %0d), kind=%s, %0d fill writes / %0d shifted -> PASS",
                     frames, frames - black_frames, rich_frames, max_colours, bytes_to_vm, chk_compared, swaps, last_swap_frame, pack_kind, fill_writes, fill_shift);
            s1_pass = 1;
        end

        // The palette, byte-exact, as the oracle for colour. vm.si loads a palette with
        //     mem.addr = segPalettes + (paletteId << 5);   // 32 bytes = 16 12-bit colours
        //     palette.addr1 = {~pal_swap,4b000} | (n>>1);  // into the bank not on screen
        // so every entry here has to equal a 2-byte little-endian word at a known offset in
        // the pack - a check that needs no opinion about what the intro is supposed to look
        // like. "Pixels appear" and "the pixels are the right pixels" are different claims,
        // and the greens on our frame 40 are only the first of those so far.
        begin : pal_dump
            integer pi;
            // The segment table the VM loaded, in the same words the reference design prints
            // as "Hello Another World (offsets: ...)". Note each field is 17 bits
            // (_w_segPalettes is [16:0]), which is why the reference reports video2=110291 for
            // part2 where our trailer holds 241363: 241363 mod 131072 = 110291.
            // Probe validated against the reference: the golden sim prints
            // "Hello Another World (offsets: 0, 75101, 9871, 110291)" for part2, so reading
            // those four numbers back here is the sentinel - if they agree, the hierarchical
            // path and the word order are both right.
            $display("SEGOFFSETS %h %h %h %h  (want 0,1255d,268f,1aed3 for part2)",
                     u_soc.vm._q_segOffsets[31:0], u_soc.vm._q_segOffsets[63:32],
                     u_soc.vm._q_segOffsets[95:64], u_soc.vm._q_segOffsets[127:96]);
            $write("PALETTE32");
            for (pi = 0; pi < 32; pi = pi + 1) begin
                if (u_soc.__mem__palette.buffer[pi] === 16'hxxxx) $write(" xxxx");
                else $write(" %04h", u_soc.__mem__palette.buffer[pi]);
            end
            $display;
        end
        // The verdict must reach the process, or every wrapper above this is reporting on text it
        // did not read. Fault injection (VM jstick tied to 0) printed 'tb_soc: FAIL - 12 errors'
        // and exited 0; scripts/sim_soc.sh checks only rc, so a broken design was a green build.
        if (!s1_pass) begin
            $fflush;
            $fatal(1, "tb_soc: FAIL (see the checks above)");
        end
        $fflush;
        $finish;
    end

    // Watchdog. An absolute simulation-time budget is the wrong shape for this: 4 s of sim
    // time is 825x500*240 cycles at 24.75 MHz, so it capped every run at ~240 frames no
    // matter what FRAMES asked for (FRAMES=700 silently stopped at 240), and $finish carries
    // no status, so the truncated run still exited 0 and the wrapper reported success. Watch
    // for a STALL instead: one frame is 16.7 ms of sim time, so 15 frames of silence is a
    // hang and nothing legitimate. Boot is allowed longer than a frame because the pack load
    // and the boot check run before the first vsync.
    // Counts clk_core cycles since the frame counter last moved, and compares the frame counter
    // itself - not $time. Two reasons, both learned the hard way:
    //   (1) the timescale here is 1ns but $time reports picoseconds, so a budget written in ns
    //       is silently 1000x out; and
    //   (2) the previous version kept its own last_frame_t, updated from the capture loop, and
    //       that update did not take effect - the watchdog then measured 61 frames from boot on
    //       a design that was still rendering frames, and killed it. Any watchdog that shadows
    //       the observable with its own copy of it can drift from the thing it watches, so it
    //       now watches `frames`, which is exactly what this testbench prints.
    localparam integer FRAME_CYCLES = 825 * 500;    // one frame of clk_core (24.75 MHz)
    localparam integer STALL_FRAMES = 60;           // 1 s of silence = hung, nothing legit
    localparam integer STALL_CYCLES = FRAME_CYCLES * STALL_FRAMES;

    integer wd_frames_seen = 0;
    integer wd_stall       = 0;
    reg     wd_armed       = 1'b0;

    always @(posedge clk_core) begin
        if (frames != wd_frames_seen) begin
            wd_frames_seen = frames;
            wd_stall       = 0;
            wd_armed       = 1'b1;   // boot (2 MB over the bridge) must not count as a stall
        end else if (wd_armed) begin
            wd_stall = wd_stall + 1;
            if (wd_stall > STALL_CYCLES) begin
                $display("tb_soc: HUNG - frame counter stuck at %0d for %0d cycles (%0d frames)",
                         frames, wd_stall, STALL_FRAMES);
                $fflush;
                $fatal(1, "tb_soc: design stopped producing frames");
            end
        end
    end

endmodule
