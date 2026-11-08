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
// Reading walks the records ONE BYTE AT A TIME through a byte-wide port with one cycle of latency - the same
// port shape the sample fetch uses, so a single arbiter can serve both.
`timescale 1ns/1ps

module aw_audio_idx #(
    parameter [23:0] INDEX_OFF = 24'h001000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,          // pulse: resolve res_id
    input  wire [15:0] res_id,
    output reg         busy,
    output reg         found,          // 1 when the latched fields are valid
    output reg  [7:0]  r_type,         // 0 sound, 1 music
    output reg  [31:0] r_blob_off,
    output reg  [15:0] r_pcm_off, r_pcm_len, r_loop_start, r_loop_len,
    // byte read port: present an address, data arrives the NEXT cycle
    output reg  [23:0] rd_addr,
    input  wire [7:0]  rd_data
);
    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_CAP = 2'd2;

    reg [1:0]  st;
    reg [7:0]  count;
    reg [7:0]  k;            // record index
    reg [4:0]  bi;           // byte index within the record
    reg [7:0]  rec [0:15];
    reg [15:0] want;
    reg        count_ok;

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
            st <= S_IDLE; busy <= 1'b0; found <= 1'b0; count_ok <= 1'b0;
            k <= 8'd0; bi <= 5'd0; count <= 8'd0; rd_addr <= 24'd0;
        end else begin
            case (st)
            S_IDLE: if (start) begin
                        want     <= res_id;
                        busy     <= 1'b1;
                        found    <= 1'b0;
                        count_ok <= 1'b0;
                        k        <= 8'd0;
                        bi       <= 5'd0;
                        rd_addr  <= INDEX_OFF + 24'd1;      // the count byte
                        st       <= S_ADDR;
                    end
            S_ADDR: begin
                        st <= S_CAP;
                    end
            S_CAP: begin
                        if (!count_ok) begin
                            count    <= rd_data;
                            count_ok <= 1'b1;
                            bi       <= 5'd0;
                            rd_addr  <= INDEX_OFF + 24'd4 + {16'd0, k} * 24'd16;
                            st       <= S_ADDR;
                        end else if (bi == 5'd15) begin
                            rec[bi] <= rd_data;
                            // compare the res id (bytes 0,1) and finish this record either way
                            // bytes 0 and 1 are the res id and were captured in earlier cycles; rd_data here
                            // is byte 15. Comparing against rd_data was the first version's bug.
                            if ({rec[1], rec[0]} == want) begin
                                r_type       <= rec[2];
                                r_blob_off   <= f32(5'd4);
                                r_pcm_off    <= f16(5'd8);
                                r_pcm_len    <= f16(5'd10);
                                r_loop_start <= f16(5'd12);
                                r_loop_len   <= f16(5'd14);
                                found        <= 1'b1;
                                busy         <= 1'b0;
                                st           <= S_IDLE;
                            end else if (k + 8'd1 >= count) begin
                                busy <= 1'b0;                    // walked everything: not found
                                st   <= S_IDLE;
                            end else begin
                                k       <= k + 8'd1;
                                bi      <= 5'd0;
                                rd_addr <= INDEX_OFF + 24'd4 + ({16'd0, k} + 16'd1) * 24'd16;
                                st      <= S_ADDR;
                            end
                        end else begin
                            rec[bi] <= rd_data;
                            bi      <= bi + 5'd1;
                            rd_addr <= rd_addr + 24'd1;
                            st      <= S_ADDR;
                        end
                    end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
