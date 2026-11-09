// Does aw_music issue exactly the commands the original player issues, and at the right tempo?
//
// The oracle is scripts/ref_tracker.py (a transcription of sfxplayer.cpp); scripts/music_scenario.py turns
// its event stream into a fixed-width expectation table plus the blob and index bytes this bench serves.
//
// The comparison is EVENT FOR EVENT, in order: volume-only commands, plays, stops and the 0xFFFD markers
// (which are 580, 580, 3 and 24 of the module's 1191 events respectively). A "make it play something" player
// drops the volume-only ones and the markers; both are load-bearing. The tick period is checked separately,
// by the wall-clock time of the first row that carries a note - a tempo error is the failure that sounds
// "slightly off" rather than broken, so it will not announce itself.
//
// The module is instantiated with a SLOW clock (250 kHz, MS_CYCLES = 250) so a whole 1024-row module runs in
// ~34M cycles. Nothing in the player depends on the clock rate; the tick is derived from the parameter.
`timescale 1ns/1ps
module tb_music;

    localparam integer CLK_HZ = 250_000;
    localparam integer MS_CYCLES = CLK_HZ / 1000;
    localparam [23:0] AUDIO_BASE = 24'h2F0000;

    reg clk = 0, rst = 1;
    always #2000 clk = ~clk;                     // 4 us = 250 kHz

    // ---- memory ----
    reg  [7:0] blob [0:733211];
    reg  [7:0] idxm [0:2047];

    wire [11:0] scan_addr;
    wire [7:0]  scan_q;
    reg  [7:0]  scan_q_r;
    always @(posedge clk) scan_q_r <= idxm[scan_addr[10:0]];
    assign scan_q = scan_q_r;

    // PSRAM byte responder: 3-cycle latency, and rd_req is a LEVEL that the caller must drop between
    // transactions (4-phase), so the capture is on its RISING edge - a responder that re-arms on the level
    // captures the same address twice.
    reg        rd_req;
    reg  [23:0] rd_addr;
    reg        rd_valid = 0;
    reg  [7:0] rd_data = 0;
    reg  [2:0] rcnt = 0;
    reg        rbusy = 0;
    reg  [23:0] cap = 0;
    reg        req_prev = 0;
    wire       req_rise = rd_req && !req_prev;
    always @(posedge clk) begin
        req_prev <= rd_req;
        if (rst) begin
            rbusy <= 1'b0; rcnt <= 3'd0; rd_valid <= 1'b0;
        end else if (!rbusy) begin
            rd_valid <= 1'b0;
            if (req_rise) begin
                cap   <= rd_addr;
                rcnt  <= 3'd3;
                rbusy <= 1'b1;
            end
        end else if (rcnt != 0) begin
            rcnt <= rcnt - 3'd1;
        end else begin
            rd_data  <= blob[cap - AUDIO_BASE];
            rd_valid <= 1'b1;
            rbusy    <= 1'b0;
        end
    end

    // ---- dut ----
    reg         play = 0;
    reg  [15:0] num = 0, delay = 0;
    reg  [7:0]  pos = 0;
    wire        cmd_valid, cmd_touch, cmd_use_inc, cmd_stop;
    wire [8:0]  cmd_inc;
    wire [1:0]  cmd_ch;
    wire [7:0]  cmd_vol;
    wire [23:0] cmd_len, cmd_lp, cmd_ll, cmd_base;
    wire [5:0]  cmd_freq;
    wire        marker_valid;
    wire [15:0] marker_value;
    wire [1:0]  marker_ch;
    wire        running;

    aw_music #(.CLK_HZ(CLK_HZ), .MS_CYCLES(MS_CYCLES)) dut (
        .clk(clk), .rst(rst), .audio_base(AUDIO_BASE),
        .play(play), .num(num), .delay(delay), .pos(pos),
        .scan_addr(scan_addr), .scan_q(scan_q),
        .rd_addr(rd_addr), .rd_req(rd_req), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_valid(cmd_valid), .cmd_stop(cmd_stop), .cmd_touch(cmd_touch), .cmd_use_inc(cmd_use_inc), .cmd_inc(cmd_inc),
        .cmd_ch(cmd_ch), .cmd_vol(cmd_vol), .cmd_len(cmd_len), .cmd_lp(cmd_lp), .cmd_ll(cmd_ll),
        .cmd_base(cmd_base), .cmd_freq(cmd_freq),
        .marker_valid(marker_valid), .marker_value(marker_value), .marker_ch(marker_ch),
        .running(running));

    // ---- expectation ----
    integer e_kind [0:2999], e_ch [0:2999], e_f1 [0:2999], e_f2 [0:2999], e_f3 [0:2999];
    integer e_f4 [0:2999], e_f5 [0:2999];
    integer nexp = 0, ncmd = 0, errors = 0, nmark = 0;
    // 64-bit: $time is in PICOSECONDS here (timescale 1ns/1ps), and 8.5 s does not fit in a 32-bit integer -
    // the first version wrapped and reported the first note at 2.1 "seconds"
    longint first_play_time = -1;
    integer tick_ms = 133, first_play_tick = -1, ticks = 0;
    integer i, fd, got;
    reg compare_en = 1'b1;          // off for the stop-music case, which is not part of the oracle's table

    task automatic compare_cmd(input integer kind, input integer ch, input integer f1,
                               input integer f2, input integer f3, input integer f4, input integer f5);
        begin
            if (!compare_en) begin
                // the stop-music check below is not part of the oracle's event table
            end else if (ncmd >= nexp) begin
                errors = errors + 1;
                if (errors < 8) $display("  FAIL extra event #%0d: kind=%0d ch=%0d", ncmd, kind, ch);
            end else if (e_kind[ncmd] != kind || e_ch[ncmd] != ch || e_f1[ncmd] != f1 ||
                         e_f2[ncmd] != f2 || e_f3[ncmd] != f3 || e_f4[ncmd] != f4 || e_f5[ncmd] != f5) begin
                errors = errors + 1;
                if (errors < 8) begin
                    $display("  FAIL event #%0d: got kind=%0d ch=%0d f1=%0d f2=%0d f3=%0d f4=%0d f5=0x%0X",
                             ncmd, kind, ch, f1, f2, f3, f4, f5);
                    $display("                   want kind=%0d ch=%0d f1=%0d f2=%0d f3=%0d f4=%0d f5=0x%0X",
                             e_kind[ncmd], e_ch[ncmd], e_f1[ncmd], e_f2[ncmd], e_f3[ncmd], e_f4[ncmd], e_f5[ncmd]);
                end
            end
            ncmd = ncmd + 1;
        end
    endtask

    // every mixer command, in the order the player issues it
    always @(posedge clk) begin
        if (cmd_valid && !rst) begin
            if (cmd_touch)
                compare_cmd(cmd_stop ? 2 : 1, cmd_ch, cmd_use_inc ? cmd_inc : 0,
                            cmd_stop ? 0 : cmd_len,
                            cmd_stop ? 0 : cmd_lp,
                            cmd_stop ? 0 : cmd_ll,
                            cmd_stop ? 0 : cmd_base);
            else
                compare_cmd(0, cmd_ch, cmd_vol, 0, 0, 0, 0);
            if (cmd_touch && cmd_vol != 0 && first_play_time < 0)
                first_play_time = $time;
        end
    end

    // markers are part of the stream (0xFFFD writes _scriptVars[0xF4]) and the expectation has them in order
    always @(posedge clk) begin
        if (marker_valid && !rst) begin
            nmark = nmark + 1;
            compare_cmd(3, marker_ch, marker_value, 0, 0, 0, 0);
        end
    end

    initial begin
        $readmemh({`SCN_PATH, "/blob.hex"}, blob);
        $readmemh({`SCN_PATH, "/idx.hex"}, idxm);
        fd = $fopen({`SCN_PATH, "/expect.txt"}, "r");
        if (fd == 0) begin $display("tb_music: no expect.txt"); $finish; end
        while (!$feof(fd)) begin
            got = $fscanf(fd, "%d %d %d %d %d %d %d\n",
                          e_kind[nexp], e_ch[nexp], e_f1[nexp], e_f2[nexp],
                          e_f3[nexp], e_f4[nexp], e_f5[nexp]);
            if (got == 7) nexp = nexp + 1;
        end
        $fclose(fd);
        fd = $fopen({`SCN_PATH, "/info.txt"}, "r");
        got = $fscanf(fd, "res %d\nticks %d\n%d\n", i, ticks, first_play_tick);
        $fclose(fd);
        tick_ms = 133;          // --delay 15700: 15700*60/7050 = 133.6, integer division -> 133

        $display("tb_music: module 7, %0d expected events, %0d ticks, first PLAY at tick %0d, tick %0d ms",
                 nexp, ticks, first_play_tick, tick_ms);

        repeat (10) @(posedge clk);
        rst <= 0;
        repeat (10) @(posedge clk);
        @(negedge clk); play <= 1; num <= 16'd7; delay <= 16'd15700; pos <= 8'd0;
        @(negedge clk); play <= 0;

        i = 0;
        while (ncmd < nexp && i < 40_000_000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (200) @(posedge clk);

        if (ncmd != nexp) begin
            errors = errors + 1;
            $display("  FAIL only %0d of %0d expected events were issued", ncmd, nexp);
        end
        if (first_play_time < 0) begin
            errors = errors + 1;
            $display("  FAIL no note was ever played");
        end else begin
            longint want, slack;
            want  = 1_000_000 * first_play_tick * tick_ms;   // ps, matching $time
            slack = 3_000_000 * tick_ms;                     // three ticks of service time
            $display("  first note at %0d ps (want %0d ps = tick %0d x %0d ms)",
                     first_play_time, want, first_play_tick, tick_ms);
            if (first_play_time < want - 1_000_000 || first_play_time > want + slack) begin
                errors = errors + 1;
                $display("  FAIL tempo: first note %0d ps outside [%0d, %0d]", first_play_time,
                         want - 1_000_000, want + slack);
            end
        end

        // the VM's op_playMusic with num == 0 is STOP MUSIC, and the intro issues it on the frame before the
        // real cue. A tracker that treats it as "load module 0" reads resource 0 (an empty SOUND) as a module
        // header and then ignores the real cue - which is exactly what the first hardware run did: effects
        // played, no music.
        begin : stop_music
            compare_en = 1'b0;
            @(negedge clk); play <= 1; num <= 16'd0; delay <= 16'd0; pos <= 8'd0;
            @(negedge clk); play <= 0;
            i = 0;
            while (dut.running && i < 1000) begin @(posedge clk); i = i + 1; end
            if (dut.running) begin
                errors = errors + 1;
                $display("  FAIL stop-music: the tracker is still running after a num=0 cue");
            end else begin
                $display("  stop-music: num=0 returned the tracker to idle after %0d cycles", i);
            end
            // and a cue after a stop must start it again (the intro does stop-then-play on consecutive frames)
            @(negedge clk); play <= 1; num <= 16'd7; delay <= 16'd15700; pos <= 8'd0;
            @(negedge clk); play <= 0;
            i = 0;
            while (!dut.running && i < 100000) begin
                @(posedge clk); i = i + 1;
                if (i == 20 || i == 2000 || i == 20000)
                    $display("  restart[%0d]: mst=%0d sc=%0d sc_go=%b sc_ack=%b sc_done=%b target=%0d ins=%0d",
                             i, dut.mst, dut.sc, dut.sc_go, dut.sc_ack, dut.sc_done, dut.sc_target, dut.ins_i);
            end
            if (!dut.running) begin
                errors = errors + 1;
                $display("  FAIL restart: a cue after a stop did not start the tracker");
            end else begin
                $display("  restart: a cue after a stop started the tracker in %0d cycles", i);
            end
        end

        $display("tb_music: %0d events compared, %0d markers, %0d errors -> %s",
                 ncmd, nmark, errors, (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $stop; else $finish;
    end

endmodule
