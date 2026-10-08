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
    always#10.10101 clk_psram  = ~clk_psram;   // 49.500 MHz
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
    aw_rom u_rom (
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

    task automatic wr32(input [31:0] a, input [31:0] d);
        begin
            // WR high for exactly one cycle, then pace cycles of quiet. Leaving WR high
            // while waiting offers the same word again every cycle - at pace=10 that is ten
            // times the intended traffic, and the design answers by (correctly) reporting
            // that the bridge has overrun the memory.
            @(negedge clk_bridge);
            dataslot_wr    <= 1'b1;
            dataslot_addr  <= a;
            dataslot_wdata <= d;
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
            if (nseen >= MIN_COLOURS && nonzero > 0) rich_frames = rich_frames + 1;
            if (nseen > max_colours) max_colours = nseen;
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
        if (mem_data_available) begin
            bytes_to_vm = bytes_to_vm + 1;
            // Every byte handed to the VM, checked against the image. When the game draws
            // nothing this is what tells you whether the ROM lied or the VM asked for
            // something strange: 'the byte was wrong' and 'the address was wrong' look
            // identical from a black screen.
            if (served_k >= 0 && (stream_base + served_k) < PACK_BYTES) begin
                if (mem_data !== ref_mem[stream_base + served_k]) begin
                    errors = errors + 1;
                    if (errors < 25)
                        $display("  ROM GAVE WRONG BYTE addr=%0h got=%02h image=%02h (k=%0d)",
                                 stream_base + served_k, mem_data,
                                 ref_mem[stream_base + served_k], served_k);
                end
            end
            served_k = served_k + 1;
        end
        if (mem_in_ready && !served_prev) begin
            stream_base = mem_addr;           // acceptance: this is where the run starts
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
        end
        served_prev = mem_data_available;
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
        if (!$value$plusargs("FRAMEDIR=%s", framedir)) framedir = "/tmp/awframes";

        // Probe sanity check. Everything the diagnosis below rests on is a hierarchical read
        // of a memory inside the generated design; if that read is not looking at the array
        // being written, every conclusion drawn from it is worthless. So write a sentinel and
        // read it back before anything else happens.
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

        // A run that produced only black frames is not a pass, whatever else went right.
        // s1_pass is what decides the process exit status (see the end of this initial block):
        // until now the verdict was print-only, so a failing design still exited 0 and
        // `make sim-soc` reported success. Proven by fault injection, see the commit note.
        if (frames < 4) begin
            $display("tb_soc: FAIL - only %0d frames; the video never framed anything", frames);
            s1_pass = 0;
        end else if (rich_frames == 0) begin
            $display("tb_soc: FAIL - %0d frames, no rich frame (best %0d colours, %0d non-black, %0d bytes to the VM); a uniform fill is not a rendering",
                     frames, max_colours, frames - black_frames, bytes_to_vm);
            s1_pass = 0;
        end else if (black_frames == frames) begin
            $display("tb_soc: FAIL - %0d frames, every one of them black (%0d bytes reached the VM)",
                     frames, bytes_to_vm);
            s1_pass = 0;
        end else if (errors != 0) begin
            $display("tb_soc: FAIL - %0d errors", errors);
            s1_pass = 0;
        end else begin
            $display("tb_soc: %0d frames, %0d non-black, %0d rich (best %0d colours), %0d bytes to the VM -> PASS",
                     frames, frames - black_frames, rich_frames, max_colours, bytes_to_vm);
            s1_pass = 1;
        end

        // The palette, byte-exact, as the oracle for colour. vm.si loads a palette with
        //     mem.addr = segPalettes + (paletteId << 5);   // 32 bytes = 16 RGB565 colours
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
