// Isolate which framebuffer memory shape Cyclone V can map. Four instances
// each (the design has 4 framebuffers), outputs consumed so nothing is pruned.

// (a) 16-bit words, 4-bit (nibble) write mask, SYNCHRONOUS read = SPRAM semantics
module fb_nib_sync #(parameter DEPTH=16384)(input clk, input [13:0] addr, input wen,
        input [3:0] wmask, input [15:0] din, output reg [15:0] dout);
  reg [15:0] mem [0:DEPTH-1];
  always @(posedge clk) begin
    dout <= mem[addr];
    if (wen) begin
      if (wmask[0]) mem[addr][3:0]   <= din[3:0];
      if (wmask[1]) mem[addr][7:4]   <= din[7:4];
      if (wmask[2]) mem[addr][11:8]  <= din[11:8];
      if (wmask[3]) mem[addr][15:12] <= din[15:12];
    end
  end
endmodule

// (b) same but ASYNCHRONOUS read (what my earlier stub accidentally modelled)
module fb_nib_async(input clk, input [13:0] addr, input wen, input [3:0] wmask,
        input [15:0] din, output [15:0] dout);
  reg [15:0] mem [0:16383];
  always @(posedge clk) if (wen) begin
      if (wmask[0]) mem[addr][3:0]   <= din[3:0];
      if (wmask[1]) mem[addr][7:4]   <= din[7:4];
      if (wmask[2]) mem[addr][11:8]  <= din[11:8];
      if (wmask[3]) mem[addr][15:12] <= din[15:12];
  end
  assign dout = mem[addr];
endmodule

// (c) per-pixel 4-bit RAM, 320*200, synchronous read = the design's own ECP5 path
module fb_px4(input clk, input [15:0] addr, input wen, input [3:0] din, output reg [3:0] dout);
  reg [3:0] mem [0:63999];
  always @(posedge clk) begin
    dout <= mem[addr];
    if (wen) mem[addr] <= din;
  end
endmodule

// (d) 16-bit words, byte (8-bit) write mask, synchronous read = what M9K offers
module fb_byte_sync(input clk, input [13:0] addr, input wen, input [1:0] wmask,
        input [15:0] din, output reg [15:0] dout);
  reg [15:0] mem [0:16383];
  always @(posedge clk) begin
    dout <= mem[addr];
    if (wen) begin
      if (wmask[0]) mem[addr][7:0]   <= din[7:0];
      if (wmask[1]) mem[addr][15:8]  <= din[15:8];
    end
  end
endmodule

// (e) control: 16-bit words, no write mask, synchronous read
module fb_plain(input clk, input [13:0] addr, input wen, input [15:0] din,
                output reg [15:0] dout);
  reg [15:0] mem [0:16383];
  always @(posedge clk) begin
    dout <= mem[addr];
    if (wen) mem[addr] <= din;
  end
endmodule
