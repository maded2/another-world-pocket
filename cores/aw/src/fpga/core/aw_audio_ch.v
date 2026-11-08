// Turns the VM's op_playSound arguments into a mixer command.
//
// The chain is: VM issues {res, freq, vol, ch} -> this resolves `res` through aw_audio_idx -> the mixer gets
// {ch, freq, vol, len, loop_pos, loop_len, data_base}, where
//     data_base = AUDIO_BASE + blob_off + pcm_off
// i.e. the absolute image address of the first PCM byte. That is the whole "fetch": the mixer already
// addresses base + p1, so a separate fetch module would duplicate its adder.
//
// vol == 0 is a STOP and is issued immediately without a lookup - vm.cpp does the same, and the harvest showed
// 16 such events on all four channels inside the first seconds of the intro, so making them wait for a lookup
// would stall every stop behind an index walk.
`timescale 1ns/1ps

module aw_audio_ch (
    input  wire        clk,
    input  wire        rst,
    // Byte address of the audio section in the image being run. It is an INPUT, not a parameter: it is
    // frames_base + pool_bytes from the image's own header, read at boot by core_top. A bitstream that
    // carries the number baked in is a bitstream that only works with the one image it was built for -
    // measured: a 2-part probe image built for a test needed its own bitstream because the audio had moved
    // from 0x2F0000 to 0x118000, and a mismatch is indistinguishable from silence.
    input  wire [23:0] audio_base,
    // request from the VM (one pulse, arguments held)
    input  wire        play,
    input  wire [15:0] res,
    input  wire [5:0]  freq,
    input  wire [7:0]  vol,
    input  wire [1:0]  ch,
    // index resolver
    output reg         idx_start,
    output wire [15:0] idx_res,
    input  wire        idx_busy,
    input  wire        idx_found,
    input  wire [7:0]  idx_type,
    input  wire [31:0] idx_blob,
    input  wire [15:0] idx_poff, idx_plen, idx_ls, idx_ll,
    // mixer command
    output reg         cmd_valid,
    output reg  [1:0]  cmd_ch,
    output reg  [5:0]  cmd_freq,
    output reg  [7:0]  cmd_vol,
    output reg  [23:0] cmd_len, cmd_lp, cmd_ll, cmd_base
);
    assign idx_res = res;

    // Explicit states, because the first version was combinational-looking and wrong: after the lookup
    // finished, idx_found stayed high and idx_start stayed low, so the command re-issued EVERY cycle and
    // would have restarted the sound continuously. An issue-once state is not decoration here.
    // S_SEEN_BUSY exists because the resolver's `busy` is REGISTERED: one cycle after `start` it can still be
    // low, so a controller that went straight to "wait for !busy" concluded "not found" before the walk had
    // begun and issued a stop. Measured: both real plays came out as vol=0/base=0 - the unknown-id path -
    // while the two stop cases passed, which is exactly what that race looks like.
    localparam [2:0] S_IDLE = 3'd0, S_REQ = 3'd1, S_SEEN = 3'd2, S_WAIT = 3'd3, S_ISSUE = 3'd4;

    reg [2:0]  st;
    reg        stop_req;      // this request is a stop (vol == 0), so no lookup

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; idx_start <= 1'b0; cmd_valid <= 1'b0; stop_req <= 1'b0;
            cmd_ch <= 2'd0; cmd_freq <= 6'd0; cmd_vol <= 8'd0;
            cmd_len <= 24'd0; cmd_lp <= 24'd0; cmd_ll <= 24'd0; cmd_base <= 24'd0;
        end else begin
            cmd_valid <= 1'b0;
            case (st)
            S_IDLE: begin
                idx_start <= 1'b0;
                if (play) begin
                    // arguments are latched once, here, so nothing downstream depends on how long the host
                    // holds them
                    cmd_ch     <= ch;
                    cmd_freq   <= freq;
                    cmd_vol    <= vol;
                    stop_req   <= (vol == 8'd0);
                    if (vol == 8'd0) begin
                        cmd_len  <= 24'd0;
                        cmd_lp   <= 24'd0;
                        cmd_ll   <= 24'd0;
                        cmd_base <= 24'd0;
                        st       <= S_ISSUE;      // a stop needs no lookup
                    end else begin
                        idx_start <= 1'b1;
                        st        <= S_REQ;
                    end
                end
            end
            S_REQ: begin
                idx_start <= 1'b0;
                st        <= S_SEEN;
            end
            S_SEEN: if (idx_busy) st <= S_WAIT;      // the walk has actually started
            S_WAIT: begin
                if (!idx_busy) begin
                    if (idx_found) begin
                        cmd_len  <= {8'd0, idx_plen};
                        cmd_lp   <= {8'd0, idx_ls};
                        cmd_ll   <= {8'd0, idx_ll};
                        cmd_base <= audio_base + idx_blob[23:0] + {16'd0, idx_poff};
                    end else begin
                        cmd_len  <= 24'd0;        // unknown id: issue nothing useful, but do not hang
                        cmd_lp   <= 24'd0;
                        cmd_ll   <= 24'd0;
                        cmd_base <= 24'd0;
                        cmd_vol  <= 8'd0;         // treat as a stop rather than playing whatever is at base 0
                    end
                    st <= S_ISSUE;
                end
            end
            S_ISSUE: begin
                cmd_valid <= 1'b1;
                st        <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
