// -----------------------------------------------------------------------------
// Another World / Pocket - clocking.
//
// The Pocket hands a core two asynchronous 74.25 MHz inputs and nothing else;
// everything else the design needs comes out of this PLL.
//
//   clk_core   24.75 MHz = 74.25 / 3    design clock *and* pixel clock
//   clk_core90 24.75 MHz, +90 deg        video_rgb_clock_90 (the scaler samples
//                                        on this edge; the APF contract)
//   clk_psram  92.8125 MHz = VCO / 8     PSRAM sequence clock
//
// Why 24.75 and not something closer to upstream's 25 MHz: 25 MHz is not an
// integer relationship to 74.25 MHz, and this clock is also the pixel clock, so
// the frame total has to divide the pixel clock cleanly. 825 x 500 at 24.75 MHz
// is exactly 60.000000 Hz - see the display section of src/si/aw_pocket.si. It
// is 1 % below upstream, which is well inside what the game's own pacing needs
// (its frame wait is a vblank sync, not a stopwatch).
//
// All three are exact integer ratios of the reference, so this is an ordinary
// integer-mode PLL: VCO at 742.5 MHz, divided by 30, 30 and 8.
//
// Why 92.8125 for the PSRAM sequence: the fitted part runs in async mode (its
// clock pin is held low - see aw_psram), so its timing is a matter of nanoseconds,
// not cycles, and the sequence may be timed on any fast clock - but not any FAST
// clock: this fabric needs ~7.4 ns clock-to-pin on the cram0 outputs (measured in
// STA), so the period must leave room for that plus the protocol's inter-signal
// setup times. 123.75 MHz failed both setup and hold on exactly those paths;
// 92.8125 (10.77 ns) leaves ~3.4 ns of margin there.
//
// The step up from 82.5 was forced by hardware, not bandwidth: at six cycles per
// access OE# was low for only two of them (build 1031's self-test read its own
// scratch address back off the bus). Reads now take twelve cycles rather than the
// seven that were thought to be enough - see aw_psram's header for the pin-level
// tAA arithmetic and for the real reason reads were silent (UB#/LB# are output
// enables). What the clock still has to do is fit the WRITE shape: seven cycles
// (75.4 ns) per access, two chained = 150.8 ns per 32-bit bridge word against the
// 161.7 ns a paced upload sustains (PACE=10 in tb_rom = 12 clk_74a cycles per
// bridge write), and ~7.4 ns of that period
// spent getting a signal from a register to a cram0 pin.
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

    // Full-width connection: the megafunction's outclk is 4 bits (four clock
    // outputs) and we use three of them. Connecting a 3-bit concat to the port
    // works in Quartus (zero extension) but Verilator 5.020 misaligns the bit
    // mapping on width-mismatched output connections - outclk[0] then never
    // reaches the net and clk_core does not run in simulation.
    wire [3:0] outclk;

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

        .output_clock_frequency2("92.8125 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),

        .output_clock_frequency3("0 MHz"),
        .phase_shift3("0 ps"),
        .duty_cycle3(50),

        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (~reset_n),
        .outclk   (outclk),
        .locked   (locked),
        .fboutclk ( ),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );

    assign clk_core   = outclk[0];
    assign clk_core90 = outclk[1];
    assign clk_psram  = outclk[2];

endmodule

`default_nettype wire
