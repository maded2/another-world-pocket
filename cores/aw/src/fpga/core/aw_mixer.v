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
    output reg         out_valid,          // one clk cycle after out_sample updates
    // Ticks that arrived while the sequencer was mid-fetch and were therefore LOST. The fetch path is
    // variable-latency (PSRAM behind a clock-domain handshake), so this is reachable rather than theoretical:
    // the integration bench must assert it stays 0 under the real VM load, because a dropped tick is a
    // sample-rate error that is audible but invisible.
    output reg  [31:0] drop_ticks,

    // Command: play a sound on a channel, or stop it (vol == 0).
    input  wire        cmd_valid,
    input  wire [1:0]  cmd_ch,
    input  wire [5:0]  cmd_freq,           // index into the rate table, must be < 40
    input  wire [7:0]  cmd_vol,            // 0 = stop; otherwise clamped to 6 bits
    input  wire [23:0] cmd_len,            // playable length in bytes
    input  wire [23:0] cmd_loop_pos,
    input  wire [23:0] cmd_loop_len,       // 0 = play once
    input  wire [23:0] cmd_data_base,      // byte address of sample 0 in the caller's memory

    // Sample fetch: REQUEST/VALID, not an implied one-cycle RAM.
    //
    // The first version hardcoded the latency in its wait states, which was correct for the bench's RAM and
    // wrong for the real path: a byte goes mixer -> clock-domain handshake -> aw_rom's sequencer -> PSRAM
    // (~12 clk_psram cycles) -> handshake back, roughly 24+ clk_core cycles, and VARIABLE because audio is
    // served only when the PSRAM port is idle. A fixed wait cannot express that, and a bench whose memory
    // answers instantly would have passed a design that cannot work on hardware.
    output reg  [23:0] rd_addr,
    output reg         rd_req,       // held until rd_valid
    input  wire        rd_valid,     // rd_data is the byte for the last rd_addr requested
    input  wire [7:0]  rd_data
);

    // ------------------------------------------------------------------ rate table
    // chunkInc = (frequenceTable[idx] << 8) / 48000, PRECOMPUTED rather than divided at runtime.
    //
    // Two reasons, and the second is why this was found at all: a divider in a four-channel mixer that has
    // to produce a sample every ~515 cycles is a waste of the fabric, and the first version computed the
    // division inside a function and produced an increment of 38 for index 20 where 0x293F gives 56 - a
    // value NO table entry can produce. Whatever the cause (the function's intermediate width, most
    // likely), a literal table cannot have it. The values are derived from staticres.cpp's
    // frequenceTable and are reproducible: (v*256)//48000 for each entry.
    function automatic [8:0] rate_inc(input [5:0] idx);
        reg [8:0] inc;
        begin
            case (idx[5:2])
            4'd0: begin
                case (idx[1:0])
                2'd0: inc = 9'd17;  2'd1: inc = 9'd18;  2'd2: inc = 9'd19;  2'd3: inc = 9'd21;
                endcase
            end
            4'd1: begin
                case (idx[1:0])
                2'd0: inc = 9'd22;  2'd1: inc = 9'd23;  2'd2: inc = 9'd25;  2'd3: inc = 9'd26;
                endcase
            end
            4'd2: begin
                case (idx[1:0])
                2'd0: inc = 9'd28;  2'd1: inc = 9'd29;  2'd2: inc = 9'd31;  2'd3: inc = 9'd33;
                endcase
            end
            4'd3: begin
                case (idx[1:0])
                2'd0: inc = 9'd35;  2'd1: inc = 9'd37;  2'd2: inc = 9'd39;  2'd3: inc = 9'd42;
                endcase
            end
            4'd4: begin
                case (idx[1:0])
                2'd0: inc = 9'd44;  2'd1: inc = 9'd47;  2'd2: inc = 9'd50;  2'd3: inc = 9'd53;
                endcase
            end
            4'd5: begin
                case (idx[1:0])
                2'd0: inc = 9'd56;  2'd1: inc = 9'd59;  2'd2: inc = 9'd63;  2'd3: inc = 9'd66;
                endcase
            end
            4'd6: begin
                case (idx[1:0])
                2'd0: inc = 9'd70;  2'd1: inc = 9'd75;  2'd2: inc = 9'd79;  2'd3: inc = 9'd84;
                endcase
            end
            4'd7: begin
                case (idx[1:0])
                2'd0: inc = 9'd89;  2'd1: inc = 9'd94;  2'd2: inc = 9'd100; 2'd3: inc = 9'd106;
                endcase
            end
            4'd8: begin
                case (idx[1:0])
                2'd0: inc = 9'd112; 2'd1: inc = 9'd119; 2'd2: inc = 9'd126; 2'd3: inc = 9'd133;
                endcase
            end
            default: begin
                case (idx[1:0])
                2'd0: inc = 9'd141; 2'd1: inc = 9'd150; 2'd2: inc = 9'd159; 2'd3: inc = 9'd168;
                endcase
            end
            endcase
            rate_inc = inc;
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
    // One tick = 4 channels x (read b1, then b2). Each read is a REQUEST/VALID transaction whose wait is as
    // long as the responder needs: in the field that is a PSRAM access behind a clock-domain handshake
    // (~24+ clk_core cycles, variable, because audio is served only when the PSRAM port is idle). The state
    // chain is therefore S_A1 -> S_W1 -> S_A2 -> S_W2 -> S_CALC, with S_W1/S_W2 waiting for rd_valid - there
    // is no fixed number of wait cycles to tune. Eight bytes per tick costs ~96 of the 516 clk_core cycles
    // available at 48 kHz (18.6%), which is the margin the integration decision was made on.
    //
    // rd_addr is a REGISTER driven non-blocking, so it becomes visible one cycle after the state that assigns
    // it; the first version captured b1 and b2 one state early and read the PREVIOUS channel's bytes (the
    // S_CALC probe showed channel 1 receiving ram[1], channel 0's second byte).
    localparam [3:0] S_IDLE = 4'd0, S_A1 = 4'd1, S_W1 = 4'd2, S_A2 = 4'd3,
                     S_W2 = 4'd4, S_CALC = 4'd5, S_NEXT = 4'd6, S_OUT = 4'd7;

    reg [3:0]  st;
    reg [1:0]  cur_ch;
    reg [23:0] p1, p2;
    reg [7:0]  ilc;
    reg [7:0]  b1, b2;
    // A non-looping channel whose next sample is the last one contributes NOTHING: mixer.cpp tests
    // `p1 == chunk.len - 1` and breaks out of the per-sample loop BEFORE interpolating, so the final byte
    // is never played. Without this the RTL emitted one extra sample per one-shot, which is exactly the
    // single off-by-one that remained at tick 55 (reference 55, RTL 54 - channel 3 contributing -1 where
    // the reference stops it first).
    reg        end_now;
    reg signed [8:0] running;         // the mix accumulator, clamped to int8 on every add
    // The interpolated sample, computed with every operand explicitly signed so the expression cannot be
    // widened to unsigned. (b1*(255-ilc) + b2*ilc) >> 8 then wraps to 8 bits, as the C int8_t store does.
    wire signed [15:0] interp_wide = ($signed({{8{b1[7]}}, b1}) * $signed({1'b0, ~ilc}))
                                   + ($signed({{8{b2[7]}}, b2}) * $signed({1'b0, ilc}));
    wire signed [7:0]  interp      = interp_wide[15:8];
    reg [23:0] next_pos;

    // signed 8-bit multiply-scale with truncation toward zero (C semantics for (b*vol)/64)
    function automatic signed [8:0] scale_vol(input signed [7:0] b, input [6:0] vol);
        // Sign-magnitude on purpose. Two width/signedness traps are avoided by doing it this way:
        //   * `(b * vol) >> 6` sizes the expression by its widest operand, so an 8-bit b truncates the
        //     product to 8 bits BEFORE shifting - 15*45 = 675 became 163 and >>6 gave 2 instead of 10.
        //   * mixing a signed b with an unsigned vol makes the whole product unsigned, which turned -128
        //     into +128 and saturated the output.
        // Magnitudes are built in 16 bits (256 - byte for negatives, because -(-128) does not fit in 8
        // bits), multiplied there, then the sign is re-applied - which is exactly C's truncation toward
        // zero for (b * volume) / 64.
        reg [15:0] magb;
        reg [23:0] prod;
        reg [8:0]  res;
        begin
            magb = b[7] ? (16'd256 - {8'd0, b}) : {8'd0, b};
            prod = magb * vol;                       // unsigned throughout
            res  = prod[14:6];                       // /64
            scale_vol = b[7] ? -res : res;
        end
    endfunction

    function automatic signed [8:0] clamp8(input signed [8:0] v);
        clamp8 = (v > 127) ? 127 : (v < -128) ? -128 : v;
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            out_sample <= 8'sd0;
            out_valid  <= 1'b0;
            drop_ticks <= 32'd0;
            rd_addr    <= 24'd0;
            rd_req     <= 1'b0;
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
            out_valid <= 1'b0;
            // A tick that lands anywhere but S_IDLE cannot be honoured by this sequencer, and it is not
            // queued: it is lost. Counted so the integration bench can assert the count is zero rather than
            // assume it.
            if (tick && st != S_IDLE) drop_ticks <= drop_ticks + 32'd1;

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
                        st      <= S_A1;
                    end
            // An inactive channel costs NO memory reads. mixer.cpp only processes active channels, and in
            // the field those reads are PSRAM round trips shared with the VM's bytecode stream: reading all
            // four channels every tick (8 reads) left 7591 dropped ticks in a 60-frame tb_soc run, 8.6% of
            // the 48 kHz ticks. Reads now cost 2 per ACTIVE channel - none in silence, four in the
            // harvest's typical case of two sounds at once - and silence therefore never touches the port.
            S_A1: if (!ch_active[cur_ch]) begin
                        st <= S_NEXT;
                    end else begin
                        // p1 and ilc are sampled BEFORE the position advances, exactly as the C does.
                        p1   = ch_pos[cur_ch] >> 8;
                        ilc  = ch_pos[cur_ch][7:0];
                        // p2 is the next sample, or the loop position when this tick sits on the last sample
                        // of a loop - mixer.cpp assigns loopPos to the position AND uses it as p2 there.
                        if (ch_looplen[cur_ch] != 0) begin
                            if (p1 == (ch_looppos[cur_ch] + ch_looplen[cur_ch] - 1)) p2 = ch_looppos[cur_ch];
                            else                                                       p2 = p1 + 24'd1;
                        end else begin
                            if (p1 >= ch_len[cur_ch] - 24'd1) p2 = 24'd0;   // unused: the channel stops
                            else                              p2 = p1 + 24'd1;
                        end
                        end_now  = (ch_looplen[cur_ch] == 0) && (p1 == (ch_len[cur_ch] - 24'd1));
                        rd_addr  <= ch_base[cur_ch] + p1;
                        rd_req   <= 1'b1;
                        st       <= S_W1;
                    end
            S_W1: if (rd_valid) begin
                        b1      <= rd_data;
                        rd_req  <= 1'b0;
                        rd_addr <= ch_base[cur_ch] + p2;
                        st      <= S_A2;
                    end
            S_A2: begin
                        rd_req <= 1'b1;
                        st     <= S_W2;
                    end
            S_W2: if (rd_valid) begin
                        b2     <= rd_data;
                        rd_req <= 1'b0;
                        st     <= S_CALC;
                    end
            S_CALC: begin
                        if (ch_active[cur_ch] && !end_now) begin
                            // SIGN-EXTEND b1/b2. They are int8 samples; zero-extending them turns -128 into
                            // +128, and mixing signed with unsigned operands makes the whole expression
                            // unsigned in Verilog, which is why this accumulated 0 before.
                            running <= clamp8(running + scale_vol(interp, {1'b0, ch_vol[cur_ch]}));
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
                            st     <= S_A1;
                        end
                    end
            S_OUT: begin
                        out_sample <= running;
                        out_valid  <= 1'b1;
                        st         <= S_IDLE;
                    end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
