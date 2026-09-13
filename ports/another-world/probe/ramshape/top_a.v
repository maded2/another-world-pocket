module top(input clk, input [13:0] addr, input wen, input [3:0] wmask, input [15:0] din, output [15:0] dout);
  wire [15:0] d0,d1,d2,d3;
  fb_nib_sync a(clk,addr,wen,wmask,din,d0); fb_nib_sync b(clk,addr,wen,wmask,din,d1);
  fb_nib_sync c(clk,addr,wen,wmask,din,d2); fb_nib_sync d_(clk,addr,wen,wmask,din,d3);
  assign dout = d0^d1^d2^d3;
endmodule
