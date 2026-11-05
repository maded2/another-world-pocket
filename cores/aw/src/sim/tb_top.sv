// tb_top - the whole core_top, from power-on to game video.
//
// Every other bench in this tree tests a module; none of them sees what the Pocket
// actually sees first. This one instantiates core_top with a behavioural PLL
// (apf_pll_model.v) and the PSRAM model on cram0, and checks the things that sit
// between "simulation passes" and "device works":
//
//   1. APF video protocol on the muxed pins from cycle zero - the idle screen is the
//      first stream the scaler locks onto at boot, and it has never been simulated
//      before this bench (apf_video_check enforces the hard rules: one-cycle vs/hs,
//      hsync >= 3 cycles after vsync, rgb=0 while de low, exactly 320x200 of de).
//   2. The idle screen shows only black and the white blink before a pack arrives -
//      any other colour means rom_error fired (red/purple/amber are the error states).
//   3. A synthetic pack with a valid trailer loads through the real bridge window,
//      rom_ready rises, and the mux switch to game video loses no vsync: every frame
//      boundary - idle, across the switch, and game - is exactly 825x500 cycles apart.
//   4. The host command round trip: Reset Exit releases design_run, and a Request
//      Status reads back {0x4F4B, 3}. It is "idle" (3), not "running" (4), because
//      this core ties status_setup_done to the PLL lock, so the handler's inner
//      if-else never reaches the running branch - that is what the design reports.
//   5. Audio pins: MCLK is 12.288 MHz, LRCK is 48 kHz, DAC is silent for the whole run.
//   6. The debug-key UART line (cart bank0[6]) idles high while no console traffic is due.
//
// The pack is deliberately tiny: four trailer words at pack offset 0x1FFFE0. The VM
// then runs on whatever the PSRAM model holds elsewhere (0x5A fill) and draws
// garbage - that is fine, because this bench checks protocol and sequencing, not
// game content; tb_soc owns "does the intro render".
//
// Run: scripts/sim_top.sh

`timescale 1ns/1ps
`default_nettype none

module tb_top;

    // ---- clocks -------------------------------------------------------------------
    reg clk_74a = 1'b0, clk_74b = 1'b0;
    always #6.734 clk_74a = ~clk_74a;               // 74.25 MHz
    initial begin                                   // the second 74.25 is a separate domain
        #1.3468;                                    // and gets a non-coincident phase
        forever #6.734 clk_74b = ~clk_74b;
    end

    // ---- DUT ports ------------------------------------------------------------------
    wire [23:0] video_rgb;
    wire        video_rgb_clock, video_rgb_clock_90;
    wire        video_de, video_skip, video_vs, video_hs;
    wire        audio_mclk, audio_dac, audio_lrck;
    wire        bridge_endian_little;
    reg  [31:0] bridge_addr = 0;
    reg         bridge_rd   = 1'b0;
    wire [31:0] bridge_rd_data;
    reg         bridge_wr   = 1'b0;
    reg  [31:0] bridge_wr_data = 0;

    wire [7:4] cart_bank0;      // driven by the DUT (debug key UART + LED)
    wire dbg_tx;                // same UART line on the FPGA breakout pin

    // cart pin 31 is an inout (the DUT leaves it as an input: debug-key UART RX).
    // An inout cannot take a constant connection in Verilator, so drive it through
    // a net - idle high, no data.
    reg pin31_drv = 1'b1;
    wire cart_pin31_net;
    assign cart_pin31_net = pin31_drv;

    // The pack census is shrunk here: this bench checks protocol, video, audio, keys and the
    // boot-check handshake, and a full 1,048,576-word sweep costs ~135 ms of simulation
    // before rom_ready - longer than this bench is willing to wait. The bitstream uses the
    // default (the whole pack); scripts/sim_rom.sh is where the mechanism itself is verified.
    core_top #(.CENSUS_RANGE(22'h000800)) u_core (
        .clk_74a              ( clk_74a          ),
        .clk_74b              ( clk_74b          ),

        .cart_tran_bank2      (                  ),  // DUT tristates all of these
        .cart_tran_bank2_dir  (                  ),
        .cart_tran_bank3      (                  ),
        .cart_tran_bank3_dir  (                  ),
        .cart_tran_bank1      (                  ),
        .cart_tran_bank1_dir  (                  ),
        .cart_tran_bank0      ( cart_bank0       ),
        .cart_tran_bank0_dir  (                  ),
        .cart_tran_pin30      (                  ),
        .cart_tran_pin30_dir  (                  ),
        .cart_pin30_pwroff_reset (               ),
        .cart_tran_pin31      ( cart_pin31_net   ),  // debug-key UART RX: idle high
        .cart_tran_pin31_dir  (                  ),

        .port_ir_rx           ( 1'b0             ),
        .port_ir_tx           (                  ),
        .port_ir_rx_disable   (                  ),

        .port_tran_si         (                  ),
        .port_tran_si_dir     (                  ),
        .port_tran_so         (                  ),
        .port_tran_so_dir     (                  ),
        .port_tran_sck        (                  ),
        .port_tran_sck_dir    (                  ),
        .port_tran_sd         (                  ),
        .port_tran_sd_dir     (                  ),

        .cram0_a              ( cram0_a          ),
        .cram0_dq             ( cram0_dq         ),
        .cram0_wait           ( 1'b1             ),  // not functional on the fitted part
        .cram0_clk            (                  ),
        .cram0_adv_n          ( cram0_adv_n      ),
        .cram0_cre            ( cram0_cre        ),
        .cram0_ce0_n          ( cram0_ce0_n      ),
        .cram0_ce1_n          ( cram0_ce1_n      ),
        .cram0_oe_n           ( cram0_oe_n       ),
        .cram0_we_n           ( cram0_we_n       ),
        .cram0_ub_n           ( cram0_ub_n       ),
        .cram0_lb_n           ( cram0_lb_n       ),

        .cram1_a              (                  ),  // unused chip: DUT parks it
        .cram1_dq             (                  ),
        .cram1_wait           ( 1'b1             ),
        .cram1_clk            (                  ),
        .cram1_adv_n          (                  ),
        .cram1_cre            (                  ),
        .cram1_ce0_n          (                  ),
        .cram1_ce1_n          (                  ),
        .cram1_oe_n           (                  ),
        .cram1_we_n           (                  ),
        .cram1_ub_n           (                  ),
        .cram1_lb_n           (                  ),

        .dram_a               (                  ),
        .dram_ba              (                  ),
        .dram_dq              (                  ),
        .dram_dqm             (                  ),
        .dram_clk             (                  ),
        .dram_cke             (                  ),
        .dram_ras_n           (                  ),
        .dram_cas_n           (                  ),
        .dram_we_n            (                  ),

        .sram_a               (                  ),
        .sram_dq              (                  ),
        .sram_oe_n            (                  ),
        .sram_we_n            (                  ),
        .sram_ub_n            (                  ),
        .sram_lb_n            (                  ),

        .vblank               ( 1'b0             ),

        .dbg_tx               ( dbg_tx           ),
        .dbg_rx               ( 1'b0             ),

        .user1                (                  ),
        .user2                ( 1'b0             ),

        .aux_sda              (                  ),
        .aux_scl              (                  ),
        .vpll_feed            (                  ),

        .video_rgb            ( video_rgb        ),
        .video_rgb_clock      ( video_rgb_clock  ),
        .video_rgb_clock_90   ( video_rgb_clock_90 ),
        .video_de             ( video_de         ),
        .video_skip           ( video_skip       ),
        .video_vs             ( video_vs         ),
        .video_hs             ( video_hs         ),

        .audio_mclk           ( audio_mclk       ),
        .audio_adc            ( 1'b0             ),
        .audio_dac            ( audio_dac        ),
        .audio_lrck           ( audio_lrck       ),

        .bridge_endian_little ( bridge_endian_little ),
        .bridge_addr          ( bridge_addr      ),
        .bridge_rd            ( bridge_rd        ),
        .bridge_rd_data       ( bridge_rd_data   ),
        .bridge_wr            ( bridge_wr        ),
        .bridge_wr_data       ( bridge_wr_data   ),

        .cont1_key            ( 32'h0000_0000    ),
        .cont2_key            ( 32'h0000_0000    ),
        .cont3_key            ( 32'h0000_0000    ),
        .cont4_key            ( 32'h0000_0000    ),
        .cont1_joy            ( 32'h0000_0000    ),
        .cont2_joy            ( 32'h0000_0000    ),
        .cont3_joy            ( 32'h0000_0000    ),
        .cont4_joy            ( 32'h0000_0000    ),
        .cont1_trig           ( 16'h0000         ),
        .cont2_trig           ( 16'h0000         ),
        .cont3_trig           ( 16'h0000         ),
        .cont4_trig           ( 16'h0000         )
    );

    // ---- the chip -------------------------------------------------------------------
    wire [21:16] cram0_a;
    wire [15:0]  cram0_dq;
    wire         cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n,
                 cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n;

    // The model's timebase MUST be the controller's own sequence clock (u_core.clk_psram,
    // the PLL's 92.8125 MHz output), exactly as tb_rom does. A separate oscillator looks
    // equivalent but is not: #12.1212 quantises to 12121 ps while #6.0606x2 to 12122 ps,
    // so the two drift a full relative phase every ~30 ms - and once the controller's
    // read-sample edge lands on a bus-release edge, rd_q latches zzzz (=0) and the boot
    // check reads back zeros. The chip's physical CLK pin is held low by the design;
    // this input is only the simulation timebase.
    aw_psram_model u_chip (
        .clk    ( u_core.clk_psram ),
        .a      ( cram0_a         ),
        .dq     ( cram0_dq        ),
        .adv_n  ( cram0_adv_n     ),
        .cre    ( cram0_cre       ),
        .ce0_n  ( cram0_ce0_n     ),
        .ce1_n  ( cram0_ce1_n     ),
        .oe_n   ( cram0_oe_n      ),
        .we_n   ( cram0_we_n      ),
        .ub_n   ( cram0_ub_n      ),
        .lb_n   ( cram0_lb_n      ),
        .wait_hi(                 )
    );

    // ---- APF protocol monitor on the muxed video, from cycle zero ---------------------
    wire [31:0] vid_errors;
    wire [7:0]  vid_jumps;
    apf_video_check #(.H_ACTIVE(320), .V_ACTIVE(200)) u_vidcheck (
        .clk         ( video_rgb_clock ),
        .rgb         ( video_rgb       ),
        .de          ( video_de        ),
        .skip        ( video_skip      ),
        .vs          ( video_vs        ),
        .hs          ( video_hs        ),
        .errors      ( vid_errors      ),
        .phase_jumps ( vid_jumps       )
    );

    // ---- verdict ----------------------------------------------------------------------
    integer errors = 0;
    // This toolchain (5.020) cannot lower a string argument to a fixed-width vector
    // input; a true SV string works with both literals and $sformatf.
    task check(input string name, input cond);
        begin
            if (!cond) begin
                $display("tb_top: FAIL %s", name);
                errors = errors + 1;
            end else begin
                $display("tb_top: ok   %s", name);
            end
        end
    endtask

    // ---- bridge helpers (the host side) -------------------------------------------------
    // Nonblocking on negedge: aw_rom and core_bridge_cmd sample bridge_wr/bridge_rd on
    // posedge clk_74a, so the stimulus must be settled BEFORE that edge. Driving them
    // with blocking assignments in the same posedge is a race - which process wins the
    // edge decides whether the DUT sees the write at all (tb_rom uses this pattern).
    task bridge_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk_74a);
            bridge_wr      <= 1'b1;
            bridge_addr    <= a;
            bridge_wr_data <= d;
            @(negedge clk_74a);
            bridge_wr      <= 1'b0;
            bridge_addr    <= 32'h0;
            bridge_wr_data <= 32'h0;
        end
    endtask

    // A data-slot write, where d is little-endian (the byte belonging at address a is
    // d[7:0]). The APF wire carries that byte at [31:24] for a core declaring
    // bridge_endian_little = 0 - the mapping data_loader.sv in analogue-pocket-utils is
    // tested with, and the one 1035a measured on hardware. Host COMMANDS at 0xF8000000
    // keep their own convention (core_bridge_cmd applies the same rule to both of its
    // ports), so bridge_write above stays unsalted and only the data path swaps.
    task slot_write32(input [31:0] a, input [31:0] d);
        begin
            bridge_write(a, {d[7:0], d[15:8], d[23:16], d[31:24]});
        end
    endtask

    task bridge_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk_74a);
            bridge_addr <= a;
            bridge_rd   <= 1'b1;
            @(negedge clk_74a);
            // bridge_rd_data is a combinational mux on bridge_addr in core_top, so sample
            // it while the address still sits on the bus - that is also how the host uses it
            d           = bridge_rd_data;
            bridge_rd   <= 1'b0;
            bridge_addr <= 32'h0;
        end
    endtask

    // ---- video observation (pixel clock domain) -----------------------------------------
    localparam integer FRAME_CYCLES = 825 * 500;

    reg [31:0] pix_cnt = 0;
    reg [31:0] vs_at [0:255];
    integer    vs_n = 0;
    reg        saw_black = 1'b0, saw_white = 1'b0, saw_red = 1'b0;
    reg [23:0] bad_colour = 0;
    reg        bad_seen = 1'b0;

    always @(posedge video_rgb_clock) begin
        pix_cnt <= pix_cnt + 1;
        if (video_vs && vs_n < 256) begin
            vs_at[vs_n] <= pix_cnt;
            vs_n        <= vs_n + 1;
        end
        if (video_de && !u_core.rom_ready) begin
            // idle screen palette: black, the white blink, and the red trailer-error
            // grid that the ~85 ms retry check paints once it has sampled an empty or
            // partial pack (background 280000, grid floor 180000, unlit cell 501010).
            // Anything else is a different error state: purple c010c0 = FIFO overflow,
            // amber c08010 = the unreachable WAIT report.
            case (video_rgb)
                24'h000000: saw_black <= 1'b1;
                24'hffffff: saw_white <= 1'b1;
                24'h280000, 24'h180000, 24'h501010: saw_red <= 1'b1;
                default: begin bad_colour <= video_rgb; bad_seen <= 1'b1; end
            endcase
        end
    end

    // ---- audio observation ------------------------------------------------------------------
    // One 10 ms window (742,500 cycles of clk_74a), opened four frames in: MCLK must then
    // count 122,880 edges and LRCK 480 rising edges, exactly.
    reg [31:0] mclk_edges = 0, lrck_rise = 0;
    reg        mclk_prev = 0, lrck_prev = 0;
    reg        in_window = 1'b0;
    reg [29:0] win_cnt = 0;
    reg        dac_dirty = 1'b0;
    reg [31:0] mclk_result = 0, lrck_result = 0;

    always @(posedge clk_74a) begin
        if (audio_mclk && !mclk_prev) mclk_edges <= in_window ? mclk_edges + 1 : mclk_edges;
        mclk_prev <= audio_mclk;
        if (audio_lrck && !lrck_prev) lrck_rise  <= in_window ? lrck_rise + 1 : lrck_rise;
        lrck_prev <= audio_lrck;
        if (audio_dac !== 1'b0) dac_dirty <= 1'b1;

        if (!in_window && win_cnt == 0 && pix_cnt > FRAME_CYCLES * 4) begin
            in_window  <= 1'b1;
            mclk_edges <= 0;
            lrck_rise  <= 0;
        end else if (in_window) begin
            win_cnt <= win_cnt + 1;
            if (win_cnt == 742500 - 1) begin
                in_window   <= 1'b0;
                mclk_result <= mclk_edges;
                lrck_result <= lrck_rise;
            end
        end
    end

    // ---- debug-key UART line ----------------------------------------------------------------
    // The console legitimately transmits at boot ("AW core up") and on every failed
    // retry check (~85 ms apart, "ROM ERR: bad trailer"), so the line is NOT idle all
    // the time. What must never happen is a hung transmitter: the longest message is
    // 25 bytes = 2.17 ms at 115200, so more than 3 ms low is a fault.
    reg [16:0] uart_low_run = 17'd0;
    reg        uart_stuck   = 1'b0;
    always @(posedge video_rgb_clock) begin
        if (cart_bank0[6] === 1'b0) begin
            if (uart_low_run < 17'd74250) uart_low_run <= uart_low_run + 17'd1;
            else                          uart_stuck   <= 1'b1;
        end else begin
            uart_low_run <= 17'd0;
        end
    end

    // ---- sequence -----------------------------------------------------------------------------
    initial begin
        $display("tb_top: power on; idle screen phase (protocol + colours)");

        // Phase A: ~0.85 s of sim time - long enough to cross the first white-blink edge
        // (bit 24 of a 25-bit counter at 24.75 MHz goes high after 2^24 cycles = 0.678 s)
        repeat (63_000_000) @(posedge clk_74a);

        check("idle: black seen", saw_black);
        check("idle: white blink seen", saw_white);
        check("idle: red trailer-error screen appeared (retry checks ran)", saw_red);
        if (bad_seen) begin
            $display("tb_top: FAIL idle screen showed colour %06h (overflow/wait state?)", bad_colour);
            errors = errors + 1;
        end else begin
            $display("tb_top: ok   idle screen stays within its palette");
        end

        check("idle: UART TX never sticks low (console traffic allowed)", !uart_stuck);
        // no phase jump can have happened yet: the mux cannot switch before rom_ready
        check("idle: video protocol clean so far", vid_errors == 0 && vid_jumps == 0);

        // Phase B: the host loads a pack while the core is still held in reset - the real
        // boot order (the OS streams with loadf before Reset Exit). Four trailer words at
        // pack offset 0x1FFFE0: offsets {0, 8192, 4096, 16384} satisfy the trailer check.
        check("host: status_boot_done", u_core.status_boot_done);

        // settle on a quiet UART: the retry checks fire every ~85 ms and their error
        // line takes ~1.9 ms, so wait (bounded) for TX to be truly idle before we start
        // writing - keeps this phase deterministic
        begin : uart_settle
            integer i;
            reg idle = 1'b0;
            for (i = 0; i < 742_500 && !idle; i = i + 1) begin   // up to 10 ms
                @(posedge clk_74a);
                idle = (cart_bank0[6] === 1'b1) && (cart_bank0[5] === 1'b0);
            end
            check("UART idle before pack write (no console traffic pending)", idle);
        end

        slot_write32(32'h101FFFE0, 32'h0000_0000);   // off0 = 0
        repeat (10) @(posedge clk_74a);
        slot_write32(32'h101FFFE4, 32'h0000_2000);   // off1 = 8192
        repeat (10) @(posedge clk_74a);
        slot_write32(32'h101FFFE8, 32'h0000_1000);   // off2 = 4096
        repeat (10) @(posedge clk_74a);
        slot_write32(32'h101FFFEc, 32'h0000_4000);   // off3 = 16384

        $display("tb_top: trailer written; waiting for the quiet timer + boot check");
        // ... AND the framework's own completion command, which this bench never sent.
        //
        // 0x008F "Data slot access all complete" is what sets dataslot_allcomplete, and it is the only
        // statement the framework makes about the end of an upload. This bench used to omit it and
        // still booted, because the sweep armed on "trailer region written + quiet" instead - which is
        // the same moment only while a pack is one 2 MiB file whose trailer really is the last sixteen
        // bytes. A combined image is 2.94 MiB with its trailer two thirds of the way in, and on
        // hardware that difference is a black screen: aw_rom armed a 2-million-word census mid-upload,
        // the census took the PSRAM from the loader, and the console printed C2 (ERR_OVERFLOW) with
        // Y00000000 - not one byte reaching the VM. A 754 KiB paged image plays on the same bitstream
        // because it never writes a trailer at all and can only be armed by this command.
        //
        // So the bench now drives the signal the field path drives. Without it, a design that waits for
        // the framework looks broken here and a design that guesses looks fine, which is exactly
        // backwards.
        bridge_write(32'hF800_0000, 32'h434D_008F);   // "CM" + command 0x008F
        repeat (10) @(posedge clk_74a);
        begin : wait_ready
            integer i;
            reg ready = 1'b0;
            for (i = 0; i < 2_000_000 && !ready; i = i + 1) begin
                @(posedge clk_74a);
                ready = u_core.rom_ready;
            end
            check("pack: rom_ready rose (trailer check passed)", ready);
            if (!ready) begin
                // where the load actually got to: how many writes matched the window,
                // where the last one landed, whether the FIFO overflowed, and what the
                // trailer readback saw - plus the load path's own state: resets, the
                // drain state machine, the load FIFO pointers (write side vs read side),
                // and the PSRAM controller state
                $display("tb_top: DEBUG t=%0t rom_error=%0b wr_match=%08h last_match=%05h ovf=%b allc=%b chk_data=%032h",
                         $time, u_core.rom_error, u_core.u_rom.dbg_wr_match,
                         u_core.u_rom.dbg_last_match, u_core.u_rom.seen_overflow,
                         u_core.u_rom.dbg_allc_seen, u_core.u_rom.chk_data);
                $display("tb_top: DEBUG rst_bridge=%b rst_psram=%b drain_state=%0d ld_empty=%b fifo_wptr=%0d fifo_rptr=%0d psram_ctrl_state=%0d",
                         u_core.rst_bridge, u_core.u_rom.rst_psram,
                         u_core.u_rom.d_state, u_core.u_rom.ld_empty,
                         u_core.u_rom.u_ldfifo.wptr_bin, u_core.u_rom.u_ldfifo.rptr_bin,
                         u_core.u_rom.u_psram.state);
            end
        end

        // Phase C: Reset Exit, then the game clock takes over the mux
        bridge_write(32'hF800_0000, {16'h434D, 16'h0011});   // host command: Reset Exit
        repeat (100) @(posedge clk_74a);
        check("host: design_run after Reset Exit", u_core.design_run);

        // let a handful of game frames cross the mux switch
        repeat (FRAME_CYCLES * 8) @(posedge video_rgb_clock);

        // At most one abnormal frame is expected: the transition frame straddling the
        // mux switch, whose line count is set by the raster phase offset. If that offset
        // happens to land on a clean boundary the transition frame is perfectly regular
        // and zero jumps is equally correct; more than one is always a bug.
        check($sformatf("video: protocol clean across the mux switch (%0d phase-jump frame(s))", vid_jumps),
              vid_errors == 0 && vid_jumps <= 1);

        // Frame boundaries: exactly one vs every 825x500 pixels, with ONE exception -
        // the mux switch jumps from the idle raster's phase to the game raster's, so
        // the boundary straddling it is 412500 plus the (unknown) phase difference and
        // must only stay inside (0, 2*FRAME_CYCLES). Any other irregularity means a
        // lost or doubled frame.
        begin : vs_period
            integer i, bad = 0;
            reg jump_seen = 1'b0;
            for (i = 1; i < vs_n && i <= 256; i = i + 1) begin
                if (vs_at[i] - vs_at[i-1] != FRAME_CYCLES) begin
                    if (jump_seen || vs_at[i] - vs_at[i-1] >= FRAME_CYCLES * 2)
                        bad = bad + 1;
                    else begin
                        jump_seen = 1'b1;
                        $display("tb_top:      mux-switch phase jump = %0d cycles", vs_at[i] - vs_at[i-1]);
                    end
                end
            end
            check($sformatf("video: %0d frame boundaries, at most one phase jump (the mux switch)", vs_n - 1),
                  vs_n >= 8 && bad == 0);
            if (bad != 0) $display("tb_top:      (%0d wrong deltas)", bad);
        end

        // host command round trip: Request Status must read back OK + idle (see header)
        begin : status
            reg [31:0] r;
            bridge_write(32'hF800_0000, {16'h434D, 16'h0000});
            repeat (50) @(posedge clk_74a);
            bridge_read(32'hF800_0000, r);
            check("host: status reads back {0x4F4B, idle}", r == 32'h4F4B_0003);
            if (r != 32'h4F4B_0003) $display("tb_top:      got %h", r);
        end

        // Phase D: audio. The window closes at win_cnt == 742500, which lands during or
        // shortly after the waits above; poll for the latched result.
        begin : audio_wait
            integer i;
            for (i = 0; i < 1_000_000 && mclk_result == 0; i = i + 1)
                @(posedge clk_74a);
        end
        check($sformatf("audio: MCLK = %0d edges in 10 ms (want 122880)", mclk_result),
               mclk_result >= 122875 && mclk_result <= 122885);
        check($sformatf("audio: LRCK = %0d rises in 10 ms (want 480)", lrck_result),
               lrck_result >= 478 && lrck_result <= 482);
        check("audio: DAC silent for the whole run", !dac_dirty);

        // ---- verdict ------------------------------------------------------------------
        if (errors == 0) begin
            $display("tb_top: all checks passed -> PASS");
            $finish;
        end else begin
            $fflush;
            $fatal(1, "tb_top: %0d error(s) -> FAIL", errors);
        end
    end

    // Watchdog: nothing here should take more than ~2 s of sim time. Delay literals
    // are in the timescale's first unit (ns here), so 2.5 s is 2_500_000_000 - which
    // also fits a 32-bit unsized literal, unlike the ps-converted value.
    initial begin
        #2_500_000_000;   // 2.5 s in ns
        $display("tb_top: HUNG - no verdict after 2.5 s of sim time");
        $fflush;
        $fatal(1, "tb_top: watchdog");
    end

endmodule

`default_nettype wire
