// I2S output for the Pocket: MCLK 12.288 MHz, SCLK 3.072 MHz, LRCK 48 kHz, 16 data + 16 spacer bits per
// channel, LRCK low = left, signed 16-bit. Replaces the template's silence shifter (`audgen_dac <= 1'b0`).
//
// WHAT IS KEPT FROM THE TEMPLATE: the MCLK generation. It is a fractional accumulator on clk_74a, because
// 74.25 / 12.288 = 6.0425 is not an integer and a fixed divider would be a wrong MCLK; this produces 12.288 MHz
// on average with every interval exactly two clk_74a cycles where it can be.
//
// WHAT IS CHANGED: everything downstream of MCLK runs on MCLK itself with an 8-bit counter (12.288 MHz / 48 kHz
// = exactly 256), so SCLK = MCLK/4 and a frame is 64 SCLK periods. That removes the template's divided-clock
// chain (negedge of a divided SCLK driving flops) and gives one clock domain for the whole output stage, which
// is what makes the FIFO handoff simple enough to check.
//
// ALIGNMENT: LRCK changes at slot 31 and slot 63, i.e. ONE SCLK before the channel's MSB at slots 32 and 0.
// That is standard I2S (the receiver sees the new LRCK and then, one bit later, the MSB) and it reproduces the
// template's own `lrck toggles at cnt==31` timing rather than inventing a new one.
//
// SAMPLE HANDOFF: clk_core (where the mixer lives) to MCLK are unrelated 48 kHz timebases, so the sample goes
// through aw_fifo (dual-clock, depth 16) rather than a bare register. An empty FIFO repeats the previous
// sample and counts an underrun; a full one drops the sample and counts an overrun. Both counters exist so the
// integration bench can assert them at zero instead of trusting the arithmetic.
`timescale 1ns/1ps

module aw_audio_i2s (
    input  wire        clk_74a,

    // sample source (clk_core domain)
    input  wire        clk_core,
    input  wire        rst_core,       // active high, clk_core domain
    input  wire signed [15:0] sample,
    input  wire        sample_valid,   // one clk_core cycle, ~48 kHz

    output reg         audio_mclk,
    output reg         audio_sclk,     // not a Pocket pin, kept for the bench and for scope debugging
    output reg         audio_lrck,
    output reg         audio_dac,

    output reg  [15:0] underruns,
    output reg  [15:0] overruns
);

    // ------------------------------------------------------------------ MCLK = 12.288 MHz from clk_74a
    // Same accumulator as the core template: add 48 kHz*2 every cycle, toggle when it passes 742500 (which is
    // 74.25 MHz / 100), so the toggle rate is 74.25 * 245760/742500 / 2 = 12.288 MHz.
    parameter [20:0] CYCLE_48KHZ = 21'd122880 * 2;
    reg [21:0] audgen_accum;

    always @(posedge clk_74a) begin
        audgen_accum <= audgen_accum + CYCLE_48KHZ;
        if (audgen_accum >= 21'd742500) begin
            audio_mclk    <= ~audio_mclk;
            audgen_accum  <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
        end
    end

    // ------------------------------------------------------------------ reset into the MCLK domain
    reg [1:0] rst_mclk_s;
    always @(posedge audio_mclk) rst_mclk_s <= {rst_mclk_s[0], rst_core};
    wire rst_m = rst_mclk_s[1];

    // ------------------------------------------------------------------ sample FIFO (clk_core -> MCLK)
    wire        fifo_full, fifo_empty;
    wire [15:0] fifo_q;
    wire        fifo_q_valid;
    wire [4:0]  fifo_level;
    reg         fifo_rd;

    aw_fifo #(.DW(16), .AW(4)) u_samp (
        .wr_clk(clk_core), .wr_rst(rst_core),
        .wr_en(sample_valid && !fifo_full), .wr_data(sample),
        .wr_full(fifo_full), .wr_free(),
        .rd_clk(audio_mclk), .rd_rst(rst_m),
        .rd_en(fifo_rd), .rd_q(fifo_q), .rd_q_valid(fifo_q_valid),
        .rd_empty(fifo_empty), .rd_level(fifo_level)
    );

    always @(posedge clk_core) begin
        if (rst_core) overruns <= 16'd0;
        else if (sample_valid && fifo_full) overruns <= overruns + 16'd1;
    end

    // ------------------------------------------------------------------ frame shifter, on MCLK
    // slot = c[7:2] (0..63), phase = c[1:0]; dac changes at phase 0, when SCLK is low and has just fallen.
    reg [7:0]  c;
    reg [63:0] tx;          // {left[15:0], 16'h0, right[15:0], 16'h0} for the frame being sent
    reg [63:0] nx;          // the best available next frame: updated only when a sample actually arrives,
                            // so an underrun repeats the previous sample instead of going to silence
    reg        got;         // a pop was requested at slot 0 and its value is due
    wire [5:0] slot = c[7:2];

    always @(posedge audio_mclk) begin
        audio_sclk <= c[1] ^ c[0];
        if (rst_m) begin
            c         <= 8'd0;
            tx        <= 64'd0;
            nx        <= 64'd0;
            got       <= 1'b0;
            audio_lrck<= 1'b0;
            audio_dac <= 1'b0;
            audio_sclk<= 1'b0;
            fifo_rd   <= 1'b0;
            underruns <= 16'd0;
        end else begin
            c <= c + 8'd1;
            fifo_rd <= 1'b0;

            if (c[1:0] == 2'd0) begin
                // one bit slot begins; LRCK is derived from the slot so it is one slot early
                audio_lrck <= (slot >= 6'd31) && (slot < 6'd63);
                case (slot)
                6'd0: begin
                    audio_dac <= tx[63];
                    tx        <= {tx[62:0], 1'b0};
                    if (!fifo_empty) begin
                        fifo_rd <= 1'b1;
                        got     <= 1'b1;
                    end else begin
                        got       <= 1'b0;
                        underruns <= underruns + 16'd1;   // nx keeps the previous sample: repeat it
                    end
                end
                // rd_q is valid the cycle after the pop, but slot 0's own assignment has not happened yet;
                // slot 4 is far enough past it to be unambiguous.
                6'd4: begin
                    audio_dac <= tx[63];
                    tx        <= {tx[62:0], 1'b0};
                    if (got) nx <= {fifo_q, 16'h0000, fifo_q, 16'h0000};
                end
                6'd63: begin
                    audio_dac <= 1'b0;          // last spacer of the right channel
                    tx        <= nx;            // next frame (fresh sample, or the previous one repeated)
                end
                default: begin
                    audio_dac <= tx[63];
                    tx        <= {tx[62:0], 1'b0};
                end
                endcase
            end
        end
    end

endmodule
