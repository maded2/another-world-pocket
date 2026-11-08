// Bench for aw_mixer against scripts/ref_mixer.py.
//
// Both sides read the SAME scenario (samples.hex + cmds.txt) produced by scripts/mixer_scenario.py, so a
// disagreement is a datapath difference rather than two different stimuli. The comparison itself happens in
// scripts/sim_mixer.sh (Python), which also runs the perturbed scenario: if the bench cannot reject a
// one-sample error it is decoration.
`timescale 1ns/1ps

module tb_mixer;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;                  // 25 MHz, near the design's 24.75

    // ---- the byte RAM the mixer reads (registered read, one cycle of latency) ----
    reg  [7:0] ram [0:255];
    reg  [7:0] rd_data_r;
    wire [23:0] rd_addr;

    always @(posedge clk) rd_data_r <= ram[rd_addr[7:0]];

    // ---- command interface ----
    reg        cmd_valid = 0;
    reg [1:0]  cmd_ch = 0;
    reg [5:0]  cmd_freq = 0;
    reg [7:0]  cmd_vol = 0;
    reg [23:0] cmd_len = 0, cmd_loop_pos = 0, cmd_loop_len = 0, cmd_data_base = 0;

    wire signed [7:0] out_sample;
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc < 40) $display("   cyc %0d st=%0d tick=%b cmdv=%b ch0=%b pos0=%0h rd=%0h",
                               cyc, dut.st, tick, cmd_valid, dut.ch_active[0], dut.ch_pos[0], rd_addr);
    end

    reg  tick = 0;                          // declared BEFORE the instantiation: as a forward reference
                                            // this silently became a different net and the mixer never saw
                                            // a tick at all, which read as "the mixer outputs zeros".

    aw_mixer dut (
        .clk(clk), .rst(rst), .tick(tick),
        .out_sample(out_sample),
        .cmd_valid(cmd_valid), .cmd_ch(cmd_ch), .cmd_freq(cmd_freq), .cmd_vol(cmd_vol),
        .cmd_len(cmd_len), .cmd_loop_pos(cmd_loop_pos), .cmd_loop_len(cmd_loop_len),
        .cmd_data_base(cmd_data_base),
        .rd_addr(rd_addr), .rd_data(rd_data_r)
    );

    integer fd, n, t, i;
    integer ct [0:63], cch [0:63], cfq [0:63], cvo [0:63];
    integer cln [0:63], clp [0:63], cll [0:63], cba [0:63];
    integer ncmd = 0;
    integer ctick [0:63];

    initial begin
        // The scenario path is baked in at build time (sim_mixer.sh passes -DSCN_PATH), so both halves
        // read the same directory with no runtime argument to get wrong.
        $readmemh({`SCN_PATH, "/samples.hex"}, ram);

        fd = $fopen({`SCN_PATH, "/cmds.txt"}, "r");
        if (fd == 0) begin $display("tb_mixer: no cmds.txt"); $finish; end
        while (!$feof(fd)) begin
            i = $fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                        ct[ncmd], cch[ncmd], cfq[ncmd], cvo[ncmd],
                        cln[ncmd], clp[ncmd], cll[ncmd], cba[ncmd]);
            if (i == 8) ncmd = ncmd + 1;
        end
        $fclose(fd);

        repeat (4) @(posedge clk);
        rst <= 0;
        repeat (2) @(posedge clk);

        fd = $fopen({`SCN_PATH, "/actual.hex"}, "w");
        for (t = 0; t < `TICKS; t = t + 1) begin
            // commands for this tick, one cycle each
            for (n = 0; n < ncmd; n = n + 1) begin
                if (ct[n] == t) begin
                    @(negedge clk);
                    if (t < 2) $display("   cmd n=%0d tick=%0d ch=%0d freq=%0d vol=%0d len=%0d lp=%0d ll=%0d base=%0d",
                                        n, t, cch[n], cfq[n], cvo[n], cln[n], clp[n], cll[n], cba[n]);
                    cmd_valid <= 1; cmd_ch <= cch[n][1:0]; cmd_freq <= cfq[n][5:0];
                    cmd_vol <= cvo[n][7:0]; cmd_len <= cln[n][23:0];
                    cmd_loop_pos <= clp[n][23:0]; cmd_loop_len <= cll[n][23:0];
                    cmd_data_base <= cba[n][23:0];
                    @(negedge clk);
                    cmd_valid <= 0;
                end
            end
            @(negedge clk); tick <= 1; @(negedge clk); tick <= 0;
            // One cycle before polling: the FSM leaves IDLE on the posedge that sampled tick, and at the
            // negedge where tick is deasserted `st` has not updated yet. Polling there read IDLE at once,
            // returned the stale out_sample, and produced a bench that reported 64 correct-looking zeros.
            @(negedge clk);
            // wait for the sequencer to finish this tick (S_IDLE == 0)
            n = 0;
            while (dut.st !== 4'd0 && n < 200) begin @(negedge clk); n = n + 1; end
            if (n >= 200) begin $display("tb_mixer: TIMEOUT in tick %0d", t); $finish; end
            $fdisplay(fd, "%0d", $signed(out_sample));
            if (t < 3)
                // %0d for pos/inc, NOT %0h: the first version printed hex and I read "38" as decimal
                // thirty-eight when it was 0x38 = 56, i.e. exactly right. A display format has now cost
                // this project a wrong diagnosis three times.
                $display("  tick %0d: act=%b%b%b%b pos0=%0d inc0=%0d vol0=%0d vol1=%0d run=%0d out=%0d",
                         t, dut.ch_active[0], dut.ch_active[1], dut.ch_active[2], dut.ch_active[3],
                         dut.ch_pos[0], dut.ch_inc[0], dut.ch_vol[0], dut.ch_vol[1],
                         dut.running, $signed(out_sample));
        end
        $fclose(fd);
        $display("tb_mixer: wrote %0d ticks", `TICKS);
        $finish;
    end
endmodule
