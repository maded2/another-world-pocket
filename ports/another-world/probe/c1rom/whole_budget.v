// The whole a5k memory budget on one Pocket die, using the framebuffer shape
// that maps (per-pixel 4bpp) plus the bridge-loaded ROM bank.  Every array
// size below is copied from the measured inventory of the generated build.v.
module top (
    input  wire clk_bridge, clk_soc, bridge_wr, wen,
    input  wire [15:0] bridge_waddr, input wire [31:0] bridge_wdata,
    input  wire [17:0] vm_addr,
    input  wire [15:0] fb_addr, input wire [3:0] fb_w,
    output wire [7:0]  vm_byte, output wire [7:0] keep_o, output wire [3:0] fb_dout
);
    // ---- ROM bank: 192 KB, bridge-written / VM-read
    wire [31:0] romw;
    rom_bank #(.DEPTH(49152), .AW(16)) rom (
        .clk_bridge(clk_bridge), .bridge_wr(bridge_wr), .bridge_waddr(bridge_waddr),
        .bridge_wdata(bridge_wdata), .clk_soc(clk_soc), .vm_addr(vm_addr), .vm_rdata(romw));
    assign vm_byte = romw[8*vm_addr[1:0] +: 8];
    assign keep_o = keep;

    // ---- four 320x200 4bpp framebuffers (the shape that maps on Cyclone V)
    wire [3:0] d0,d1,d2,d3;
    // distinct address per page: identical inputs would be merged by synthesis
    fb_px4 p0(clk_soc, {2'b00,fb_addr}              , wen, fb_w, d0);
    fb_px4 p1(clk_soc, {2'b00,fb_addr} ^ 18'd65521  , wen, fb_w, d1);
    fb_px4 p2(clk_soc, {2'b00,fb_addr} ^ 18'd65513  , wen, fb_w, d2);
    fb_px4 p3(clk_soc, {2'b00,fb_addr} ^ 18'd65497  , wen, fb_w, d3);
    assign fb_dout = d0 ^ d1 ^ d2 ^ d3;

    // ---- the game's own arrays, sizes measured from build.v
    reg [17:0] inv_y   [0:1023];      // rasterizer, brom
    reg [29:0] opdec   [0:255];
    reg [48:0] polyStk [0:127];
    reg [16:0] vmVars  [0:255];
    reg [16:0] thrData [0:127];
    reg [32:0] polygon [0:63];
    reg [8:0]  chanAct [0:127];
    reg [16:0] scrStk  [0:63];
    reg [8:0]  vmdata  [0:63];
    reg [16:0] palette [0:31];
    always @(posedge clk_soc) begin
        if (bridge_wr) begin
            inv_y[bridge_waddr[9:0]]    <= bridge_wdata[17:0];
            opdec[bridge_waddr[7:0]]    <= bridge_wdata[29:0];
            polyStk[bridge_waddr[6:0]]  <= bridge_wdata[25:0];
            vmVars[bridge_waddr[7:0]]   <= bridge_wdata[16:0];
            thrData[bridge_waddr[6:0]]  <= bridge_wdata[16:0];
            polygon[bridge_waddr[5:0]]  <= bridge_wdata[20:0];
            chanAct[bridge_waddr[6:0]]  <= bridge_wdata[8:0];
            scrStk[bridge_waddr[5:0]]   <= bridge_wdata[16:0];
            vmdata[bridge_waddr[5:0]]   <= bridge_wdata[8:0];
            palette[bridge_waddr[4:0]]  <= bridge_wdata[16:0];
        end
    end
    wire [7:0] keep = inv_y[vm_addr[9:0]][7:0] ^ opdec[vm_addr[7:0]][7:0]
                    ^ polyStk[vm_addr[6:0]][7:0] ^ vmVars[vm_addr[7:0]][7:0]
                    ^ thrData[vm_addr[6:0]][7:0] ^ polygon[vm_addr[5:0]][7:0]
                    ^ chanAct[vm_addr[6:0]][7:0] ^ scrStk[vm_addr[5:0]][7:0]
                    ^ vmdata[vm_addr[5:0]][7:0]  ^ palette[vm_addr[4:0]][7:0];
    // (keep drives keep_o, which keeps the game arrays live)
endmodule
