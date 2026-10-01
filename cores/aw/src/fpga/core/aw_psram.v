// -----------------------------------------------------------------------------
// Another World / Pocket - controller for one cellular PSRAM chip (cram0).
//
// The Pocket's cellular RAM is plain synchronous ZBT SRAM: 16 bits wide, address
// multiplexed onto the data bus behind ADV#, one access every two clock cycles, no
// refresh and no init sequence. Two dies per chip selected by CE0#/CE1#, so the
// top address bit is die select - which is how 21 x 16-bit words become the 8 MB
// a pack needs.
//
// Timing (all chip outputs are registered one cycle before they are needed, which
// is what keeps this clean at 49.5 MHz):
//
//   cycle N   ADV#=0, CE#=0, dq = address[15:0],  a = address[21:16]
//   cycle N+1 ADV#=1, OE#=0 (read, dq tri-stated) or WE#=0 (write, dq = data)
//
// Requests are a level with stable data, accepted on a cycle where the matching
// *_ready is high. ready stays asserted through the data phase of the access in
// progress, so a requester that holds its request up is served back to back at a
// sustained one word per two cycles instead of one per three.
//
// Writes win over reads: a write seen on the bridge cannot be retried by anyone,
// while a read can always be issued a cycle later.
//
// WAIT is honoured (the access is stretched while it is asserted). The Pocket calls
// this pin cram0_wait, with no bar, and nothing in the APF template uses it, so
// neither its polarity nor whether the fitted part drives it is established anywhere
// in what is available here. Two things follow. It is treated as active high, which
// is what the name says. And stall_wait below counts a wait that never lets go, so
// that a wrong assumption about this pin shows up as a reported error instead of a
// design that quietly sits there with a blank screen - the failure a reader of this
// file would otherwise find hardest to diagnose.
//
// Writes take a 2-bit mask (bit1 = upper byte / UB#, bit0 = lower byte / LB#), so
// a byte that does not land on an even address is written without read-modify-write.
//
// rd_tag is stored with the access at the cycle it is taken and returned with the
// data, rather than counted in cycles by the requester. The requester uses it to
// remember which address a returned word came from, and WAIT# can stretch an access by
// an arbitrary number of cycles: a fixed pipeline depth there would mislabel a word
// exactly when the memory misbehaved, which is the one time the label matters. It costs
// twenty flip-flops, and aw_rom needs the address anyway - see the reader in aw_rom for
// why a word's address is a better label than a counter of who asked for it.
// -----------------------------------------------------------------------------
`default_nettype none

module aw_psram (
    input  wire             clk,        // 49.5 MHz
    input  wire             rst,

    // write request
    input  wire             wr_req,
    input  wire [21:0]      wr_addr,    // word address, bit 21 = die select
    input  wire [15:0]      wr_data,
    input  wire [1:0]       wr_be,      // 1 = that lane is written; 2'b11 = whole word
    output wire             wr_ready,

    // read request
    input  wire             rd_req,
    input  wire [21:0]      rd_addr,
    input  wire [20:0]      rd_tag,     // travels with this access, see below
    output wire             rd_ready,
    output reg  [15:0]      rd_q,
    output reg              rd_q_valid, // one cycle, in step with rd_q
    output reg  [20:0]      rd_tag_q,   // the tag of the word on rd_q

    input  wire             psram_wait,
    output reg              stall_wait,     // WAIT has been asserted for ~2^16 cycles

    // chip pins
    output reg  [5:0]       psram_a,
    inout  wire [15:0]      psram_dq,
    output reg              psram_adv_n,
    output reg              psram_cre,
    output reg              psram_ce0_n,
    output reg              psram_ce1_n,
    output reg              psram_oe_n,
    output reg              psram_we_n,
    output reg              psram_ub_n,
    output reg              psram_lb_n,
    output wire             psram_clk
);

    localparam S_IDLE = 2'd0,
               S_ADDR = 2'd1,
               S_DATA = 2'd2;

    reg [1:0]  state;
    reg [15:0] wdata;
    reg [1:0]  be;
    reg        is_write;
    reg [20:0] tag_cur;   // tag of the access in progress
    reg [15:0] wait_cnt;  // consecutive cycles WAIT has been high

    // A new access can start from idle or out of the data phase of the current
    // one; either way the next ADV cycle goes out on the very next clock.
    wire can_start = (state == S_IDLE) || ((state == S_DATA) && !psram_wait);
    assign wr_ready = can_start;
    assign rd_ready = can_start && !wr_req;

    wire take_wr = wr_req &&  wr_ready;
    wire take_rd = rd_req &&  rd_ready;
    wire take    = take_wr | take_rd;
    wire [21:0] req_addr = take_wr ? wr_addr : rd_addr;

    // the data bus carries the address during the ADV cycle and write data during
    // the write cycle; tri-stated otherwise so the part can drive a read result
    reg        dq_drive;
    reg [15:0] dq_out;

    assign psram_dq  = dq_drive ? dq_out : 16'hzzzz;
    assign psram_clk = clk;

    always @(posedge clk) begin
        rd_q_valid <= 1'b0;
        psram_cre  <= 1'b0;         // this is the "clock rate" option; keep it low

        if (rst) begin
            state       <= S_IDLE;
            dq_drive    <= 1'b0;
            rd_q_valid  <= 1'b0;
            rd_tag_q    <= 21'd0;
            tag_cur     <= 21'd0;
            stall_wait  <= 1'b0;
            wait_cnt    <= 16'd0;
            psram_adv_n <= 1'b1;
            psram_oe_n  <= 1'b1;
            psram_we_n  <= 1'b1;
            psram_ce0_n <= 1'b1;
            psram_ce1_n <= 1'b1;
            psram_ub_n  <= 1'b1;
            psram_lb_n  <= 1'b1;
            psram_a     <= 6'd0;
        end else begin
            // A wait that outlasts any real part is a wrong assumption, not a
            // slowdown: say so once, and keep the count honest by resetting on release.
            if (psram_wait) begin
                if (&wait_cnt) stall_wait <= 1'b1;
                else           wait_cnt   <= wait_cnt + 16'd1;
            end else begin
                wait_cnt   <= 16'd0;
                stall_wait <= 1'b0;
            end

            case (state)
            // ------------------------------------------------------------------
            // Nothing on the bus. An accepted request sets up the ADV cycle here,
            // so that during S_ADDR the address and chip select are already out.
            S_IDLE: begin
                psram_adv_n <= 1'b1;
                psram_oe_n  <= 1'b1;
                psram_we_n  <= 1'b1;
                dq_drive    <= 1'b0;
                if (take) begin
                    wdata     <= wr_data;
                    be        <= wr_be;
                    is_write  <= take_wr;
                    tag_cur   <= rd_tag;
                    psram_a     <= {1'b0, req_addr[20:16]};
                    psram_ce0_n <= ~req_addr[21];
                    psram_ce1_n <=  req_addr[21];
                    dq_out      <= req_addr[15:0];
                    dq_drive    <= 1'b1;
                    psram_adv_n <= 1'b0;
                    state       <= S_ADDR;
                end
            end

            // ------------------------------------------------------------------
            // ADV cycle: the address is on the bus. Now set up the data phase.
            //
            // Two things here were wrong in the first version, and neither one shows up
            // as a compile error or a failing read:
            //
            //   * ADV# stayed low through the data phase. A ZBT part samples ADV# on
            //     every rising edge, so an ADV# still low while write data is on the
            //     bus makes the part take that data as another address and write
            //     nothing. The design then reads back exactly what it expects (reads are
            //     unaffected), the boot check passes, and not one byte of the pack ever
            //     lands in the memory.
            //   * we_n and oe_n were both set from ~is_write, which asserts write enable
            //     on every read, output enable on every write, and leaves both asserted
            //     at once - so the part and the controller drive the bus together during
            //     every write while neither of them writes.
            //
            // Both are invisible until something actually writes and then reads back the
            // chip, which is what tb_rom does.
            S_ADDR: begin
                if (psram_wait) begin
                    psram_adv_n <= 1'b0;         // hold the address up one more cycle
                end else begin
                    psram_adv_n <= 1'b1;         // high for the data phase
                    dq_out     <= wdata;
                    dq_drive   <= is_write;      // only a write drives the bus
                    psram_we_n <= ~is_write;     // low during a write
                    psram_oe_n <=  is_write;     // low during a read - the opposite
                                                 // sense: with both from ~is_write the
                                                 // part drives the bus against the
                                                 // controller on every write
                    psram_ub_n <= ~be[1];
                    psram_lb_n <= ~be[0];
                    state      <= S_DATA;
                end
            end

            // ------------------------------------------------------------------
            // Data phase. Reads sample the bus here: the part drove it tCO after
            // the edge that latched the address, so a whole 20 ns period has gone
            // by. Then either chain straight into the next access or go idle.
            S_DATA: begin
                psram_adv_n <= 1'b1;
                psram_we_n  <= 1'b1;
                psram_oe_n  <= 1'b1;
                dq_drive    <= 1'b0;
                if (!is_write) begin
                    rd_q       <= psram_dq;
                    rd_q_valid <= 1'b1;
                    rd_tag_q   <= tag_cur;
                end
                if (!psram_wait) begin
                    if (take) begin
                        wdata       <= wr_data;
                        be          <= wr_be;
                        is_write    <= take_wr;
                        tag_cur     <= rd_tag;
                        psram_a     <= {1'b0, req_addr[20:16]};
                        psram_ce0_n <= ~req_addr[21];
                        psram_ce1_n <=  req_addr[21];
                        dq_out      <= req_addr[15:0];
                        dq_drive    <= 1'b1;
                        psram_adv_n <= 1'b0;
                        state       <= S_ADDR;
                    end else begin
                        state <= S_IDLE;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
