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
    reg design_reset_n = 1'b0;

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
        .vm_running            (design_reset_n),
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

    M_main u_soc (
        .in_mem_data          (mem_data),
        .in_mem_data_available(mem_data_available),
        .in_mem_busy          (mem_busy),
        .in_jstick            (6'b000000),
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
        .reset                (design_reset_n),
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
            $fflush;
        end
    endtask

    // The VM's video is captured on the pixel clock, which here is clk_core.
    // Is the VM asking and not being served? Distinguishes 'the ROM is not answering' from
    // 'the VM stopped asking', which is the first question a black screen poses.
    integer starving = 0;
    always @(posedge clk_core) begin
        if (mem_in_ready && !mem_data_available) starving = starving + 1;
        else if (mem_data_available) starving = 0;
    end

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
        end
        served_prev = mem_data_available;
        if (game_vs) begin
            if (fbp > 0) begin
                dump_frame;
                if (nonzero == 0) black_frames = black_frames + 1;
                frames = frames + 1;
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
        if (!$value$plusargs("FRAMEDIR=%s", framedir)) framedir = "/tmp/awframes";

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
        @(posedge clk_core); design_reset_n = 1;
        $display("tb_soc: VM reset released at t=%0t", $time); $fflush;

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

        // A run that produced only black frames is not a pass, whatever else went right.
        if (frames < 4)
            $display("tb_soc: FAIL - only %0d frames; the video never framed anything", frames);
        else if (black_frames == frames)
            $display("tb_soc: FAIL - %0d frames, every one of them black (%0d bytes reached the VM)",
                     frames, bytes_to_vm);
        else if (errors != 0)
            $display("tb_soc: FAIL - %0d errors", errors);
        else
            $display("tb_soc: %0d frames, %0d non-black, %0d bytes to the VM -> PASS",
                     frames, frames - black_frames, bytes_to_vm);
        $fflush;
        $finish;
    end

    // hard stop, so a hung design reports instead of running forever
    initial begin
        #4_000_000_000;   // 4 s of simulation
        $display("tb_soc: TIMEOUT after %0d frames", frames); $fflush;
        $finish;
    end

endmodule
