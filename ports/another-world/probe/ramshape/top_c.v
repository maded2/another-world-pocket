module top(input clk, input [15:0] addr, input wen, input [3:0] din, output [3:0] dout);
  wire [3:0] d0,d1,d2,d3;
  fb_px4 a(clk,addr,wen,din,d0); fb_px4 b(clk,addr,wen,din,d1);
  fb_px4 c(clk,addr,wen,din,d2); fb_px4 d_(clk,addr,wen,din,d3);
  assign dout = d0^d1^d2^d3;
endmodule
