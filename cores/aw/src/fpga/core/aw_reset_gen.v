//
// aw_reset_gen - where the host's reset meets the PLL lock pin.
//
// Two things must come out of reset in two different orders, and getting this wrong
// cost a full hardware round-trip (2026-10-17):
//
//   * The LOAD path - bridge write acceptance, the FIFO, the PSRAM drain, the trailer
//     check - has to be up as soon as the PLL is locked. The OS streams the pack with
//     `loadf` while still holding the core in reset: Reset Exit arrives only after the
//     transfer completes (System/Logs/Eddie Chan.Another World_20261017_075232.txt -
//     loader runs, "File: LOADF Long Start", then Run/Reset Exit). When this path was
//     gated on ~reset_n, every pack byte was discarded during a "successful" 2 MiB load
//     and the debug counters read zero. The known-good SNES data_loader has no reset
//     input at all for exactly this reason.
//
//   * The GAME (VM + render pipeline) stays held by the host's reset until Run, on top
//     of rom_ready. That is the only place reset_n may gate anything in this design.
//
// tb_reset_gen.sv pins the ordering down; do not fold reset_n back into the load path.
//

module aw_reset_gen (
    input  wire clk_core,       // 24.75 MHz design clock
    input  wire clk_psram,      // 92.8125 MHz PSRAM sequence clock
    input  wire pll_locked,     // PLL lock; core_top passes the clk_74a-synchronised copy
                                // (rst_bridge drives bridge-domain logic). The module itself
                                // does not sync it - tb_reset_gen drives this port directly.
    input  wire reset_n,        // host reset, bridge domain (async)
    input  wire rom_ready,      // clk_core domain, from aw_rom
    output wire rst_bridge,     // load path, clk_bridge domain: PLL only, never the host's
    output reg  rst_core,       // staged release into clk_core (active high)
    output reg  rst_psram,      // staged release into clk_psram (active high)
    output wire design_run      // game may run: clocks up, pack understood, host released
);

    // Load-path reset: the PLL not being up yet. Nothing else.
    assign rst_bridge = ~pll_locked;

    // Synchronous, stretched releases into each design clock, so nothing comes out of
    // reset on the same edge the PLL lock pin happens to tick.
    reg [3:0] cnt_core, cnt_psram;

    always @(posedge clk_core) begin
        cnt_core <= rst_bridge ? 4'd0 : ((cnt_core == 4'd15) ? cnt_core : cnt_core + 4'd1);
        rst_core <= rst_bridge || (cnt_core != 4'd15);
    end

    always @(posedge clk_psram) begin
        cnt_psram <= rst_bridge ? 4'd0 : ((cnt_psram == 4'd15) ? cnt_psram : cnt_psram + 4'd1);
        rst_psram <= rst_bridge || (cnt_psram != 4'd15);
    end

    // Host reset into the core clock, for design_run only.
    reg [2:0] rn_s;
    always @(posedge clk_core) rn_s <= {rn_s[1:0], reset_n};

    assign design_run = rn_s[2] && ~rst_core && rom_ready;

endmodule
