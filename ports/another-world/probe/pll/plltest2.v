// What can the Pocket's Cyclone V PLL actually synthesise from the Pocket's
// 74.25 MHz? Request a target and let altera_pll pick counters; the post-fit
// PLL summary reports what it really achieved.
module plltest (
    input  wire refclk,     // 74.25 MHz from the Pocket
    output wire clk_soc,    // a5k SoC / pixel clock
    output wire clk_2x,     // the design's clock2x
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(2),
        .output_clock_frequency0("24.75 MHz"),   // exact 74.25/3 (and x2) -- the "no fractional work" option
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("49.5 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("0 MHz"),
        .output_clock_frequency3("0 MHz"),
        .output_clock_frequency4("0 MHz"),
        .output_clock_frequency5("0 MHz"),
        .output_clock_frequency6("0 MHz"),
        .output_clock_frequency7("0 MHz")
    ) pll_a5k_b (
        .refclk(refclk), .rst(1'b0),
        .outclk({clk_2x, clk_soc}), .locked(locked),
        .fboutclk(), .fbclk()
    );
endmodule
