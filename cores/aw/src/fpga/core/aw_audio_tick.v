// 48 kHz sample tick from the 24.75 MHz design clock.
//
// 24_750_000 / 48_000 = 515.625 - NOT an integer, so a fixed divider cannot produce the rate APF requires
// ("exactly 48 kHz, no rate changes"). A counter that divides by 515 or 516 gives 48,058 Hz or 47,965 Hz,
// either of which is a wrong sample rate for the whole core. This uses a fractional accumulator instead:
// add the output rate every clock and emit a tick whenever it reaches the input rate, so the LONG-RUN rate is
// exact and no individual interval is more than one clock out.
`timescale 1ns/1ps

module aw_audio_tick #(
    parameter integer CLK_HZ = 24_750_000,
    parameter integer RATE   = 48_000
) (
    input  wire clk,
    input  wire rst,
    output reg  tick            // one clk cycle wide, RATE per second on average
);
    // Enough width for the accumulator to hold CLK_HZ-1 without wrapping on its own.
    localparam integer AW = $clog2(CLK_HZ) + 1;

    reg [AW-1:0] acc;

    always @(posedge clk) begin
        if (rst) begin
            acc  <= {AW{1'b0}};
            tick <= 1'b0;
        end else if (acc + RATE >= CLK_HZ) begin
            acc  <= acc + RATE - CLK_HZ;
            tick <= 1'b1;
        end else begin
            acc  <= acc + RATE;
            tick <= 1'b0;
        end
    end
endmodule
