// 192 KB ROM bank (40960 x 32) + byte mux, as the port would use it.
module top (input wire clk_bridge, clk_soc, bridge_wr,
            input wire [15:0] bridge_waddr, input wire [31:0] bridge_wdata,
            input wire [17:0] vm_addr, output wire [7:0] vm_byte);
    wire [31:0] w;
    rom_bank #(.DEPTH(40960), .AW(16)) bank (
        .clk_bridge(clk_bridge), .bridge_wr(bridge_wr), .bridge_waddr(bridge_waddr),
        .bridge_wdata(bridge_wdata), .clk_soc(clk_soc), .vm_addr(vm_addr), .vm_rdata(w));
    assign vm_byte = w[8*vm_addr[1:0] +: 8];
endmodule
