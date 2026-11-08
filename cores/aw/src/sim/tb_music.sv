// Does aw_music issue exactly the commands the original player issues, and at the right tempo?
//
// The oracle is scripts/ref_tracker.py (a transcription of sfxplayer.cpp); scripts/music_scenario.py turns
// its event stream into a fixed-width expectation table plus the blob and index bytes this bench serves.
//
// The comparison is COMMAND FOR COMMAND, in order, including the volume-only commands - those are the ones a
// "make it play something" implementation drops, and they are 580 of the 1191 events in this module. The tick
// period is checked separately, by the wall-clock time of the 65th row (the first row that carries a note):
// a tempo error is the failure mode that sounds "slightly off" rather than broken.
//
// The module is instantiated with a SLOW clock (250 kHz, MS_CYCLES = 250) so a whole 1024-row module runs in
// ~34M cycles. Nothing in the player depends on the clock rate; the tick is derived from the parameter.
`timescale 1ns/1ps
module tb_music;

    localparam integer CLK_HZ = 250_000;
    localparam integer MS_CYCLES = CLK_HZ / 1000;

    reg clk = 0, rst = 1;
    always #2000 clk = ~clk;                     // 4 us = 250 kHz

    localparam [23:0] AUDIO_BASE = 24'h2F0000;

    // ---- memory ----
    reg  [7:0] blob [0:733211];
    reg  [7:0] idxm [0:2047];

    // index RAM read port
    wire [11:0] scan_addr;
    wire [7:0]  scan_q;
    // registered, exactly like aw_audio_idx's own RAM port
    reg  [7:0]  scan_q_r;
    always @(posedge clk) scan_q_r <= idxm[scan_addr[10:0]];
    assign scan_q = scan_q_r;

    // PSRAM byte responder: 3-cycle latency, like the field path (a bench that answers instantly would
    // certify a player that cannot work on hardware)
    reg        rd_req;
    reg  [23:0] rd_addr;
    reg        rd_valid = 0;
    reg  [7:0] rd_data = 0;
    reg  [2:0] rcnt = 0;
    reg        rbusy = 0;
    reg  [23:0] cap = 0;
    reg        req_prev = 0;
    // rd_req is a LEVEL that the caller must drop between transactions (4-phase): a responder that re-arms
    // on the level rather than its rising edge captures the same address twice. That is exactly what the
    // index loader hit, and here it made every header byte a duplicate of the one before it.
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
    wire        cmd_valid, cmd_touch, cmd_use_inc;
    wire [8:0]  cmd_inc;
    wire [1:0]  cmd_ch;
    wire [7:0]  cmd_vol;
    wire [23:0] cmd_len, cmd_lp, cmd_ll, cmd_base;
    wire [5:0]  cmd_freq;
    wire        marker_valid;
    wire [15:0] marker_value;
    wire        running;

    aw_music #(.AUDIO_BASE(AUDIO_BASE), .CLK_HZ(CLK_HZ), .MS_CYCLES(MS_CYCLES)) dut (
        .clk(clk), .rst(rst),
        .play(play), .num(num), .delay(delay), .pos(pos),
        .scan_addr(scan_addr), .scan_q(scan_q),
        .rd_addr(rd_addr), .rd_req(rd_req), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_valid(cmd_valid), .cmd_touch(cmd_touch), .cmd_use_inc(cmd_use_inc), .cmd_inc(cmd_inc),
        .cmd_ch(cmd_ch), .cmd_vol(cmd_vol), .cmd_len(cmd_len), .cmd_lp(cmd_lp), .cmd_ll(cmd_ll),
        .cmd_base(cmd_base), .cmd_freq(cmd_freq),
        .marker_valid(marker_valid), .marker_value(marker_value), .running(running));

    // ---- expectation ----
    integer e_kind [0:2999], e_ch [0:2999], e_f1 [0:2999], e_f2 [0:2999], e_f3 [0:2999];
    integer e_f4 [0:2999], e_f5 [0:2999];
    integer nexp = 0;
    integer ncmd = 0, errors = 0;
    integer first_play_time = -1;
    integer tick_ms = 0, first_play_tick = -1, ticks = 0;
    integer i, fd, got;

    task automatic compare_cmd(input integer kind, input integer ch, input integer f1,
                               input integer f2, input integer f3, input integer f4, input integer f5);
        begin
            if (ncmd >= nexp) begin
                errors = errors + 1;
                $display("  FAIL extra command #%0d: kind=%0d ch=%0d", ncmd, kind, ch);
            end else if (e_kind[ncmd] != kind || e_ch[ncmd] != ch || e_f1[ncmd] != f1 ||
                         e_f2[ncmd] != f2 || e_f3[ncmd] != f3 || e_f4[ncmd] != f4 || e_f5[ncmd] != f5) begin
                errors = errors + 1;
                if (errors < 8) begin
                    $display("  FAIL command #%0d: got kind=%0d ch=%0d inc=%0d len=%0d lp=%0d ll=%0d base=0x%0X",
                             ncmd, kind, ch, f1, f2, f3, f4, f5);
                    $display("                     want kind=%0d ch=%0d inc=%0d len=%0d lp=%0d ll=%0d base=0x%0X",
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
                compare_cmd(cmd_vol == 0 ? 2 : 1, cmd_ch, cmd_use_inc ? cmd_inc : 0,
                            cmd_vol == 0 ? 0 : cmd_len,
                            cmd_vol == 0 ? 0 : cmd_lp,
                            cmd_vol == 0 ? 0 : cmd_ll,
                            cmd_vol == 0 ? 0 : cmd_base);
            else
                compare_cmd(0, cmd_ch, cmd_vol, 0, 0, 0, 0);
            if (cmd_touch && cmd_vol != 0 && first_play_time < 0)
                first_play_time = $time;
            if (ncmd < 14)
                $display("CMD #%0d row ord=%0d pos=%0d: touch=%b ch=%0d vol=%0d use_inc=%b inc=%0d len=%0d lp=%0d ll=%0d base=%06h",
                         ncmd, dut.cur_order, dut.cur_pos, cmd_touch, cmd_ch, cmd_vol, cmd_use_inc,
                         cmd_inc, cmd_len, cmd_lp, cmd_ll, cmd_base);
        end
    end

    // markers are compared as they arrive, interleaved with the commands by tick only
    integer nmark = 0;
    always @(posedge clk) if (marker_valid && !rst) nmark = nmark + 1;

    integer ncmp = 0;
    always @(posedge clk) begin
        if (dut.sc == 4'd6 && ncmp < 4) begin
            $display("  cmp #%0d k=%0d b0=%02h q=%02h target=%04h a=%0d", ncmp, dut.sc_k, dut.sc_b0, scan_q, dut.sc_target, dut.sc_a);
            ncmp = ncmp + 1;
        end
    end
    reg [4:0] mst_d = 5'd31;
    integer ntr = 0;
    always @(posedge clk) begin
        if (dut.mst !== mst_d && ntr < 60) begin
            $display("  tr %0d: mst %0d -> %0d (b_start=%b b_count=%0d b_done=%b b_n=%0d b_dst=%0d)",
                     ntr, mst_d, dut.mst, dut.b_start, dut.b_count, dut.b_done, dut.b_n, dut.b_dst);
            ntr = ntr + 1;
        end
        mst_d <= dut.mst;
    end
    integer mon = 0;
    always @(posedge clk) begin
        mon = mon + 1;
        if (mon % 20000 == 0) begin
            $display("  hdr[0..3]=%02h %02h %02h %02h hdr[60..63]=%02h %02h %02h %02h modbase=%06h",
                     dut.hdr[0], dut.hdr[1], dut.hdr[2], dut.hdr[3],
                     dut.hdr[60], dut.hdr[61], dut.hdr[62], dut.hdr[63], dut.mod_base);
            $display("  [%0t] mst=%0d sc=%0d sc_done=%b | bst=%0d b_done=%b b_n=%0d rdreq=%b | ins=%0d numord=%0d tick=%0d tick_cnt=%0d ord0=%0d hdr63=%0d",
                     $time, dut.mst, dut.sc, dut.sc_done, dut.bst, dut.b_done, dut.b_n, rd_req,
                     dut.ins_i, dut.num_order, dut.tick_cycles, dut.tick_cnt, dut.ord[0], dut.hdr[63]);
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
        tick_ms = 133;          // from --delay 15700: 15700*60/7050 = 133.6 -> 133 (integer division)

        $display("tb_music: module 7, %0d expected commands, %0d ticks, first PLAY at tick %0d, tick %0d ms",
                 nexp, ticks, first_play_tick, tick_ms);

        $display("  probe: idx[0..7]=%02h %02h %02h %02h %02h %02h %02h %02h | rec0 res=%02h%02h rec1 res=%02h%02h rec7 res=%02h%02h",
                 idxm[0], idxm[1], idxm[2], idxm[3], idxm[4], idxm[5], idxm[6], idxm[7],
                 idxm[5], idxm[4], idxm[21], idxm[20], idxm[117], idxm[116]);
        repeat (10) @(posedge clk);
        rst <= 0;
        repeat (10) @(posedge clk);
        @(negedge clk); play <= 1; num <= 16'd7; delay <= 16'd15700; pos <= 8'd0;
        @(negedge clk); play <= 0;

        // run until every expected command has been issued (or the run is clearly stuck)
        i = 0;
        while (ncmd < nexp && i < 200_000_000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (200) @(posedge clk);

        // ---- verdict ----
        if (ncmd != nexp) begin
            errors = errors + 1;
            $display("  FAIL only %0d of %0d expected commands were issued", ncmd, nexp);
        end
        // 64 rows at 133 ms each: the first note must arrive at 64 * 133 ms of simulated time
        if (first_play_time < 0) begin
            errors = errors + 1;
            $display("  FAIL no note was ever played");
        end else begin
            begin : tempo
                integer want, slack;
                want  = first_play_tick * tick_ms * 1000;        // ns
                slack = 3 * tick_ms * 1000;                      // the row's own service time, generously
                $display("  first note at %0d ns (want %0d ns = tick %0d x %0d ms)",
                         first_play_time, want, first_play_tick, tick_ms);
                if (first_play_time < want - 1000 || first_play_time > want + slack) begin
                    errors = errors + 1;
                    $display("  FAIL tempo: first note %0d ns outside [%0d, %0d]", first_play_time,
                             want - 1000, want + slack);
                end
            end
        end

        $display("tb_music: %0d commands compared, %0d markers, %0d errors -> %s",
                 ncmd, nmark, errors, (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $stop; else $finish;
    end

endmodule
