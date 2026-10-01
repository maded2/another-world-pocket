`ifndef TRACE_LEFT
`define TRACE_LEFT 0   // +define+TRACE_LEFT=24 to watch the chip accesses
`endif
// -----------------------------------------------------------------------------
// Behavioural model of one Pocket cellular PSRAM chip (ZBT SRAM), for simulation.
//
// Not part of the core: nothing here goes into the bitstream. It exists so the RTL
// can be run against something that behaves like the part - in particular the two
// things a controller can get wrong:
//
//   * the address arrives on the data bus behind ADV#, on the SAME bus the data
//     later arrives on, so a controller that drives them in the wrong order sees
//     its own address as data;
//   * the read result appears after the ADV-capturing edge and must be sampled on
//     the following edge, one full cycle after the address was taken.
//
// 4 MiWords x 16 = 8 MB, which is one chip (two dies behind CE0#/CE1#, address bit
// 21 selecting between them).
//
// Run with:  scripts/sim_rom.sh          (see cores/aw/src/sim/)
// -----------------------------------------------------------------------------
`timescale 1ns/10ps

module aw_psram_model (
    input  wire        clk,
    input  wire [5:0]  a,
    inout  wire [15:0] dq,
    input  wire        adv_n,
    input  wire        cre,
    input  wire        ce0_n,
    input  wire        ce1_n,
    input  wire        oe_n,
    input  wire        we_n,
    input  wire        ub_n,
    input  wire        lb_n,
    output reg         wait_hi     // active-high stall, matches aw_psram
);

    localparam WORDS = 1 << 22;         // 4M words = 8 MB

    reg [15:0] mem [0:WORDS-1];
    reg [21:0] addr;
    // The part drives the bus only while OE# is low. Gating the driver combinationally
    // on OE# rather than registering it matters: at the ADV edge the part cannot know
    // yet whether the following cycle is the read or the write half of the access, and
    // a model that starts driving anyway fights the controller for the bus during every
    // write - which reads back as garbage data on a write that otherwise looks fine.
    reg         read_pending;
    reg  [15:0] read_data;

    assign dq = (read_pending && ~oe_n) ? read_data : 16'hzzzz;

    // The first `TRACE_LEFT chip accesses are printed, which is how the write path is
    // this file found a controller that read correctly and wrote nothing, and nothing
    // downstream can tell "the address is wrong" apart from "the write never
    // diagnosed at all: compile with +define+TRACE_LEFT=24 to see them. Nothing
    // downstream can tell "the address is wrong" apart from "the write never happened" -
    // a controller that writes nothing can still read back exactly what it expects.
    integer trace_left = `TRACE_LEFT;
    always @(posedge clk) begin
        if (trace_left > 0) begin
            if (~adv_n && (~ce0_n || ~ce1_n)) begin
                $display("  psram ADV addr=%0h ce0=%b ce1=%b",
                         {~ce0_n, a[4:0], dq}, ce0_n, ce1_n);
                trace_left = trace_left - 1;
            end else if (~ce0_n || ~ce1_n) begin
                $display("  psram DATA addr=%0h dq=%0h we_n=%b oe_n=%b lb=%b ub=%b",
                         addr, dq, we_n, oe_n, lb_n, ub_n);
                trace_left = trace_left - 1;
            end
        end

        if (~ce0_n || ~ce1_n) begin
            if (~adv_n) begin
                // address multiplexed on the data bus, captured on this edge; the
                // die bit comes from the chip select that is asserted
                addr         <= {~ce0_n, a[4:0], dq};
                read_data    <= mem[{~ce0_n, a[4:0], dq}];
                read_pending <= 1'b1;
            end else begin
                if (~we_n) begin
                    if (~lb_n) mem[addr][7:0]  <= dq[7:0];
                    if (~ub_n) mem[addr][15:8] <= dq[15:8];
                end
                // the result is on the bus during this cycle and no longer after it
                read_pending <= 1'b0;
            end
        end else begin
            read_pending <= 1'b0;
        end
    end

    // start in a known-but-clearly-not-a-pack state, so that a core which reads
    // before loading shows up as a trailer failure rather than looking correct
    initial begin : fill
        integer i;
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'h5A5A;
    end

endmodule
