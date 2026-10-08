// aw_keys.v - Pocket controller word -> the jstick packing vm.si reads.
//
// Split out of core_top.v so that this can be tested at all. tb_soc drives the SoC's jstick
// port directly and never passes through this mapping, which is how a wrong mapping survived
// every simulation this project ran while looking verified: the symptom would have been "intro
// plays, pad dead", and no simulation could show it. src/sim/tb_keys.sv now covers it.
//
// Bit numbers are Analogue's, from the developer docs "Bus Communication" page,
// https://www.analogue.co/developer/docs/bus-communication (fetched 2026-10-04):
//
//   cont1_key[0]  dpad_up      [4]  face_a       [8]  trig_l1   [12] trig_l3   [15] face_start
//   cont1_key[1]  dpad_down    [5]  face_b       [9]  trig_r1   [13] trig_r3
//   cont1_key[2]  dpad_left    [6]  face_x       [10] trig_l2   [14] face_select
//   cont1_key[3]  dpad_right   [7]  face_y       [11] trig_r2
//
// What was here before, and why it is worth writing down: RIGHT=12, LEFT=13, DOWN=14, UP=15,
// B=0, A=8 - the numbering used by APF-era community examples, which predates this word.
// Against the spec those are trig_l3, trig_r3, face_select, face_start, dpad_up and trig_l1, so
// START and SELECT would have moved the hero, the d-pad would have done nothing except UP,
// which would have fired. Separately, the old packing put RIGHT in bit 4 and FIRE in bit 0,
// while vm.si reads bit 4 as fire and bit 0 as right: two independent mistakes, neither
// reachable from any test that existed.
//
// vm.si reads jstick as: [0] right, [1] left, [2] up, [3] down, [4] fire, [5] unused.
// Verified against vm.si in simulation (tb_soc, 7/7 patterns) - that part is not a belief.

module aw_keys (
    input  wire        clk,         // design clock (clk_core); cont1_key is asynchronous to it
    input  wire [31:0] cont1_key,
    output wire [5:0]  jstick       // vm.si order: {unused, fire, down, up, left, right}
);

// Overridable so a controller-word change is a -D flag rather than an edit, but the defaults
// are the documented bits, not a guess.
`ifndef AW_KEY_UP
  `define AW_KEY_UP    0   // dpad_up
  `define AW_KEY_DOWN  1   // dpad_down
  `define AW_KEY_LEFT  2   // dpad_left
  `define AW_KEY_RIGHT 3   // dpad_right
  `define AW_KEY_A     4   // face_a
  `define AW_KEY_B     5   // face_b
`endif

    wire k_right = cont1_key[`AW_KEY_RIGHT];
    wire k_left  = cont1_key[`AW_KEY_LEFT];
    wire k_up    = cont1_key[`AW_KEY_UP];
    wire k_down  = cont1_key[`AW_KEY_DOWN];
    // Another World has one action verb, so both face buttons are fire.
    wire k_fire  = cont1_key[`AW_KEY_A] | cont1_key[`AW_KEY_B];

    // 3FF: the controller word is handed over asynchronously to the design clock. Depth is
    // observable and tb_keys asserts it, because "it is registered" and "it is registered
    // three deep" are different answers to metastability.
    reg [5:0] s1 = 6'b000000;
    reg [5:0] s2 = 6'b000000;
    reg [5:0] s3 = 6'b000000;

    always @(posedge clk) begin
        // Written in vm.si bit order, MSB first, so the concatenation can be read against the
        // comment at the top of this file without re-deriving indices: bits 5..0 are
        // {unused, fire, down, up, left, right}.
        s1 <= { 1'b0, k_fire, k_down, k_up, k_left, k_right };
        s2 <= s1;
        s3 <= s2;
    end

    assign jstick = s3;

endmodule
