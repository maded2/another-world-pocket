// Does the controller translate a play request into the right mixer command, ONCE?
//
// Three cases, and the third is the one that caught the first version's bug: a command must be issued exactly
// once per request. The original re-issued every cycle after the lookup returned, which would restart the
// sound continuously - a fault that produces sound and is easy to miss by listening.
`timescale 1ns/1ps
module tb_audio_ch;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;

    localparam [23:0] ABASE = 24'h2F0000;

    // index region + payload, built here so the expected values are visible next to the stimulus
    reg  [7:0] mem [0:4095];

    // The index RAM is loaded at boot through a byte port. This responder answers one cycle later - the
    // loader's contract is req/valid, and tb_audio_idx is the bench that exercises a delayed responder;
    // this one only needs the index resident so the controller's handshake can be checked.
    wire        ldr_req;
    wire [23:0] ldr_addr;
    reg         ldr_valid = 0;
    reg  [7:0]  ldr_data = 0;
    always @(posedge clk) begin
        ldr_valid <= ldr_req;
        if (ldr_req) ldr_data <= mem[ldr_addr - 24'h001000];
    end
    reg         load_start = 0;
    wire        load_busy, load_done;

    reg         play = 0;
    reg  [15:0] res = 0;
    reg  [5:0]  freq = 0;
    reg  [7:0]  vol = 0;
    reg  [1:0]  ch = 0;

    wire        idx_start;
    wire [15:0] idx_res;
    wire        idx_busy, idx_found;
    wire [7:0]  idx_type;
    wire [31:0] idx_blob;
    wire [15:0] idx_poff, idx_plen, idx_ls, idx_ll;

    wire        cmd_valid;
    wire [1:0]  cmd_ch;
    wire [5:0]  cmd_freq;
    wire [7:0]  cmd_vol;
    wire [23:0] cmd_len, cmd_lp, cmd_ll, cmd_base;

    aw_audio_idx u_idx(.clk(clk), .rst(rst),
                       .load_start(load_start), .load_busy(load_busy), .load_done(load_done),
                       .ldr_addr(ldr_addr), .ldr_req(ldr_req), .ldr_valid(ldr_valid), .ldr_data(ldr_data),
                       .start(idx_start), .res_id(idx_res),
                       .busy(idx_busy), .found(idx_found), .r_type(idx_type), .r_blob_off(idx_blob),
                       .r_pcm_off(idx_poff), .r_pcm_len(idx_plen),
                       .r_loop_start(idx_ls), .r_loop_len(idx_ll));

    aw_audio_ch #(.AUDIO_BASE(ABASE)) u_ch(.clk(clk), .rst(rst), .play(play), .res(res),
                       .freq(freq), .vol(vol), .ch(ch),
                       .idx_start(idx_start), .idx_res(idx_res), .idx_busy(idx_busy), .idx_found(idx_found),
                       .idx_type(idx_type), .idx_blob(idx_blob), .idx_poff(idx_poff),
                       .idx_plen(idx_plen), .idx_ls(idx_ls), .idx_ll(idx_ll),
                       .cmd_valid(cmd_valid), .cmd_ch(cmd_ch), .cmd_freq(cmd_freq), .cmd_vol(cmd_vol),
                       .cmd_len(cmd_len), .cmd_lp(cmd_lp), .cmd_ll(cmd_ll), .cmd_base(cmd_base));

    integer i, k, pulses, errors = 0, checked = 0;
    reg probe_run = 1'b0;   // flip to 1 to trace the controller/resolver handshake
    reg [7:0] got_vol; reg [23:0] got_base, got_len, got_lp, got_ll; reg [1:0] got_ch; reg [5:0] got_freq;

    task automatic do_play(input [15:0] r, input [5:0] f, input [7:0] v, input [1:0] c);
        begin
            pulses = 0;
            @(negedge clk); play <= 1; res <= r; freq <= f; vol <= v; ch <= c;
            @(negedge clk); play <= 0;
            for (k = 0; k < 3000; k = k + 1) begin
                @(negedge clk);
                if (probe_run && k < 24)
                    $display("   cyc %0d: st=%0d start=%b busy=%b found=%b idx_res=%0d a=%0h",
                             k, u_ch.st, idx_start, idx_busy, idx_found, idx_res, u_idx.a);
                if (cmd_valid) begin
                    pulses = pulses + 1;
                    got_vol = cmd_vol; got_base = cmd_base; got_len = cmd_len;
                    got_lp = cmd_lp; got_ll = cmd_ll; got_ch = cmd_ch; got_freq = cmd_freq;
                end
                if (pulses > 0 && k > 200) k = 3000;   // stop waiting once one has been seen
            end
            repeat (50) @(negedge clk);
        end
    endtask

    task automatic check_cmd(input [7:0] v, input [1:0] c, input [5:0] f,
                          input [23:0] base, input [23:0] len, input [23:0] lp, input [23:0] ll,
                          input [8*32-1:0] what);
        begin
            checked = checked + 1;
            if (pulses != 1) begin
                errors = errors + 1;
                $display("  FAIL %0s: %0d commands issued, want exactly 1", what, pulses);
            end else if (got_vol !== v || got_ch !== c || got_freq !== f || got_base !== base ||
                         got_len !== len || got_lp !== lp || got_ll !== ll) begin
                errors = errors + 1;
                $display("  FAIL %0s: got vol=%0d ch=%0d freq=%0d base=0x%X len=%0d lp=%0d ll=%0d",
                         what, got_vol, got_ch, got_freq, got_base, got_len, got_lp, got_ll);
                $display("       want vol=%0d ch=%0d freq=%0d base=0x%X len=%0d lp=%0d ll=%0d",
                         v, c, f, base, len, lp, ll);
            end
        end
    endtask

    initial begin
        for (i = 0; i < 4096; i = i + 1) mem[i] = 8'd0;
        // index: tag, count=2
        mem[0] = 8'h41; mem[1] = 8'd2;
        // Records are LITTLE-ENDIAN. The first version wrote them with {hi, lo} concatenations, which put the
        // high byte first - so res 8 became 0x0800 and no lookup could ever match. The RTL was right; the
        // stimulus was wrong, and the probe (busy=1, rd walking the record) is what located it.
        // record 0: res 8, sound, blob_off 0, pcm_off 8, pcm_len 0x1234, loop_start 0x10, loop_len 0x20
        mem[4] = 8'd8;   mem[5] = 8'd0;                 // res
        mem[6] = 8'd0;   mem[7] = 8'd0;                 // type, flags
        mem[8] = 8'd0;   mem[9] = 8'd0; mem[10] = 8'd0; mem[11] = 8'd0;   // blob_off
        mem[12] = 8'd8;  mem[13] = 8'd0;                // pcm_off
        mem[14] = 8'h34; mem[15] = 8'h12;               // pcm_len
        mem[16] = 8'h10; mem[17] = 8'd0;                // loop_start
        mem[18] = 8'h20; mem[19] = 8'd0;                // loop_len
        // record 1: res 9, sound, blob_off 0x100, pcm_off 8, pcm_len 0x0100, no loop
        mem[20] = 8'd9;   mem[21] = 8'd0;
        mem[22] = 8'd0;   mem[23] = 8'd0;
        mem[24] = 8'h00;  mem[25] = 8'h01; mem[26] = 8'd0; mem[27] = 8'd0;
        mem[28] = 8'd8;   mem[29] = 8'd0;
        mem[30] = 8'h00;  mem[31] = 8'h01;
        mem[32] = 8'd0;   mem[33] = 8'd0;
        mem[34] = 8'd0;   mem[35] = 8'd0;

        repeat (4) @(posedge clk);
        rst <= 0;
        repeat (2) @(posedge clk);

        // load the index before any play - the controller must never see a lookup against an unloaded RAM
        @(negedge clk); load_start <= 1;
        @(negedge clk); load_start <= 0;
        while (!load_done) @(negedge clk);
        $display("  index loaded (%0d bytes)", 4 + mem[1]*16);

        do_play(16'd8, 6'd20, 8'd45, 2'd1);
        check_cmd(8'd45, 2'd1, 6'd20, ABASE + 24'd8, 24'h1234, 24'h0010, 24'h0020, "play res 8");

        do_play(16'd9, 6'd5, 8'd63, 2'd3);
        check_cmd(8'd63, 2'd3, 6'd5, ABASE + 24'd0 + 24'h100 + 24'd8, 24'h0100, 24'd0, 24'd0, "play res 9");

        do_play(16'd8, 6'd20, 8'd0, 2'd2);
        check_cmd(8'd0, 2'd2, 6'd20, 24'd0, 24'd0, 24'd0, 24'd0, "stop (vol 0)");

        do_play(16'd9999, 6'd7, 8'd30, 2'd0);
        check_cmd(8'd0, 2'd0, 6'd7, 24'd0, 24'd0, 24'd0, 24'd0, "unknown id becomes a stop");

        $display("tb_audio_ch: %0d checks, %0d errors -> %s", checked, errors,
                 (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $stop; else $finish;
    end
endmodule
