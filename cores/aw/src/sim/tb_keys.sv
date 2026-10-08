// tb_keys.sv - unit test for aw_keys: the Pocket controller word -> vm.si's jstick packing.
//
// This is the input path tb_soc cannot reach. tb_soc drives the SoC's jstick port directly, so
// every "input works" claim it supports says nothing about whether a real pad's bits land in the
// right places - which is exactly the bug class that made this mapping wrong twice over (wrong
// Analogue bit numbers, and fire/right swapped in the packing) while every simulation was green.
//
//   ./docker/run-silice.sh scripts/sim_keys.sh
//
// Bit numbers under test come from Analogue's bus-communication docs:
//   [0] dpad_up  [1] dpad_down  [2] dpad_left  [3] dpad_right  [4] face_a  [5] face_b
// and vm.si reads jstick as:
//   [0] right    [1] left       [2] up         [3] down        [4] fire
`timescale 1ns/1ps
module tb_keys;

    reg clk = 1'b0;
    always #20.20202 clk = ~clk;          // clk_core, 24.75 MHz

    reg  [31:0] cont1_key = 32'h0000_0000;
    wire [5:0]  jstick;

    integer errors = 0;
    integer checks = 0;

    aw_keys u_keys (
        .clk        (clk),
        .cont1_key  (cont1_key),
        .jstick     (jstick)
    );

    // Settle past the 3FF array, then compare. 4 clocks = depth + 1, so a shallower (or absent)
    // synchroniser still passes the value cases and gets caught by the latency case below.
    // Not called `expect`: that is a SystemVerilog keyword (the immediate expect assertion),
    // and the parser error it produces - "syntax error, unexpected expect" - points nowhere near
    // the cause.
    task automatic expect_bits(input string label, input [5:0] want);
    begin
        repeat (4) @(posedge clk);   // settle past the 3FF array before comparing
        checks = checks + 1;
        if (jstick !== want) begin
            $display("  %-18s cont1_key=%08h  jstick=%b  want %b   FAIL",
                     label, cont1_key, jstick, want);
            errors = errors + 1;
        end else begin
            $display("  %-18s cont1_key=%08h  jstick=%b  ok", label, cont1_key, jstick);
        end
    end
    endtask

    initial begin
        $display("=== aw_keys: Pocket cont1_key -> vm.si jstick ===");
        $display("    (vm.si: bit0 right, bit1 left, bit2 up, bit3 down, bit4 fire)");

        expect_bits("all released",  6'b000000);
        cont1_key = 32'h1 << 3;  expect_bits("dpad_right",   6'b000001);
        cont1_key = 32'h1 << 2;  expect_bits("dpad_left",    6'b000010);
        cont1_key = 32'h1 << 0;  expect_bits("dpad_up",      6'b000100);
        cont1_key = 32'h1 << 1;  expect_bits("dpad_down",    6'b001000);
        cont1_key = 32'h1 << 4;  expect_bits("face_a=fire",  6'b010000);
        cont1_key = 32'h1 << 5;  expect_bits("face_b=fire",  6'b010000);
        cont1_key = (32'h1 << 3) | (32'h1 << 5); expect_bits("right+face_b", 6'b010001);
        cont1_key = 32'h0000_003F;             expect_bits("all six held",   6'b011111);

        // Things that must NOT move the hero. Start/select are bits 15/14: with the numbers this
        // file used before the fix, face_start was read as AW_KEY_UP and face_select as
        // AW_KEY_DOWN, so pressing START walked the hero down-left.
        cont1_key = (32'h1 << 15) | (32'h1 << 14); expect_bits("start+select", 6'b000000);
        cont1_key = 32'hFFFF_FFC0;                 expect_bits("shoulders/sticks", 6'b000000);
        cont1_key = 32'h0000_0000;

        // ---- synchroniser depth ----
        // "It is registered" and "it is registered three deep" are different answers about
        // metastability, so the depth is asserted rather than assumed.
        repeat (6) @(posedge clk);
        if (jstick !== 6'b000000) begin
            $display("  FAIL: jstick=%b with cont1_key 0 before the latency test", jstick);
            errors = errors + 1;
        end
        cont1_key = 32'h1 << 3;
        repeat (2) @(posedge clk);
        checks = checks + 1;
        if (jstick !== 6'b000000) begin
            $display("  FAIL: output changed after 2 clocks - the synchroniser is not 3 deep");
            errors = errors + 1;
        end
        @(posedge clk); #1;
        checks = checks + 1;
        if (jstick !== 6'b000001) begin
            $display("  FAIL: output still %b at the third clock (want 000001)", jstick);
            errors = errors + 1;
        end else begin
            $display("  synchroniser depth   3 clocks: output stable before, updated on the 3rd  ok");
        end

        $display("tb_keys: %0d checks, %0d errors%s", checks, errors,
                 errors == 0 ? " -> PASS" : "");
        $fflush;
        if (errors != 0) $fatal(1, "tb_keys: FAIL");
        $finish;
    end

endmodule
