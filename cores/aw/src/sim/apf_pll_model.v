// apf_pll_model.v - behavioural stand-in for the altera_pll megafunction, for
// simulation only (Verilator cannot elaborate the Quartus IP). Quartus uses the
// real one; this file is never part of a synthesis build.
//
// It reproduces exactly what aw_pll.v asks for:
//   outclk[0] = 24.75 MHz          (74.25 / 3)   clk_core, also the pixel clock
//   outclk[1] = 24.75 MHz +90 deg  (10101 ps)    video_rgb_clock_90
//   outclk[2] = 82.5 MHz           (74.25 * 11/12) clk_psram
//   locked    rises shortly after t=0 (the real PLL locks in a few hundred us;
//             the sim only needs "locked before the first interesting event")
//
// Clock generation style matters here: an `initial begin #d; forever #d
// x = ~x; end` block silently drops its toggles under Verilator 5.020 when this
// parameterised module is instantiated from another module (the same code works
// in a plain, unparameterised module - the bug needs both). A simple initial
// block like `locked` survives. So the clocks use the always forms:
//   outclk[0]  always #half x = ~x;                    (plain rhythm)
//   outclk[1]  always begin #quarter; forever #half ... end  (+90 deg offset)

`timescale 1ns/1ps
`default_nettype none

module altera_pll #(
    // Every parameter aw_pll.v passes, accepted and ignored - the same reason
    // Quartus accepts them: pll_type "General" derives the counters from the
    // frequencies at compile time.
    parameter fractional_vco_multiplier   = "false",
    parameter reference_clock_frequency   = "74.25 MHz",
    parameter operation_mode              = "normal",
    parameter number_of_clocks            = 3,
    parameter output_clock_frequency0     = "24.75 MHz",
    parameter phase_shift0                = "0 ps",
    parameter duty_cycle0                 = 50,
    parameter output_clock_frequency1     = "24.75 MHz",
    parameter phase_shift1                = "10101 ps",
    parameter duty_cycle1                 = 50,
    parameter output_clock_frequency2     = "82.5 MHz",
    parameter phase_shift2                = "0 ps",
    parameter duty_cycle2                 = 50,
    parameter output_clock_frequency3     = "0 MHz",
    parameter phase_shift3                = "0 ps",
    parameter duty_cycle3                 = 50,
    parameter pll_type                    = "General",
    parameter pll_subtype                 = "General"
) (
    input  wire        rst,      // active high; held low by aw_pll in this core
    output wire [3:0]  outclk,
    output reg         locked,
    output wire        fboutclk,
    input  wire        fbclk,
    input  wire        refclk    // 74.25 MHz - the model does not need to count it
);

    // 24.75 MHz: period 40.404 ns -> half period 20.202 ns
    reg outclk0 = 1'b0;
    always #20.202 outclk0 = ~outclk0;

    // +90 deg: first toggle a quarter period (10.101 ns) after t=0, then the
    // same half-period rhythm as outclk0. (A bare `initial #10.101;` would not
    // delay this always block - it starts at t=0 regardless.)
    reg outclk1 = 1'b0;
    always begin
        #10.101;
        forever #20.202 outclk1 = ~outclk1;
    end

    // 82.5 MHz: period 12.121 ns -> half period 6.0606 ns
    // (the first draft of this model used the full period as the toggle delay and ran
    // at 41.25 MHz - fast enough to look alive, slow enough that a PSRAM read took
    // twice the reader's per-word budget and the boot check rewound forever)
    reg outclk2 = 1'b0;
    always #6.0606 outclk2 = ~outclk2;

    assign outclk   = {1'b0, outclk2, outclk1, outclk0};
    assign fboutclk = 1'b0;

    // rst is accepted but the model never unlocks: aw_pll holds it low anyway,
    // and a mid-sim unlock would just desync the benches.
    initial begin
        locked = 1'b0;
        #250 locked = 1'b1;
    end

endmodule

`default_nettype wire
