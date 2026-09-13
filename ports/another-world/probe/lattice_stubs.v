// ===========================================================================
// THROWAWAY AREA PROBE - not part of any port.
// Minimal stand-ins for the 4 Lattice iCE40 primitives that Silice emits, so
// Quartus can elaborate and report area for the a5k game logic. Behaviour of
// the PLL/IO stubs is intentionally meaningless; the SPRAM stub is a real
// behavioural model (128 Kbit, 16-bit, 4-bit write mask) because the
// framebuffer memory question (analysis C2) is what we want to measure.
// ===========================================================================
module SB_PLL40_PAD #(
  parameter FEEDBACK_PATH="SIMPLE", parameter PLLOUT_SELECT="GENCLK",
  parameter [3:0] DIVR=0, parameter [6:0] DIVF=0, parameter [2:0] DIVQ=0,
  parameter [2:0] FILTER_RANGE=0,
  parameter DELAY_ADJUSTMENT_MODE_FEEDBACK="FIXED", parameter [3:0] FDA_FEEDBACK=0,
  parameter DELAY_ADJUSTMENT_MODE_RELATIVE="FIXED", parameter [3:0] FDA_RELATIVE=0,
  parameter [1:0] SHIFTREG_DIV_MODE=0, parameter ENABLE_ICEGATE=1'b0
)(input PACKAGEPIN, output PLLOUTCORE, output PLLJPLLLOGIC, input EXTFEEDBACK,
   input [7:0] DYNAMICDELAY, input LATCHINPUTVALUE, input RESETB, input BYPASS, output LOCK);
  assign PLLOUTCORE = PACKAGEPIN;
  assign PLLJPLLLOGIC = 1'b0;
  assign LOCK = 1'b1;
endmodule

module SB_GB(input USER_SIGNAL_TO_GLOBAL_BUFFER, output GLOBAL_BUFFER_OUTPUT);
  assign GLOBAL_BUFFER_OUTPUT = USER_SIGNAL_TO_GLOBAL_BUFFER;
endmodule

module SB_IO #(parameter [5:0] PIN_TYPE = 6'b000000)(
  inout PACKAGE_PIN,
  output [7:0] D_IN_0, output [7:0] D_IN_1,
  input  [7:0] D_OUT_0, input  [7:0] D_OUT_1,
  input INPUT_CLK, input OUTPUT_CLK, input OUTPUT_ENABLE,
  output PACKAGE_PIN_I, output PACKAGE_PIN_O, input PACKAGE_PIN_OE);
  assign D_IN_0 = 8'b0; assign D_IN_1 = 8'b0;
  assign PACKAGE_PIN_I = 1'b0; assign PACKAGE_PIN_O = 1'b0;
endmodule

module SB_SPRAM256KA(input [15:0] ADDRESS, input [15:0] DATAIN,
                     input [3:0] MASKWREN, input WREN, input [3:0] CHIPSELECT,
                     input CLOCK, input STANDBY, input SLEEP, input POWEROFF,
                     output [15:0] DATAOUT);
  reg [15:0] mem [0:16383];
  always @(posedge CLOCK) begin
    if (CHIPSELECT[0] && WREN) begin
      if (MASKWREN[0]) mem[ADDRESS][3:0]   <= DATAIN[3:0];
      if (MASKWREN[1]) mem[ADDRESS][7:4]   <= DATAIN[7:4];
      if (MASKWREN[2]) mem[ADDRESS][11:8]  <= DATAIN[11:8];
      if (MASKWREN[3]) mem[ADDRESS][15:12] <= DATAIN[15:12];
    end
  end
  assign DATAOUT = mem[ADDRESS];
endmodule
