// CONTROL: same 4x 32KB 16-bit RAMs, synchronous read, NO write mask at all
module top(input clk, input [13:0] addr, input wen, input [15:0] din, output [15:0] dout);
  wire [15:0] d0,d1,d2,d3;
  fb_plain a(clk,addr,wen,din,d0); fb_plain b(clk,addr,wen,din,d1);
  fb_plain c(clk,addr,wen,din,d2); fb_plain d_(clk,addr,wen,din,d3);
  assign dout = d0^d1^d2^d3;
endmodule
