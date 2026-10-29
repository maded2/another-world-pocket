// dbg_uart_tx.v - 8N1 UART transmitter for the debug console on dbg_tx.
//
// Sits in the design clock domain (clk_core, 24.75 MHz). Integer divisor only:
// 24_750_000 / 115_200 = 214.84 -> DIV 215 -> 115_116 baud, -0.07% error, far
// inside the +/-2% a UART receiver tolerates. No fractional logic: the line only
// carries human-readable log text and the reader is the host's CP210x bridge.
//
// Interface is a push FIFO so the console pump can hand over a whole short
// message without stalling mid-string; tx_ready backpressures when it fills.

module dbg_uart_tx #(
    parameter CLK_FREQ = 24_750_000,
    parameter BAUD     = 115_200,
    parameter DEPTH    = 16                  // bytes; power of two
)(
    input  wire        clk,
    input  wire        rst_n,                // active low
    input  wire [7:0]  tx_data,              // byte to push while tx_valid
    input  wire        tx_valid,
    output wire        tx_ready,             // FIFO has room for one more byte
    output wire        busy,                 // shifting or bytes queued - LED activity
    output reg         dbg_tx                 // idle high (mark)
);

localparam DIV = (CLK_FREQ + BAUD/2) / BAUD;  // nearest integer: 215 at the defaults
localparam AW  = $clog2(DEPTH);               // pointer width for the index part

// ---- byte FIFO ----------------------------------------------------------------
reg [7:0] mem [0:DEPTH-1];
reg [AW:0] wr, rd;                           // one extra bit to tell full from empty
wire [AW:0] wr_i = wr[AW-1:0], rd_i = rd[AW-1:0];

wire fifo_full  = (wr == {~rd[AW], rd[AW-1:0]});
wire fifo_empty = (wr == rd);

assign tx_ready = ~fifo_full;
assign busy     = shifting | ~fifo_empty;

// rd is driven by the shift engine below, including its reset value.
always @(posedge clk) begin
    if (!rst_n) begin
        wr <= {(AW+1){1'b0}};
    end else begin
        if (tx_valid && !fifo_full) begin
            mem[wr_i] <= tx_data;
            wr         <= wr + 1'b1;
        end
        // rd advances when the shift engine pops, below
    end
end

// ---- shift-out -----------------------------------------------------------------
// Frame layout in shreg: {stop, d7..d0, start}; bit 0 goes out first (start),
// then the byte LSB-first, then stop. 10 bits per frame at DIV clocks each.

reg [9:0] shreg;
reg [3:0] bitcnt;                            // 0..9 within a frame
reg [15:0] divcnt;
reg        shifting;

always @(posedge clk) begin
    if (!rst_n) begin
        dbg_tx   <= 1'b1;                     // mark
        rd       <= {(AW+1){1'b0}};
        shifting <= 1'b0;
        bitcnt   <= 4'd0;
        divcnt   <= 16'd0;
        shreg    <= 10'd0;
    end else if (shifting) begin
        if (divcnt == DIV - 1) begin
            divcnt <= 16'd0;
            dbg_tx <= shreg[1];               // next bit out
            shreg  <= {1'b1, shreg[9:1]};     // refill MSB with mark between bits
            if (bitcnt == 4'd9) begin
                shifting <= 1'b0;             // stop bit shifted out, frame done
            end else begin
                bitcnt <= bitcnt + 1'b1;
            end
        end else begin
            divcnt <= divcnt + 1'b1;
        end
    end else if (!fifo_empty) begin
        // pop a byte and start its frame: start bit out immediately
        rd     <= rd + 1'b1;
        shreg  <= {1'b1, mem[rd_i], 1'b0};
        bitcnt <= 4'd0;
        divcnt <= 16'd0;
        dbg_tx <= 1'b0;                       // start bit
        shifting <= 1'b1;
    end
end

endmodule
