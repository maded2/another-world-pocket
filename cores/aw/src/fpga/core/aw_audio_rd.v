// One byte at a time from the PSRAM (clk_psram) into the design clock (clk_core).
//
// This is the only thing that crosses between aw_mixer / aw_audio_idx (both clk_core, see the integration
// decision in docs/another-world/audio-plan.md) and aw_rom's audio port, which lives in clk_psram because that
// is the clock that owns the chip.
//
// PROTOCOL, caller side (the 4-phase half that the mixer and the index loader already speak):
//   * raise req with addr stable and hold both until valid;
//   * valid is a one-cycle pulse with data;
//   * drop req after seeing valid, and leave it low for at least one cycle before the next request.
// The shim enforces that last rule itself (C_GAP), because a caller that re-raises immediately would otherwise
// start a second transaction for the same address - the duplicate-capture bug the index loader hit.
//
// PROTOCOL, PSRAM side: a single `aud_req` pulse with `aud_addr` held for the whole transaction, and the byte
// arrives later as `aud_valid` + `aud_data`. That is exactly what aw_rom's audio port already does (latch a
// pending request, serve it when the sequencer is idle, return one byte), including the property that matters:
// a request is never lost, because aw_rom holds `aud_pend` until the port is free.
//
// WHY A TOGGLE AND NOT A LEVEL: the request crosses as a toggling bit sampled by two flops in the PSRAM domain.
// A level would need both sides to agree on when it went away, and the return path needs its own handshake
// anyway; a toggle is a single bit with no ordering question (the design's own CDC rule: single bit through a
// synchroniser, multi-bit only when the value is stable for the whole crossing - and `addr_r` is, because it is
// written before the toggle and not touched until the acknowledgement returns).
`timescale 1ns/1ps

module aw_audio_rd (
    // ---- caller side (clk_core) ----
    input  wire        clk_c,
    input  wire        rst_c,
    input  wire        req,
    input  wire [23:0] addr,
    output reg  [7:0]  data,
    output reg         valid,          // one clk_c cycle, data is the byte for the last request

    // ---- audio port of aw_rom (clk_psram) ----
    input  wire        clk_p,
    input  wire        rst_p,
    output reg         aud_req,        // one clk_p cycle
    output reg  [23:0] aud_addr,       // held for the whole transaction
    input  wire [7:0]  aud_data,
    input  wire        aud_valid       // one clk_p cycle
);

    // ------------------------------------------------------------------ caller side
    localparam [1:0] C_IDLE = 2'd0, C_LAUNCH = 2'd1, C_WAIT = 2'd2, C_GAP = 2'd3;

    reg [1:0]  cs;
    reg        req_t;                  // toggles once per transaction
    reg [23:0] addr_r;
    reg        ack_seen;
    reg [1:0]  ack_s;                  // acknowledgement toggle, synchronised into clk_c

    // PSRAM-side state, declared here because the caller-side block reads the returned byte and the
    // acknowledgement toggle: Verilog does not guarantee that a later declaration is visible earlier in the
    // file, and an implicit net here would silently be a 1-bit wire instead of the register.
    reg [2:0]  req_s;                  // request toggle, synchronised into clk_p
    reg        req_last;
    reg        busy;
    reg        ack_t;
    reg [7:0]  d_r;                    // the returned byte, stable until the next transaction
    reg [23:0] addr_s1, addr_s2;       // address, synchronised into clk_p

    always @(posedge clk_c) begin
        ack_s <= {ack_s[0], ack_t};
    end

    always @(posedge clk_c) begin
        if (rst_c) begin
            cs       <= C_IDLE;
            req_t    <= 1'b0;
            addr_r   <= 24'd0;
            ack_seen <= 1'b0;
            data     <= 8'd0;
            valid    <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (cs)
            C_IDLE:   if (req) begin
                          addr_r <= addr;
                          cs     <= C_LAUNCH;
                      end
            C_LAUNCH: begin
                          req_t <= ~req_t;
                          cs    <= C_WAIT;
                      end
            C_WAIT:   if (ack_s[1] != ack_seen) begin
                          ack_seen <= ack_s[1];
                          data     <= d_r;
                          valid    <= 1'b1;
                          cs       <= C_GAP;
                      end
            // The caller drops req in the cycle it sees valid; one gap cycle makes the next request
            // distinguishable from the one just answered.
            C_GAP:    if (!req) cs <= C_IDLE;
            default:  cs <= C_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ PSRAM side
    always @(posedge clk_p) begin
        if (rst_p) begin
            req_s    <= 3'd0;
            req_last <= 1'b0;
            busy     <= 1'b0;
            ack_t    <= 1'b0;
            aud_req  <= 1'b0;
            aud_addr <= 24'd0;
            d_r      <= 8'd0;
            addr_s1  <= 24'd0;
            addr_s2  <= 24'd0;
        end else begin
            req_s    <= {req_s[1:0], req_t};
            addr_s1  <= addr_r;
            addr_s2  <= addr_s1;
            aud_req  <= 1'b0;

            if (!busy && (req_s[2] != req_last)) begin
                // addr_r has been stable for at least three clk_p cycles by now (written before the toggle,
                // two flops deep), so the address captured here belongs to this transaction and no other.
                req_last <= req_s[2];
                aud_addr <= addr_s2;
                aud_req  <= 1'b1;
                busy     <= 1'b1;
            end else if (busy && aud_valid) begin
                d_r   <= aud_data;
                ack_t <= ~ack_t;
                busy  <= 1'b0;
            end
        end
    end

endmodule
