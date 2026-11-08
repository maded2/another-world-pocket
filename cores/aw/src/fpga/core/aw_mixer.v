// Another World sound mixer - four channels of 8-bit signed PCM into the Pocket's audio path.
//
// The oracle is scripts/ref_mixer.py, a line-by-line transcription of upstream's Mixer::mix. Every
// arithmetic choice below exists to match it, and the ones that look wrong are noted where they are:
//
//   * chunkPos is 16.8 fixed point: [7:0] the interpolation fraction, [23:8] the sample index.
//   * the interpolated value is ((b1*(255-ilc) + b2*ilc) >> 8) and is then WRAPPED to 8 bits, not
//     clamped - the C code stores it into an int8_t.
//   * volume is (b * vol) / 64 with truncation TOWARD ZERO, i.e. sign-magnitude, not an arithmetic
//     shift on a negative number.
//   * addclamp saturates the running sum to -128..127.
//   * the loop wrap writes the RAW loop position into chunkPos (not << 8), which lands the reader at the
//     start of the sample with a fraction equal to loopPos. Almost certainly a bug in the original; it is
//     copied deliberately, because 11 of the 103 extracted sounds loop and a "fixed" version would not
//     match them.
//   * volume 0 means STOP (vm.cpp: if (vol == 0) mixer->stopChannel(channel)), not a silent play. The
//     harvest measured 16 such events on all four channels inside the first seconds of the intro.
//
// Sample bytes are fetched through a simple byte-wide port, two reads per channel per output sample. At
// 24.75 MHz there are ~515 cycles between 48 kHz ticks, so sequencing eight reads per tick is free. A
// later task points this port at the PSRAM audio region; for now any synchronous RAM works.
`timescale 1ns/1ps

module aw_mixer (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high

    // One-cycle pulse at exactly the output sample rate (48 kHz). Everything below happens inside it.
    input  wire        tick,
    output reg  signed [7:0] out_sample,   // one mixed sample per tick, registered

    // Command: play a sound on a channel, or stop it (vol == 0).
    input  wire        cmd_valid,
    input  wire [1:0]  cmd_ch,
    input  wire [5:0]  cmd_freq,           // index into the rate table, must be < 40
    input  wire [7:0]  cmd_vol,            // 0 = stop; otherwise clamped to 6 bits
    input  wire [23:0] cmd_len,            // playable length in bytes
    input  wire [23:0] cmd_loop_pos,
    input  wire [23:0] cmd_loop_len,       // 0 = play once
    input  wire [23:0] cmd_data_base,      // byte address of sample 0 in the caller's memory

    // Sample fetch: addresses are presented one per cycle, data returns the NEXT cycle.
    output reg  [23:0] rd_addr,
    input  wire [7:0]  rd_data
);

    // ------------------------------------------------------------------ rate table
    // transcribed from staticres.cpp's VirtualMachine::frequenceTable (40 entries, asserted < 40 upstream)
    function automatic [15:0] freq_val(input [5:0] idx);
        case (idx)
            6'd0: freq_val = 16'h0CFF; 6'd1:  freq_val = 16'h0DC3; 6'd2:  freq_val = 16'h0E91;
            6'd3: freq_val = 16'h0F6F; 6'd4:  freq_val = 16'h1056; 6'd5:  freq_val = 16'h114E;
            6'd6: freq_val = 16'h1259; 6'd7:  freq_val = 16'h136C; 6'd8:  freq_val = 16'h149F;
            6'd9: freq_val = 16'h15D9; 6'd10: freq_val = 16'h1726; 6'd11: freq_val = 16'h1888;
            6'd12: freq_val = 16'h19FD; 6'd13: freq_val = 16'h1B86; 6'd14: freq_val = 16'h1D21;
            6'd15: freq_val = 16'h1EDE; 6'd16: freq_val = 16'h20AB; 6'd17: freq_val = 16'h229C;
            6'd18: freq_val = 16'h24B3; 6'd19: freq_val = 16'h26D7; 6'd20: freq_val = 16'h293F;
            6'd21: freq_val = 16'h2BB2; 6'd22: freq_val = 16'h2E4C; 6'd23: freq_val = 16'h3110;
            6'd24: freq_val = 16'h33FB; 6'd25: freq_val = 16'h370D; 6'd26: freq_val = 16'h3A43;
            6'd27: freq_val = 16'h3DDF; 6'd28: freq_val = 16'h4157; 6'd29: freq_val = 16'h4538;
            6'd30: freq_val = 16'h4998; 6'd31: freq_val = 16'h4DAE; 6'd32: freq_val = 16'h5240;
            6'd33: freq_val = 16'h5764; 6'd34: freq_val = 16'h5C9A; 6'd35: freq_val = 16'h61C8;
            6'd36: freq_val = 16'h6793; 6'd37: freq_val = 16'h6E19; 6'd38: freq_val = 16'h7485;
            default: freq_val = 16'h7BBD;      // 6'd39
        endcase
    endfunction

    // chunkInc = (freq << 8) / 48000, exactly as mixer.cpp computes it. freq <= 0x7BBD gives <= 169.
    function automatic [8:0] rate_inc(input [5:0] idx);
        reg [23:0] scaled;
        begin
            scaled = {freq_val(idx), 8'd0};          // freq << 8
            rate_inc = scaled / 24'd48000;
        end
    endfunction

    // ------------------------------------------------------------------ channel state
    reg        ch_active  [0:3];
    reg [23:0] ch_pos     [0:3];      // 16.8
    reg [8:0]  ch_inc     [0:3];
    reg [5:0]  ch_vol     [0:3];
    reg [23:0] ch_len     [0:3];
    reg [23:0] ch_looppos [0:3];
    reg [23:0] ch_looplen [0:3];
    reg [23:0] ch_base    [0:3];

    integer i;
    integer c;

    // ------------------------------------------------------------------ sequencer
    // One tick = 4 channels x (read b1, read b2, accumulate). Two dead cycles between reads absorb the
    // one-cycle memory latency, so the sequence is 4 x 4 = 16 cycles per tick - far below the ~515
    // available, and it keeps the pipeline trivially checkable.
    localparam [3:0] S_IDLE = 4'd0, S_RD1 = 4'd1, S_W1 = 4'd2, S_RD2 = 4'd3,
                     S_W2 = 4'd4, S_CALC = 4'd5, S_NEXT = 4'd6, S_OUT = 4'd7;

    reg [3:0]  st;
    reg [1:0]  cur_ch;
    reg [23:0] p1, p2;
    reg [7:0]  ilc;
    reg [7:0]  b1, b2;
    reg signed [8:0] running;         // the mix accumulator, clamped to int8 on every add
    reg [23:0] next_pos;

    // signed 8-bit multiply-scale with truncation toward zero (C semantics for (b*vol)/64)
    function automatic signed [8:0] scale_vol(input signed [7:0] b, input [5:0] vol);
        reg signed [15:0] mag;
        begin
            if (b >= 0) scale_vol = (b * vol) >> 6;
            else begin
                mag = -b;                                 // magnitude, so >> is a floor on a positive value
                scale_vol = -((mag * vol) >> 6);          // re-apply the sign: truncation toward zero
            end
        end
    endfunction

    function automatic signed [8:0] clamp8(input signed [8:0] v);
        clamp8 = (v > 127) ? 127 : (v < -128) ? -128 : v;
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            out_sample <= 8'sd0;
            rd_addr    <= 24'd0;
            running    <= 9'sd0;
            cur_ch     <= 2'd0;
            for (i = 0; i < 4; i = i + 1) begin
                ch_active[i]  <= 1'b0;
                ch_pos[i]     <= 24'd0;
                ch_inc[i]     <= 9'd0;
                ch_vol[i]     <= 6'd0;
                ch_len[i]     <= 24'd0;
                ch_looppos[i] <= 24'd0;
                ch_looplen[i] <= 24'd0;
                ch_base[i]    <= 24'd0;
            end
        end else begin
            // ---- commands, honoured any time ----
            if (cmd_valid) begin
                if (cmd_vol == 8'd0) begin
                    ch_active[cmd_ch] <= 1'b0;            // vol 0 is a STOP, not a silent play
                end else begin
                    ch_active[cmd_ch]  <= 1'b1;
                    ch_pos[cmd_ch]     <= 24'd0;
                    ch_inc[cmd_ch]     <= rate_inc(cmd_freq);
                    ch_vol[cmd_ch]     <= (cmd_vol > 8'd63) ? 6'd63 : cmd_vol[5:0];
                    ch_len[cmd_ch]     <= cmd_len;
                    ch_looppos[cmd_ch] <= cmd_loop_pos;
                    ch_looplen[cmd_ch] <= cmd_loop_len;
                    ch_base[cmd_ch]    <= cmd_data_base;
                end
            end

            case (st)
            S_IDLE: if (tick) begin
                        running <= 9'sd0;
                        cur_ch  <= 2'd0;
                        st      <= S_RD1;
                    end
            S_RD1: begin
                        // p1 and ilc are sampled BEFORE the position advances, exactly as the C does.
                        p1   = ch_pos[cur_ch] >> 8;
                        ilc  = ch_pos[cur_ch][7:0];
                        // p2 is the next sample, or - when this tick sits on the last sample of a loop -
                        // the loop position, because mixer.cpp assigns loopPos to the position AND uses
                        // it as p2 in that same iteration. The pair must be fetched before the position
                        // is advanced, so it is resolved here rather than later.
                        if (ch_looplen[cur_ch] != 0) begin
                            if (p1 == (ch_looppos[cur_ch] + ch_looplen[cur_ch] - 1)) p2 = ch_looppos[cur_ch];
                            else                                                       p2 = p1 + 24'd1;
                        end else begin
                            if (p1 >= ch_len[cur_ch] - 24'd1) p2 = 24'd0;   // never used: the channel stops
                            else                              p2 = p1 + 24'd1;
                        end
                        b1   <= 8'd0;
                        b2   <= 8'd0;
                        rd_addr <= ch_base[cur_ch] + p1;
                        st   <= S_W1;
                    end
            S_W1: begin
                        b1 <= rd_data;
                        // advance the position now, so the loop test below uses the pre-advance p1
                        next_pos = ch_pos[cur_ch] + ch_inc[cur_ch];
                        rd_addr  <= ch_base[cur_ch] + p2;
                        st       <= S_RD2;
                    end
            S_RD2: st <= S_W2;
            S_W2: begin
                        b2 <= rd_data;
                        st <= S_CALC;
                    end
            S_CALC: begin
                        if (ch_active[cur_ch]) begin
                            running <= clamp8(running + scale_vol(
                                $signed(8'((($signed({1'b0,b1}) * (9'd255 - {1'b0,ilc}))
                                           + ($signed({1'b0,b2}) * {1'b0,ilc})) >> 8)),
                                ch_vol[cur_ch]));
                        end
                        st <= S_NEXT;
                    end
            S_NEXT: begin
                        // advance and loop, matching mixer.cpp including the raw-index wrap
                        if (ch_active[cur_ch]) begin
                            if (ch_looplen[cur_ch] != 0) begin
                                if ((ch_pos[cur_ch] >> 8) == (ch_looppos[cur_ch] + ch_looplen[cur_ch] - 1))
                                    ch_pos[cur_ch] <= ch_looppos[cur_ch];      // RAW, not << 8
                                else
                                    ch_pos[cur_ch] <= ch_pos[cur_ch] + ch_inc[cur_ch];
                            end else begin
                                if ((ch_pos[cur_ch] >> 8) == (ch_len[cur_ch] - 1)) begin
                                    ch_active[cur_ch] <= 1'b0;
                                    ch_pos[cur_ch]    <= ch_pos[cur_ch] + ch_inc[cur_ch];
                                end else
                                    ch_pos[cur_ch] <= ch_pos[cur_ch] + ch_inc[cur_ch];
                            end
                        end
                        if (cur_ch == 2'd3) st <= S_OUT;
                        else begin
                            cur_ch <= cur_ch + 2'd1;
                            st     <= S_RD1;
                        end
                    end
            S_OUT: begin
                        out_sample <= running;
                        st         <= S_IDLE;
                    end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
