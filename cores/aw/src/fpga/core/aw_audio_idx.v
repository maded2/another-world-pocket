// Resolve a sound/music resource id to where its bytes live in the image.
//
// The index is at a FIXED directory-page offset (0x1000) with a fixed record layout, so this module needs to
// know nothing about how many parts or frames the image holds:
//   +0x1000: u8 tag 0x41 ('A'), u8 count, u16 reserved
//   +0x1004 + k*16, count records of 16 bytes: <HBBIHHHH>
//     res u16 | type u8 (0 sound, 1 music) | flags u8 | blob_off u32 |
//     pcm_off u16 | pcm_len u16 | loop_start u16 | loop_len u16
//
// blob_off is the resource's offset in the audio blob and pcm_off is the offset WITHIN that resource (8 for a
// sound, 0 for a module), so the absolute byte address of sample position p is
//   AUDIO_BASE + blob_off + pcm_off + p
// where AUDIO_BASE is the audio section's start in the image. That split is why the record carries both.
//
// THE INDEX IS COPIED OUT OF THE IMAGE ONCE, AT BOOT, INTO A LOCAL RAM (2 x M10K, 2048 x 8).
//
// The first version walked the image one byte at a time on EVERY lookup through the same byte port the mixer
// used. Measured cost of that: up to 1 + 106*16 = 1697 byte reads for the last record, and each read in the
// field is a full PSRAM round trip through a clock-domain handshake (~24 clk_core), so a lookup could take
// ~40,000 clk_core = 1.6 ms. At 48 kHz that is ~78 dropped mixer ticks per play, on a channel that may be
// playing music, and it made the index compete with the sample fetch for the one PSRAM port.
//
// Loading it once costs 4 + count*16 byte reads at boot (measured in the bench: see tb_audio_idx), after which
// a lookup is a local-memory scan with no PSRAM traffic at all. This is what docs/another-world/audio-plan.md
// phase C specified ("a small index RAM loaded at boot"); the walk was the implementation drifting from it.
`timescale 1ns/1ps

module aw_audio_idx #(
    parameter [23:0] INDEX_OFF = 24'h001000,
    parameter integer DEPTH    = 2048      // bytes of local index RAM
) (
    input  wire        clk,
    input  wire        rst,

    // ---- loader: pull the index region out of the image once, through a byte port ----
    input  wire        load_start,
    output reg         load_busy,
    output reg         load_done,
    output reg  [23:0] ldr_addr,
    output reg         ldr_req,        // held until ldr_valid
    input  wire        ldr_valid,
    input  wire [7:0]  ldr_data,

    // ---- lookup ----
    input  wire        start,          // pulse: resolve res_id
    input  wire [15:0] res_id,
    output reg         busy,
    output reg         found,          // 1 when the latched fields are valid
    output reg  [7:0]  r_type,         // 0 sound, 1 music
    output reg  [31:0] r_blob_off,
    output reg  [15:0] r_pcm_off, r_pcm_len, r_loop_start, r_loop_len
);

    reg [7:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------------ loader
    // A 4-phase handshake per byte: raise req with a stable address, wait for valid, drop req, advance. The
    // first version kept req high across bytes and incremented the address in the same cycle it captured;
    // the responder could then capture the OLD address a second time (measured in tb_audio_idx: mem[1] held
    // the tag again). `req` must go low between transactions for the responder to have an edge to act on.
    localparam [2:0] L_IDLE = 3'd0, L_REQ = 3'd1, L_WAIT = 3'd2,
                     L_NEXT = 3'd3, L_FIN  = 3'd4;
    reg [2:0]  lst;
    reg [11:0] n;                  // byte index within the current phase
    reg [11:0] need;               // count * 16, the record region's size
    reg [23:0] taddr;              // address for the next transaction
    reg        in_rec;             // 0 = header (4 bytes), 1 = records
    reg  [7:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            lst       <= L_IDLE;
            ldr_req   <= 1'b0;
            ldr_addr  <= INDEX_OFF;
            load_busy <= 1'b0;
            load_done <= 1'b0;
            n         <= 12'd0;
            need      <= 12'd0;
            taddr     <= INDEX_OFF;
            in_rec    <= 1'b0;
            cnt       <= 8'd0;
        end else begin
            case (lst)
            L_IDLE: if (load_start && !load_done) begin
                        load_busy <= 1'b1;
                        n         <= 12'd0;
                        taddr     <= INDEX_OFF;
                        in_rec    <= 1'b0;
                        lst       <= L_REQ;
                    end
            L_REQ: begin
                        ldr_addr <= taddr;
                        ldr_req  <= 1'b1;
                        lst      <= L_WAIT;
                    end
            L_WAIT: if (ldr_valid) begin
                        ldr_req <= 1'b0;
                        if (in_rec) mem[12'd4 + n] <= ldr_data;
                        else        mem[n]         <= ldr_data;
                        if (!in_rec && n == 12'd1) cnt <= ldr_data;
                        lst <= L_NEXT;
                    end
            // Clamp to the RAM: a count that does not fit is a layout error, and copying past the end of an
            // inferred RAM is how a "works in simulation" design corrupts itself. 127 records fit exactly.
            L_NEXT: begin
                        if (!in_rec) begin
                            if (n == 12'd3) begin
                                need  <= ({4'd0, cnt} * 12'd16 > (DEPTH - 4)) ? (DEPTH - 4)
                                                                              : ({4'd0, cnt} * 12'd16);
                                in_rec <= 1'b1;
                                n      <= 12'd0;
                                taddr  <= INDEX_OFF + 24'd4;
                                lst    <= L_REQ;
                            end else begin
                                n     <= n + 12'd1;
                                taddr <= taddr + 24'd1;
                                lst   <= L_REQ;
                            end
                        end else if (n + 12'd1 >= need) begin
                            lst <= L_FIN;
                        end else begin
                            n     <= n + 12'd1;
                            taddr <= taddr + 24'd1;
                            lst   <= L_REQ;
                        end
                    end
            L_FIN: begin
                        load_busy <= 1'b0;
                        load_done <= 1'b1;
                        lst       <= L_IDLE;
                    end
            default: lst <= L_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ lookup
    // The scan is one record at a time in local memory: 16 captures plus the compare, ~17 clk per record, so
    // the worst case (the last of 106 records) is ~1800 clk = 73 us - and no PSRAM traffic.
    localparam [1:0] S_IDLE = 2'd0, S_CAP = 2'd1, S_LATCH = 2'd2;

    reg [1:0]  st;
    reg [7:0]  count;
    reg [7:0]  k;            // record index
    reg [4:0]  bi;           // byte index within the record
    reg [11:0] a;            // byte index into mem: 4 + k*16 + bi
    reg [7:0]  rec [0:15];
    reg [15:0] want;

    integer i;

    // assemble a little-endian field from the captured record bytes
    function [15:0] f16(input [4:0] o);
        f16 = {rec[o+1], rec[o]};
    endfunction
    function [31:0] f32(input [4:0] o);
        f32 = {rec[o+3], rec[o+2], rec[o+1], rec[o]};
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; found <= 1'b0;
            k <= 8'd0; bi <= 5'd0; count <= 8'd0; a <= 12'd0;
        end else begin
            case (st)
            S_IDLE: if (start) begin
                        want  <= res_id;
                        found <= 1'b0;
                        if (!load_done) begin
                            // The index is not resident yet: report not-found rather than scanning garbage.
                            // core_top does not issue a play before boot completes, so this is a guard - and it
                            // still raises `busy` for a cycle so the controller's S_SEEN state sees the walk
                            // start, exactly as a real lookup does. A lookup that answers "not found" with no
                            // busy at all is the race that made every real play come out as a stop.
                            busy  <= 1'b1;
                            count <= 8'd0;
                            k     <= 8'd0;
                            st    <= S_LATCH;
                        end else begin
                            busy  <= 1'b1;
                            count <= mem[8'd1];
                            k     <= 8'd0;
                            bi    <= 5'd0;
                            a     <= 12'd4;
                            st    <= S_CAP;
                        end
                    end
            S_CAP: begin
                        rec[bi] <= mem[a];
                        if (bi == 5'd15) begin
                            st <= S_LATCH;
                        end else begin
                            bi <= bi + 5'd1;
                            a  <= a + 12'd1;
                        end
                    end
            S_LATCH: begin
                        if (count != 8'd0 && {rec[1], rec[0]} == want) begin
                            r_type       <= rec[2];
                            r_blob_off   <= f32(5'd4);
                            r_pcm_off    <= f16(5'd8);
                            r_pcm_len    <= f16(5'd10);
                            r_loop_start <= f16(5'd12);
                            r_loop_len   <= f16(5'd14);
                            found        <= 1'b1;
                            busy         <= 1'b0;
                            st           <= S_IDLE;
                        end else if (count == 8'd0 || (k + 8'd1 >= count)) begin
                            busy  <= 1'b0;                  // walked everything: not found
                            found <= 1'b0;
                            st    <= S_IDLE;
                        end else begin
                            k     <= k + 8'd1;
                            bi    <= 5'd0;
                            a     <= a + 12'd1;             // a is at base+15; next base is +16
                            st    <= S_CAP;
                        end
                    end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
