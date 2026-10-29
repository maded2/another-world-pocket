// tb_reset_gen - the host-reset vs load-path ordering that hardware proved wrong.
//
// The OS streams the pack with `loadf` while still holding the core in reset; Reset
// Exit arrives only after the transfer (System/Logs/Eddie Chan.Another World_
// 20261017_075232.txt). On 2026-10-17 the bridge-domain reset was
// ~reset_n | ~pll_locked, so every pack byte was discarded during a "successful"
// 2 MiB load and the debug counters read zero - while every module-level sim was
// green, because none of them ever held host reset across a load. This bench pins
// the ordering down so it cannot regress silently again.
`timescale 1ns/1ps
`default_nettype none

module tb_reset_gen;

    reg clk_core = 0, clk_psram = 0;
    always #20.20202 clk_core  = ~clk_core;   // 24.75 MHz
    always #6.06060 clk_psram = ~clk_psram;  // 82.5 MHz

    reg  pll_locked = 1'b0, reset_n = 1'b0, rom_ready = 1'b0;
    wire rst_bridge, rst_core, rst_psram, design_run;

    aw_reset_gen dut (
        .clk_core   ( clk_core   ),
        .clk_psram  ( clk_psram  ),
        .pll_locked ( pll_locked ),
        .reset_n    ( reset_n    ),
        .rom_ready  ( rom_ready  ),
        .rst_bridge ( rst_bridge ),
        .rst_core   ( rst_core   ),
        .rst_psram  ( rst_psram  ),
        .design_run ( design_run )
    );

    integer errors = 0;
    task expect(input [8*64-1:0] name, input cond);
        begin
            if (!cond) begin
                $display("tb_reset_gen: FAIL %s", name);
                errors = errors + 1;
            end else begin
                $display("tb_reset_gen: ok   %s", name);
            end
        end
    endtask

    initial begin
        // PLL not up yet: everything in reset, game held.
        #50;
        expect("pre-lock: load path in reset", rst_bridge && rst_core && rst_psram);
        expect("pre-lock: game held", !design_run);

        // PLL locks while the host still holds reset - the real boot order.
        pll_locked = 1'b1;
        repeat (40) @(posedge clk_core);
        repeat (40) @(posedge clk_psram);
        expect("locked+held: load path UP (pack must stream now)",
               !rst_bridge && !rst_core && !rst_psram);

        // A pack could already be in even while the game is held.
        rom_ready = 1'b1;
        repeat (10) @(posedge clk_core);
        expect("locked+held: game still held", !design_run);

        // Run phase: Reset Exit.
        reset_n = 1'b1;
        repeat (10) @(posedge clk_core);
        expect("released: game runs", design_run);

        // User exits: Reset Enter. The game stops, but the load path must stay up -
        // a reload of the (reloadable) data slot happens while the core is held again.
        reset_n = 1'b0;
        repeat (10) @(posedge clk_core);
        expect("re-held: game stopped", !design_run);
        expect("re-held: load path still up", !rst_bridge && !rst_core && !rst_psram);

        // PLL unlock resets everything again.
        pll_locked = 1'b0;
        repeat (40) @(posedge clk_core);
        repeat (40) @(posedge clk_psram);
        expect("unlock: all in reset", rst_bridge && rst_core && rst_psram && !design_run);

        if (errors == 0) $display("tb_reset_gen: all checks passed -> PASS");
        else             $display("tb_reset_gen: %0d error(s) -> FAIL", errors);
        $finish;
    end

endmodule
