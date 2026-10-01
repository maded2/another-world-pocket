// -----------------------------------------------------------------------------
// Another World / Pocket - clock crossing FIFO.
//
// Gray-coded read/write pointers, with a registered read on the consumer side (so
// rd_q holds the byte pulled by the rd_en of the previous cycle; aw_rom presents
// it the cycle after, and the handshake it offers the VM has a cycle of slack in
// it by construction).
//
// Two extras beyond the usual full/empty:
//
//   wr_free   free slots as seen from the write side, conservative (never larger
//             than the truth) - aw_rom uses it to make sure a burst of bytes it is
//             about to fetch cannot overflow the far side
//   rd_level  entries as seen from the read side, conservative (never larger than
//             the truth) - aw_rom uses it to know when the last byte of a stream
//             has really been delivered before it drops `busy`
//
// Both are conservative because a synchronized pointer can only ever lag: the
// consumer may see fewer entries than there are, and the producer may see less
// free space than there is. Neither can be wrong in the direction that loses
// data.
//
// No flush input: clearing pointers across an asynchronous boundary needs both sides
// halted, and the one user that wanted it (restarting a byte stream) is better served
// by tagging entries with the transaction that fetched them - see aw_rom.

module aw_fifo #(
    parameter DW = 16,            // data width
    parameter AW = 6              // address bits, depth = 1 << AW
)(
    // write side
    input  wire          wr_clk,
    input  wire          wr_rst,
    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    output wire          wr_full,
    output wire [AW:0]   wr_free,

    // read side
    input  wire          rd_clk,
    input  wire          rd_rst,
    input  wire          rd_en,
    output reg  [DW-1:0] rd_q,
    output wire          rd_empty,
    output reg           rd_q_valid,  // 1 when rd_q holds a byte pulled this cycle
    output wire [AW:0]   rd_level
);

    localparam DEPTH = (1 << AW);

    reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wptr_bin, wptr_gray;
    reg  [AW:0] rptr_bin, rptr_gray;
    reg  [AW:0] wptr_sync1, wptr_sync2;   // write pointer, into the read domain
    reg  [AW:0] rptr_sync1, rptr_sync2;   // read pointer,  into the write domain

    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        reg [AW:0] b;
        begin
            b = g;
            for (i = AW - 1; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            gray2bin = b;
        end
    endfunction

    // ---------------------------------------------------------------- write side
    always @(posedge wr_clk) begin
        rptr_sync1 <= rptr_gray;      // consumer's pointer, 2FF into our domain
        rptr_sync2 <= rptr_sync1;
    end

    wire [AW:0] rptr_bin_w = gray2bin(rptr_sync2);
    wire [AW:0] used_w     = wptr_bin - rptr_bin_w;
    assign      wr_full    = (used_w == DEPTH[AW:0]);

    assign wr_free = DEPTH[AW:0] - used_w;

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wptr_bin  <= {(AW+1){1'b0}};
            wptr_gray <= {(AW+1){1'b0}};
        end else if (wr_en && !wr_full) begin
            mem[wptr_bin[AW-1:0]] <= wr_data;
            wptr_bin              <= wptr_bin + 1'b1;
            wptr_gray             <= bin2gray(wptr_bin + 1'b1);
        end
    end

    // ----------------------------------------------------------------- read side
    always @(posedge rd_clk) begin
        wptr_sync1 <= wptr_gray;
        wptr_sync2 <= wptr_sync1;
    end

    wire [AW:0] wptr_bin_r = gray2bin(wptr_sync2);
    wire [AW:0] used_r     = wptr_bin_r - rptr_bin;

    assign rd_empty = (used_r == {(AW+1){1'b0}});
    assign rd_level = used_r;

    wire rd_fire = rd_en && !rd_empty;

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rptr_bin   <= {(AW+1){1'b0}};
            rptr_gray  <= {(AW+1){1'b0}};
            rd_q       <= {DW{1'b0}};
            rd_q_valid <= 1'b0;
        end else begin
            rd_q_valid <= rd_fire;
            if (rd_fire) begin
                rd_q      <= mem[rptr_bin[AW-1:0]];
                rptr_bin  <= rptr_bin + 1'b1;
                rptr_gray <= bin2gray(rptr_bin + 1'b1);
            end
        end
    end

endmodule

`default_nettype wire
