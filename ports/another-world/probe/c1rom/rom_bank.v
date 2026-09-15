// C1 probe: the proposed Pocket ROM backend -- a RAM written from the APF
// bridge (32-bit words, clk_74a domain) and read by the a5k VM (SoC domain).
// The a5k VM's rom interface is byte-granular (mem_io: uint24 addr / uint8
// data), so the byte mux sits outside the RAM.
//
// Sizes are chosen against measured free block RAM on 5CEBA4F23C8:
//   3,153,920 total  -  1,024,000 (4 framebuffers, measured)
//                    -     44,384 (game arrays, measured from build.v)
//                    =  2,085,536 bits free (254 KB)

module rom_bank #(parameter DEPTH = 49152, parameter AW = 16) (
    // write side: APF bridge, synchronous to clk_74a
    input  wire        clk_bridge,
    input  wire        bridge_wr,
    input  wire [AW-1:0] bridge_waddr,            // 32-bit word address
    input  wire [31:0] bridge_wdata,
    // read side: VM instruction/data fetch, synchronous to clk_soc
    input  wire        clk_soc,
    input  wire [AW+1:0] vm_addr,                 // byte address
    output reg  [31:0] vm_rdata                   // word containing vm_addr
);
    reg [31:0] mem [0:DEPTH-1];

    always @(posedge clk_bridge)
        if (bridge_wr) mem[bridge_waddr] <= bridge_wdata;

    always @(posedge clk_soc)
        vm_rdata <= mem[vm_addr[AW+1:2]];
endmodule
