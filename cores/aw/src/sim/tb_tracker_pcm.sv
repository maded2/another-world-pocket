// Does the tracker's AUDIO match the reference rendering, sample for sample?
//
// tb_music grades the command stream event for event, and tb_mixer grades the mixer bit-exactly
// against ref_mixer.py - but nothing until now has compared the *samples* the tracker produces with
// the ones scripts/ref_tracker.py renders. The two halves composing correctly is an argument; this
// is the measurement, and it is the second half of phase G's acceptance.
//
// How it is kept cheap: the module's first note is ~8.5 s in at its own delay, and reproducing that
// silence in simulation costs 200M cycles. So the scenario overrides the tick delay (the same
// override the music opcode carries), which compresses the timeline without changing a single
// sample - the reference is rendered with the same override. Both sides then start at the first
// NON-ZERO sample, which is the note's onset, so no silent stretch has to line up.
//
// The clock is 24.576 MHz so that 48 kHz divides exactly (512 cycles per sample) and the mixer's
// tick is not a rounded interval - a bench clock that cannot express the sample period would grade
// its own rounding error.
`timescale 1ns/1ps
module tb_tracker_pcm;

    localparam integer CLK_HZ      = 24_576_000;
    localparam integer MS_CYCLES   = CLK_HZ / 1000;      // 24576
    localparam integer SAMP_CYCLES = CLK_HZ / 48000;     // 512 - exact by construction
    localparam [23:0]  AUDIO_BASE  = 24'h2F0000;
    localparam integer NSAMP       = 4000;
`ifdef DELAY_VAL
    localparam integer DELAY       = `DELAY_VAL;         // -DDELAY_VAL=n, for the scaling test
`else
    localparam integer DELAY       = 1000;               // matches the scenario's --delay
`endif
    localparam integer TICKS       = 120;
    localparam integer POS         = 0;

    reg clk = 0, rst = 1;
    always #20.345 clk = ~clk;                            // 40.69 ns = 24.576 MHz

    // ---- memory, served to the tracker and the mixer from one blob ------------------------------
    reg [7:0] blob [0:733211];
    reg [7:0] idxm [0:2047];

    wire [11:0] scan_addr;
    wire [7:0]  scan_q;
    reg  [7:0]  scan_q_r;
    always @(posedge clk) scan_q_r <= idxm[scan_addr[10:0]];
    assign scan_q = scan_q_r;

    // --- tracker commands ---
    wire        mus_cmd_valid, mus_cmd_stop, mus_cmd_touch, mus_cmd_use_inc;
    wire [8:0]  mus_cmd_inc;
    wire [1:0]  mus_cmd_ch;
    wire [7:0]  mus_cmd_vol;
    wire [23:0] mus_cmd_len, mus_cmd_lp, mus_cmd_ll, mus_cmd_base;

    wire        mus_rd_req, mus_rd_valid;
    wire [23:0] mus_rd_addr;
    wire [7:0]  mus_rd_data;

    // --- mixer fetch ---
    wire        mix_rd_req, mix_rd_valid_in;
    wire [23:0] mix_rd_addr;
    wire [7:0]  mix_rd_data_in;
    wire signed [7:0] mix_sample;
    wire        mix_valid;
    wire [31:0] mix_drop_ticks;

    // ONE responder, two clients: the tracker reads only while it loads its module/instruments, the
    // mixer only while it plays, and both hold their request until valid. A mux with the tracker
    // first is therefore enough - no byte can be dropped, because the loser keeps asking.
    // Per-client pending flags, set on that client's RISING edge (the 4-phase handshake's rule: a
    // request must be dropped before the next one, so an edge is exactly one transaction) and
    // cleared when its data is handed back. A shared edge detector on the OR of the two would
    // deadlock the loser: if both ask at once, the loser's rising edge is long gone by the time the
    // winner finishes, and it would wait forever - measured as 13.6M cycles of a held request and no
    // audio at all.
    reg         tp = 0, mp = 0;            // tracker / mixer pending
    reg         tq_d = 0, mq_d = 0;
    reg         ard_owner = 1'b0;          // 1 = tracker
    reg  [2:0]  rund = 0;
    reg         rbusy = 0, rvalid = 0;
    reg  [23:0] rcap = 0;
    reg  [7:0]  rdata = 0;

    always @(posedge clk) begin
        if (rst) begin
            tp <= 0; mp <= 0; tq_d <= 0; mq_d <= 0;
            rbusy <= 0; rund <= 0; rvalid <= 0;
        end else begin
            rvalid <= 0;
            if (mus_rd_req && !tq_d) tp <= 1'b1;
            if (mix_rd_req && !mq_d) mp <= 1'b1;
            tq_d <= mus_rd_req; mq_d <= mix_rd_req;
            if (!rbusy) begin
                if (tp) begin
                    rcap <= mus_rd_addr; ard_owner <= 1'b1; tp <= 1'b0;
                    rund <= 3'd3; rbusy <= 1'b1;
                end else if (mp) begin
                    rcap <= mix_rd_addr; ard_owner <= 1'b0; mp <= 1'b0;
                    rund <= 3'd3; rbusy <= 1'b1;
                end
            end else if (rund != 0) begin
                rund <= rund - 3'd1;
            end else begin
                rdata <= blob[rcap - AUDIO_BASE];
                rvalid <= 1'b1;
                rbusy <= 1'b0;
            end
        end
    end

    assign mus_rd_valid    = rvalid &  ard_owner;
    assign mix_rd_valid_in = rvalid & ~ard_owner;
    assign mus_rd_data     = rdata;
    assign mix_rd_data_in  = rdata;

    // 48 kHz tick, exactly 512 clocks, and its grid starts when the tracker is told to play.
    // Phase matters: the tracker's row ticks are delay_ms*MS_CYCLES = 98304 cycles = 192 samples,
    // and if the mixer's grid starts at reset while the tracker's starts at `play`, every command
    // can cross a mixer tick boundary and the volume/note change lands one sample early or late.
    // That is exactly what the first comparison showed: 56 differing samples, all in runs of 2-4,
    // all differing by 1, all around tick boundaries.
    reg        run_mix = 0;
    always @(posedge clk) if (play) run_mix <= 1'b1;
    wire       mix_rst = rst | ~run_mix;

    reg [15:0] tick_div = 0;
    reg        tick = 0;
    always @(posedge clk) begin
        if (mix_rst) begin
            tick_div <= 0; tick <= 0;
        end else if (tick_div == SAMP_CYCLES - 1) begin
            tick_div <= 0; tick <= 1;
        end else begin
            tick_div <= tick_div + 1; tick <= 0;
        end
    end

    reg play = 0;
    reg [15:0] num = 7, delay = DELAY;
    reg [7:0]  pos = POS;

    aw_music #(.CLK_HZ(CLK_HZ), .MS_CYCLES(MS_CYCLES)) u_music (
        .clk(clk), .rst(rst), .audio_base(AUDIO_BASE),
        .play(play), .num(num), .delay(delay), .pos(pos),
        .scan_addr(scan_addr), .scan_q(scan_q),
        .rd_addr(mus_rd_addr), .rd_req(mus_rd_req), .rd_valid(mus_rd_valid), .rd_data(mus_rd_data),
        .cmd_valid(mus_cmd_valid), .cmd_stop(mus_cmd_stop), .cmd_touch(mus_cmd_touch),
        .cmd_use_inc(mus_cmd_use_inc), .cmd_inc(mus_cmd_inc), .cmd_ch(mus_cmd_ch),
        .cmd_vol(mus_cmd_vol), .cmd_len(mus_cmd_len), .cmd_lp(mus_cmd_lp), .cmd_ll(mus_cmd_ll),
        .cmd_base(mus_cmd_base),
        .row_valid(), .state_o(), .marker_valid(), .marker_value(), .marker_ch(), .running());

    aw_mixer u_mixer (
        .clk(clk), .rst(mix_rst), .tick(tick),
        .out_sample(mix_sample), .out_valid(mix_valid), .drop_ticks(mix_drop_ticks),
        .cmd_valid(mus_cmd_valid), .cmd_stop(mus_cmd_stop), .cmd_touch(mus_cmd_touch),
        .cmd_use_inc(mus_cmd_use_inc), .cmd_inc(mus_cmd_inc), .cmd_ch(mus_cmd_ch),
        .cmd_freq(6'd0), .cmd_vol(mus_cmd_vol),
        .cmd_len(mus_cmd_len), .cmd_loop_pos(mus_cmd_lp), .cmd_loop_len(mus_cmd_ll),
        .cmd_data_base(mus_cmd_base),
        .rd_addr(mix_rd_addr), .rd_req(mix_rd_req),
        .rd_valid(mix_rd_valid_in), .rd_data(mix_rd_data_in)
    );

    // ---- capture: from the first non-zero sample, NSAMP samples --------------------------------
    integer cap [0:NSAMP-1];
    integer ncap = 0;
    reg     started = 0;
    integer fd, i, nref, got, rv;
    integer refs [0:NSAMP-1];
    integer bad = 0, firstbad = -1;
    integer best_off = 0, best_bad = 0;
    integer ndrop = 0;
    integer ncmd = 0, nrow = 0, nvalid = 0;
    always @(posedge clk) begin
        if (!rst && mus_cmd_valid) ncmd = ncmd + 1;
        if (!rst && mus_rd_req)    nrow = nrow + 1;
        if (!rst && mix_valid)     nvalid = nvalid + 1;
    end

    always @(posedge clk) begin
        if (!rst && mix_valid) begin
            if (!started && mix_sample != 0) started <= 1;
            if ((started || mix_sample != 0) && ncap < NSAMP) begin
                cap[ncap] = mix_sample;
                ncap = ncap + 1;
            end
            if (mix_drop_ticks != 0) ndrop = mix_drop_ticks;
        end
    end

    initial begin
        $readmemh({`SCN_PATH, "/blob.hex"}, blob);
        $readmemh({`SCN_PATH, "/idx.hex"}, idxm);

        fd = $fopen({`SCN_PATH, "/ref-pcm.txt"}, "r");
        if (fd == 0) begin
            $display("tb_tracker_pcm: no ref-pcm.txt - generate the scenario with --pcm");
            $finish;
        end
        nref = 0;
        while (!$feof(fd) && nref < NSAMP) begin
            got = $fscanf(fd, "%d\n", rv);
            if (got == 1) begin refs[nref] = rv; nref = nref + 1; end
        end
        $fclose(fd);

        repeat (10) @(posedge clk);
        rst <= 0;
        repeat (10) @(posedge clk);
        @(negedge clk); play <= 1;
        @(negedge clk); play <= 0;

        // enough simulated time for DELAY*TICKS milliseconds plus the window, bounded
        i = 0;
        while (ncap < NSAMP && i < 20_000_000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (5) @(posedge clk);

        // Compare, and also report the best sample offset. A tracker whose volume/note commands land
        // a sample later than the reference's tick boundary shows up as a handful of +-1 diffs around
        // every change; if shifting by k makes it exact, the difference is COMMAND LATENCY (a fixed
        // number of samples), not arithmetic, and that is a different claim to make.
        for (i = 0; i < nref && i < ncap; i = i + 1)
            if (refs[i] !== cap[i]) begin
                bad = bad + 1;
                if (firstbad < 0) firstbad = i;
            end
        best_off = 0; best_bad = bad;
        for (got = -3; got <= 3; got = got + 1) begin
            integer k, nb;
            nb = 0;
            for (k = 0; k < NSAMP - 8; k = k + 1)
                if (refs[k + got + 4] !== cap[k]) nb = nb + 1;
            if (nb < best_bad) begin best_bad = nb; best_off = got; end
        end
        $display("  offset search: best shift %0d sample(s) gives %0d differences", best_off, best_bad);

        $display("tb_tracker_pcm: %0d samples captured, %0d reference, %0d differ (first at %0d), dropped ticks %0d",
                 ncap, nref, bad, firstbad, ndrop);
        $display("  diagnostics: %0d tracker commands, %0d tracker byte requests, %0d mixer valids",
                 ncmd, nrow, nvalid);
        if (firstbad >= 0) begin
            $display("  first difference: rtl %0d vs reference %0d (index %0d)",
                     cap[firstbad], refs[firstbad], firstbad);
            // the shape matters: isolated single samples on a period say "one tick's volume/position
            // is applied a sample early"; a run says "the waveform diverges from here"
            // every differing index, so the shape can be read: a cluster at a tick boundary is a
            // command-timing question, a spread is arithmetic
            $write("    differing indices:");
            got = 0;
            for (i = 0; i < nref && i < ncap; i = i + 1)
                if (refs[i] !== cap[i]) begin
                    $write(" %0d", i);
                    got = got + 1;
                end
            $display;
        end
        if (ncap < NSAMP || nref < NSAMP) begin
            $display("tb_tracker_pcm: FAIL - captured %0d of %0d, reference %0d", ncap, NSAMP, nref);
        end else if (bad != 0) begin
            $display("tb_tracker_pcm: FAIL - %0d of %0d samples differ from the reference rendering", bad, NSAMP);
        end else begin
            $display("tb_tracker_pcm: PASS - %0d samples match the reference rendering exactly", NSAMP);
        end
        $finish;
    end
endmodule
