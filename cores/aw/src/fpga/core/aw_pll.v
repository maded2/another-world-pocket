// -----------------------------------------------------------------------------
// Another World / Pocket - clocking.
//
// The Pocket hands a core two asynchronous 74.25 MHz inputs and nothing else;
// everything else the design needs comes out of this PLL.
//
//   clk_core   24.75 MHz = 74.25 / 3   design clock *and* pixel clock
//   clk_core90 24.75 MHz, +90 deg      video_rgb_clock_90 (the scaler samples
//                                       on this edge; the APF contract)
//   clk_psram  49.5  MHz = 74.25 * 2/3 ZBT PSRAM controller
//
// Why 24.75 and not something closer to upstream's 25 MHz: 25 MHz is not an
// integer relationship to 74.25 MHz, and this clock is also the pixel clock, so
// the frame total has to divide the pixel clock cleanly. 825 x 500 at 24.75 MHz
// is exactly 60.000000 Hz - see the display section of src/si/aw_pocket.si. It
// is 1 % below upstream, which is well inside what the game's own pacing needs
// (its frame wait is a vblank sync, not a stopwatch).
//
// 24.75 = 49.5/2 and both are exact integer ratios of the reference, so this is
// an ordinary integer-mode PLL: VCO at 742.5 MHz, divided by 30 and 15.
//
// Phase: 24.75 MHz has a 40404 ps period, so quadrature is 10101 ps.
// -----------------------------------------------------------------------------
//
// Hand-written parameter list, same shape as the APF template's mf_pllbase:
// Quartus Lite ships no ip-generate-cli, and with pll_type "General" the PLL
// synthesizer derives the counters from these frequencies at compile time. The
// achieved frequencies are checked after synthesis in build/<core>/report.txt.
`default_nettype none

module aw_pll (
    input  wire reset_n,    // PLL reset, active low (the template's PLL resets are
                            // held until the bridge is up; see core_top)
    input  wire refclk,     // clk_74a, 74.25 MHz
    output wire clk_core,
    output wire clk_core90,
    output wire clk_psram,
    output wire locked
);

    wire outclk0, outclk1, outclk2;

    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(3),

        .output_clock_frequency0("24.75 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),

        .output_clock_frequency1("24.75 MHz"),
        .phase_shift1("10101 ps"),
        .duty_cycle1(50),

        .output_clock_frequency2("49.5 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),

        .output_clock_frequency3("0 MHz"),
        .phase_shift3("0 ps"),
        .duty_cycle3(50),

        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (~reset_n),
        .outclk   ({outclk2, outclk1, outclk0}),
        .locked   (locked),
        .fboutclk ( ),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );

    assign clk_core  = outclk0;
    assign clk_core90 = outclk1;
    assign clk_psram = outclk2;

endmodule

`default_nettype wire
