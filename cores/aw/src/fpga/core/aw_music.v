// STATUS: WORK IN PROGRESS - NOT INSTANTIATED ANYWHERE, AND ITS BENCH FAILS.
//
// The structure is here (divider, index scan, burst reader, row decode, command issue) and the oracle it is
// graded against (scripts/ref_tracker.py) is complete and self-checking. The bench tb_music does not pass
// yet: the command stream diverges from the oracle from the second command onwards, and the row/order state
// is wrong at the first row, which points at the pattern fetch or the row address rather than at the decode.
// It is deliberately NOT in aw.qsf and NOT instantiated in core_top, so it cannot affect the shipping build.
// Debugging notes are in task #14 (the last measurement: instrument slots resolved to the module's own record
// and rows 1.. were decoded from the wrong addresses).
//
// Another World music player: the tracker, in RTL.
//
// The oracle is scripts/ref_tracker.py, a transcription of upstream sfxplayer.cpp. The RTL is graded
// event-for-event against it first (a wrong tempo shows as an off-by-one tick, not as noise) and then
// sample-for-sample through the same mixer the sound effects use.
//
// THE FORMAT (big-endian; ref_tracker.py has the annotated map):
//   +0x00 u16 delay | +0x02 15 x {u16 res, u16 volume} | +0x3E u16 numOrder | +0x40 0x80 order table
//   +0xC0 pattern data: order*1024 + row*16, four 4-byte channel events per row
// An event is {u16 note_1, u16 note_2}: 0xFFFD marker, 0xFFFE stop, 0 = no note, otherwise an Amiga period
// (freq = 7159092/(period*2)); note_2 bits 12-15 sample 1..15, bits 8-11 effect (5 up, 6 down), 0-7 parameter.
//
// THE INSTRUMENT TABLE IS BORROWED FROM THE IMAGE, NOT THE PACK. Each instrument names a SOUND resource, and
// the index RAM (aw_audio_idx) already holds exactly what playback needs: pcm address, sample length and
// loop. It is read through the dedicated scan port rather than the single-request resolver, so a sound effect
// and a module load cannot collide.
//
// TWO DIVERGENCES, both documented:
//   * the 0xFFFD marker writes _scriptVars[0xF4] in the original - VM state, not audio. It is surfaced as a
//     one-cycle pulse and nothing consumes it yet.
//   * prepareInstruments blanks four bytes at data+8 on the shared resource buffer. Reproducing that means
//     writing to PSRAM or masking the first four samples of every music note in the mixer; the oracle has
//     --no-memset for exact comparison, and the divergence is four samples per note.
`timescale 1ns/1ps

module aw_music #(
    parameter integer CLK_HZ = 24_750_000,
    parameter integer MS_CYCLES = CLK_HZ / 1000
) (
    input  wire        clk,
    input  wire        rst,
    // Byte address of the audio section, read from the image header at boot by core_top - the same input
    // aw_audio_ch takes, and for the same reason: a bitstream that carries the number only works with the
    // image it was built for, and a mismatch is indistinguishable from silence.
    input  wire [23:0] audio_base,

    // op_playMusic: num = resource id, delay = tick override (0 = module header), pos = start order
    input  wire        play,
    input  wire [15:0] num,
    input  wire [15:0] delay,
    input  wire [7:0]  pos,

    // index RAM read port
    output reg  [11:0] scan_addr,
    input  wire [7:0]  scan_q,

    // PSRAM byte reader (4-phase; shared through the arbiter in core_top)
    output reg  [23:0] rd_addr,
    output reg         rd_req,
    input  wire        rd_valid,
    input  wire [7:0]  rd_data,

    // mixer command
    output reg         cmd_valid,
    output reg         cmd_stop,
    output reg         cmd_touch,
    output reg         cmd_use_inc,
    output reg  [8:0]  cmd_inc,
    output reg  [1:0]  cmd_ch,
    output reg  [7:0]  cmd_vol,
    output reg  [23:0] cmd_len, cmd_lp, cmd_ll, cmd_base,
    output reg  [5:0]  cmd_freq,

    output reg         row_valid,      // one cycle per pattern row fetched: the tracker's own progress
    output reg         marker_valid,
    output reg  [15:0] marker_value,
    output reg  [1:0]  marker_ch,
    output wire        running
);

    // ================================================================== divider
    // Three divisions exist: delay*60/7050 at module load, and per note 7159092/(period*2) then
    // (freq<<8)/48000. A 24-step restoring divide, with a one-cycle done pulse.
    reg  [31:0] dv_num;
    reg  [15:0] dv_den;
    reg  [31:0] dv_quo, dv_rem, dv_q;
    reg  [5:0]  dv_i;
    reg         dv_go, dv_busy, dv_done;

    always @(posedge clk) begin
        if (rst) begin
            dv_busy <= 1'b0; dv_done <= 1'b0; dv_quo <= 32'd0; dv_rem <= 32'd0;
            dv_q <= 32'd0; dv_i <= 6'd0;
        end else begin
            dv_done <= 1'b0;
            if (dv_go) begin
                dv_busy <= 1'b1;
                dv_rem  <= 32'd0;
                dv_quo  <= 32'd0;
                dv_i    <= 6'd24;
            end else if (dv_busy) begin
                if (dv_i == 6'd0) begin
                    dv_busy <= 1'b0;
                    dv_done <= 1'b1;
                    dv_q    <= dv_quo;
                end else begin
                    dv_i <= dv_i - 6'd1;
                    if ({dv_rem[30:0], dv_num[dv_i - 6'd1]} >= {16'd0, dv_den}) begin
                        dv_rem <= {dv_rem[30:0], dv_num[dv_i - 6'd1]} - {16'd0, dv_den};
                        dv_quo <= {dv_quo[30:0], 1'b1};
                    end else begin
                        dv_rem <= {dv_rem[30:0], dv_num[dv_i - 6'd1]};
                        dv_quo <= {dv_quo[30:0], 1'b0};
                    end
                end
            end
        end
    end

    // ================================================================== index scan
    // The RAM port is REGISTERED: an address presented in cycle T is in scan_q in cycle T+2 (one flop for the
    // port, one for the RAM). Every byte is therefore ISSUE -> WAIT -> ACT, and the first version - which
    // assumed T+1 - read every field one byte early and therefore matched nothing (measured: record 0's res
    // came back as {mem[4], mem[1]}).
    localparam [1:0] SC_IDLE = 2'd0, SC_RD1 = 2'd1, SC_RD2 = 2'd2, SC_ACT = 2'd3;
    reg [1:0]  sc;
    reg [1:0]  sc_p;               // what the byte in flight is for: 0 count, 1 b0, 2 b1, 3 record
    reg [11:0] sc_a;
    reg [7:0]  sc_k, sc_cnt, sc_b0;
    reg [15:0] sc_target;
    reg        sc_go, sc_ack, sc_done, sc_found, sc_abort;
    reg [7:0]  sc_rec [0:15];
    reg [4:0]  sc_i;
    reg [31:0] sc_blob;
    reg [15:0] sc_poff, sc_plen, sc_ls, sc_ll;
    reg        sc_fin;

    always @(posedge clk) begin
        if (rst) begin
            sc <= SC_IDLE; sc_done <= 1'b0; sc_found <= 1'b0; sc_fin <= 1'b0;
            sc_a <= 12'd0; sc_k <= 8'd0; sc_cnt <= 8'd0; sc_i <= 5'd0; sc_p <= 2'd0;
            scan_addr <= 12'd0;
        end else begin
            if (sc_abort) begin
                sc      <= SC_IDLE;
                sc_done <= 1'b0;
            end else case (sc)
            SC_IDLE: if (sc_ack) begin
                         sc_done <= 1'b0;              // the consumer has taken the result
                     end else if (sc_go) begin
                         sc_done  <= 1'b0;
                         sc_found <= 1'b0;
                         sc_fin   <= 1'b0;
                         sc_a     <= 12'd1;
                         sc_p     <= 2'd0;
                         sc       <= SC_RD1;
                     end
            SC_RD1: begin
                         scan_addr <= sc_a;
                         sc_a      <= sc_a + 12'd1;
                         sc        <= SC_RD2;
                     end
            SC_RD2: sc <= SC_ACT;
            SC_ACT: case (sc_p)
                    2'd0: begin
                              sc_cnt <= scan_q;
                              sc_k   <= 8'd0;
                              sc_a   <= 12'd4;
                              sc_p   <= 2'd1;
                              sc     <= SC_RD1;
                          end
                    2'd1: begin
                              sc_b0 <= scan_q;
                              sc_p  <= 2'd2;
                              sc    <= SC_RD1;
                          end
                    2'd2: begin
                              if ({scan_q, sc_b0} == sc_target) begin
                                  sc_a <= sc_a - 12'd2;      // back to this record's first byte
                                  sc_i <= 5'd0;
                                  sc_p <= 2'd3;
                                  sc   <= SC_RD1;
                              end else if (sc_k + 8'd1 >= sc_cnt) begin
                                  sc_found <= 1'b0;
                                  sc_done  <= 1'b1;
                                  sc       <= SC_IDLE;
                              end else begin
                                  sc_k <= sc_k + 8'd1;
                                  sc_a <= sc_a + 12'd14;     // base+2 -> next base
                                  sc_p <= 2'd1;
                                  sc   <= SC_RD1;
                              end
                          end
                    default: begin
                              sc_rec[sc_i] <= scan_q;
                              if (sc_i == 5'd15) begin
                                  // the last byte is written at this edge, so the last field reads the port
                                  sc_blob  <= {sc_rec[7], sc_rec[6], sc_rec[5], sc_rec[4]};
                                  sc_poff  <= {sc_rec[9], sc_rec[8]};
                                  sc_plen  <= {sc_rec[11], sc_rec[10]};
                                  sc_ls    <= {sc_rec[13], sc_rec[12]};
                                  sc_ll    <= {scan_q, sc_rec[14]};
                                  sc_found <= 1'b1;
                                  sc_done  <= 1'b1;
                                  sc_fin   <= 1'b1;
                                  sc       <= SC_IDLE;
                              end else begin
                                  sc_i <= sc_i + 5'd1;
                                  sc   <= SC_RD1;
                              end
                          end
                     endcase
            default: sc <= SC_IDLE;
            endcase
        end
    end

    // ================================================================== burst byte reader
    // ONE owner for every register here. The first version had the main FSM and the reader both assigning
    // `bst`/`bdone`, which is the multi-driver mistake Quartus refuses and Verilator happily simulates (the
    // player simply hung in M_HDR). The main FSM now starts a burst - address, length, destination - and waits
    // for `b_done`; nothing else touches the port.
    //   b_dst: 0 = hdr[0:63], 1 = ord[0:127], 2 = pat[0:15]
    // b_done is a LEVEL until the consumer acknowledges it. Without the acknowledgement the NEXT burst's
    // consumer sees the PREVIOUS burst's done flag on the cycle it raises its start, concludes its own burst
    // finished, and decodes stale data - measured: the order table came back all zeros and every row was
    // decoded from the header's tail.
    localparam [2:0] B_IDLE = 3'd0, B_REQ = 3'd1, B_WAIT = 3'd2, B_FIN = 3'd3, B_ACK = 3'd4;
    reg [2:0]  bst;
    reg        b_start, b_busy, b_done, b_ack;
    reg [23:0] b_addr;
    reg [7:0]  b_count, b_dst;
    reg [23:0] b_a;
    reg [7:0]  b_n, b_i;

    always @(posedge clk) begin
        if (rst) begin
            bst <= B_IDLE; rd_req <= 1'b0; b_done <= 1'b0; b_busy <= 1'b0;
            rd_addr <= 24'd0; b_a <= 24'd0; b_n <= 8'd0; b_i <= 8'd0;
        end else begin
            case (bst)
            B_IDLE: begin
                        rd_req <= 1'b0;
                        if (b_start) begin
                            b_a    <= b_addr;
                            b_n    <= b_count;
                            b_i    <= 8'd0;
                            b_busy <= 1'b1;
                            b_done <= 1'b0;
                            bst    <= B_REQ;
                        end
                    end
            B_REQ: begin
                        rd_addr <= b_a;
                        rd_req  <= 1'b1;
                        bst     <= B_WAIT;
                    end
            B_WAIT: if (rd_valid) begin
                        rd_req <= 1'b0;
                        if (b_dst == 8'd0) hdr[b_i[5:0]] <= rd_data;
                        else if (b_dst == 8'd1) ord[b_i[6:0]] <= rd_data;
                        else pat[b_i[3:0]] <= rd_data;
                        b_a <= b_a + 24'd1;
                        b_i <= b_i + 8'd1;
                        if (b_i + 8'd1 >= b_n) bst <= B_FIN;
                        else                   bst <= B_REQ;
                    end
            B_FIN: begin
                        b_done <= 1'b1;
                        b_busy <= 1'b0;
                        bst    <= B_ACK;
                    end
            B_ACK: if (b_ack) begin
                        b_done <= 1'b0;
                        bst    <= B_IDLE;
                    end
            default: bst <= B_IDLE;
            endcase
        end
    end

    // ================================================================== player
    localparam [4:0]
        M_IDLE    = 5'd0,
        M_MODSCAN = 5'd1,
        M_HDR     = 5'd2,
        M_INSTR   = 5'd3,

        M_DELAY   = 5'd4,
        M_TICK    = 5'd5,
        M_PAT     = 5'd6,
        M_CH      = 5'd7,
        M_NOTE_SAMPLE = 5'd8,
        M_DIV1    = 5'd9,
        M_DIV2    = 5'd10,
        M_CMD     = 5'd11,
        M_NEXTCH  = 5'd12,
        M_ADV     = 5'd13,
        M_WAIT    = 5'd14,
        M_STOPALL = 5'd15,
        M_RESTART = 5'd25,
        M_INSTR_N = 5'd23,
        M_INSTR_G = 5'd24,
        M_HDR_W   = 5'd19,
        M_HDR_S   = 5'd20,
        M_TICK_S  = 5'd21,
        M_PAT_W   = 5'd22;

    reg [4:0]  mst;
    reg [15:0] num_r, delay_arg;
    reg [7:0]  pos_r;
    reg        running_r;

    reg [23:0] mod_base;
    reg [7:0]  hdr [0:63];
    reg [7:0]  ord [0:127];
    reg [7:0]  pat [0:15];
    reg [7:0]  rd_cnt;
    reg        hdr_orders;               // 0 = header, 1 = order table

    reg [7:0]  i_res_lo [0:14], i_res_hi [0:14], i_vol [0:14], i_ok [0:14];
    reg [23:0] i_base [0:14], i_len [0:14], i_lp [0:14], i_ll [0:14];
    reg [4:0]  ins_i;

    // cur_pos counts BYTES into a 1024-byte order (0, 16, ..., 1008): ten bits. It was eight, so it wrapped
    // at 256 and `cur_pos == 1008` was really `== 240` in that width - the order advanced after sixteen rows
    // and every row from then on fetched the wrong pattern. Measured: order 1 row 16 read row 0's bytes.
    reg [7:0]  cur_order, num_order;
    reg [9:0]  cur_pos;
    reg [2:0]  ch_idx;
    reg [15:0] note1, note2;
    reg [7:0]  note_vol;
    reg        play_note;
    reg [15:0] period_r;
    reg [8:0]  inc_r;

    reg [31:0] tick_cycles, tick_cnt, delay_ms;

    assign running = running_r;

    // the current channel's 4-byte event, straight out of the row buffer
    wire [7:0] cb0 = pat[{ch_idx, 2'b00}];
    wire [7:0] cb1 = pat[{ch_idx, 2'b00} + 3'd1];
    wire [7:0] cb2 = pat[{ch_idx, 2'b00} + 3'd2];
    wire [7:0] cb3 = pat[{ch_idx, 2'b00} + 3'd3];
    wire [15:0] cn1 = {cb0, cb1};
    wire [15:0] cn2 = {cb2, cb3};
    wire [3:0]  csample = cn2[15:12];
    wire [3:0]  ceffect = cn2[11:8];
    wire [7:0]  cparam  = cn2[7:0];

    // effect-adjusted volume for this note
    wire [7:0] ins_vol_w = i_vol[csample - 4'd1];
    wire [8:0] vol_up_w   = {1'b0, ins_vol_w} + {1'b0, cparam};
    wire [7:0] note_vol_w = (csample == 4'd0 || !i_ok[csample - 4'd1]) ? 8'd0 :
                            (ceffect == 4'd5) ? (vol_up_w > 9'd63 ? 8'd63 : vol_up_w[7:0]) :
                            (ceffect == 4'd6) ? ((ins_vol_w < cparam) ? 8'd0 : ins_vol_w - cparam) :
                                                ins_vol_w;

    wire have_ins = (csample != 4'd0) && i_ok[csample - 4'd1];

    integer ii;

    always @(posedge clk) begin
        if (rst) begin
            mst <= M_IDLE; running_r <= 1'b0; cmd_valid <= 1'b0; cmd_touch <= 1'b0; cmd_stop <= 1'b0;
            cmd_use_inc <= 1'b0; cmd_inc <= 9'd0; cmd_vol <= 8'd0;
            marker_valid <= 1'b0;
            num_r <= 16'd0; delay_arg <= 16'd0; pos_r <= 8'd0;
            sc_go <= 1'b0; dv_go <= 1'b0; ins_i <= 5'd0; ch_idx <= 3'd0;
            cur_order <= 8'd0; cur_pos <= 8'd0; num_order <= 8'd0;
            tick_cnt <= 32'd0; tick_cycles <= 32'd0; delay_ms <= 32'd0;
            b_start <= 1'b0; rd_cnt <= 8'd0; hdr_orders <= 1'b0;
            for (ii = 0; ii < 15; ii = ii + 1) begin
                i_base[ii] <= 24'd0; i_len[ii] <= 24'd0; i_lp[ii] <= 24'd0; i_ll[ii] <= 24'd0;
                i_vol[ii] <= 8'd0; i_ok[ii] <= 1'b0;
                i_res_lo[ii] <= 8'd0; i_res_hi[ii] <= 8'd0;
            end
        end else begin
            cmd_valid    <= 1'b0;
            marker_valid <= 1'b0;
            row_valid    <= 1'b0;
            dv_go        <= 1'b0;
            if (mst != M_RESTART) sc_abort <= 1'b0;

            // A cue is accepted in ANY state: the intro issues `num = 0` (stop music, vm.cpp) and then
            // `num = 7` on consecutive frames, and the first version was still loading "module 0" - the
            // index HAS a record for resource 0 (an empty sound), so it happily read that sound's bytes as a
            // module header and then ignored the real cue because it was no longer idle. Measured on
            // hardware: effects played, no music.
            if (play) begin
                num_r     <= num;
                delay_arg <= delay;
                pos_r     <= pos;
                sc_go     <= 1'b0;
                sc_ack    <= 1'b0;              // release any acknowledgement the last load left standing
                sc_abort  <= 1'b1;              // abandon any scan in flight
                if (num == 16'd0) begin
                    ch_idx <= 3'd0;
                    mst    <= M_STOPALL;        // stop music
                end else begin
                    mst    <= M_RESTART;
                end
            end else case (mst)
            M_RESTART: begin
                sc_abort  <= 1'b0;
                sc_ack    <= 1'b0;
                sc_target <= num_r;
                sc_go     <= 1'b1;
                mst       <= M_MODSCAN;
            end
            M_IDLE: begin
                running_r <= 1'b0;
                sc_go     <= 1'b0;
                sc_abort  <= 1'b0;
            end

            M_MODSCAN: begin
                sc_go <= 1'b0;
                if (sc_done) begin
                    sc_ack <= 1'b1;
                    if (!sc_found) begin
                        mst <= M_IDLE;                 // not a music resource: nothing to play, not an error
                    end else begin
                        mod_base  <= audio_base + sc_blob[23:0] + {16'd0, sc_poff};
                        b_addr    <= audio_base + sc_blob[23:0] + {16'd0, sc_poff};
                        b_count   <= 8'd64;
                        b_dst     <= 8'd0;
                        b_start   <= 1'b1;
                        mst       <= M_HDR;
                    end
                end
            end

            // 64 header bytes, then the 128-byte order table
            M_HDR: begin
                b_start <= 1'b0;
                b_ack   <= 1'b0;
                // the module scan's acknowledgement must be released here, or SC_IDLE sees sc_ack still high
                // when M_HDR raises sc_go for the first instrument and drops the go on the floor (measured:
                // the instrument phase stalled with sc idle, go 0, done 0 for the rest of the run)
                sc_ack  <= 1'b0;
                if (b_done) begin
                    b_ack <= 1'b1;                      // consume this burst
                    if (!hdr_orders) begin
                        hdr_orders <= 1'b1;
                        b_addr  <= mod_base + 24'h40;
                        b_count <= 8'd128;
                        b_dst   <= 8'd1;
                        mst     <= M_HDR_W;             // wait for the reader to take the ack...
                    end else begin
                        num_order <= hdr[8'd63];
                        ins_i     <= 5'd0;
                        mst       <= M_INSTR;
                        sc_go     <= 1'b1;
                        sc_target <= {hdr[8'd2], hdr[8'd3]};   // big-endian res: high byte first
                    end
                end
            end
            M_HDR_W: begin                              // ...then for b_done to fall, then start
                b_ack <= 1'b0;
                if (!b_done) begin
                    b_start <= 1'b1;
                    mst     <= M_HDR_S;
                end
            end
            M_HDR_S: begin
                b_start <= 1'b0;
                mst     <= M_HDR;
            end

            M_INSTR: begin
                sc_ack <= 1'b0;
                sc_go  <= 1'b0;
                if (sc_done || sc_target == 16'd0) begin
                    sc_ack <= 1'b1;
                    if (sc_target != 16'd0 && sc_found) begin
                        i_ok[ins_i]   <= 1'b1;
                        i_base[ins_i] <= audio_base + sc_blob[23:0] + {16'd0, sc_poff};
                        i_len[ins_i]  <= {8'd0, sc_ls};
                        i_ll[ins_i]   <= {8'd0, sc_ll};
                        i_lp[ins_i]   <= (sc_ll != 16'd0) ? {8'd0, sc_ls} : 24'd0;
                        // instrument i occupies bytes 2+4i..5+4i: res at 2+4i (big-endian), volume at 4+4i,
                        // so the volume's LOW byte is 5+4i. Reading 3+4i gave the res's low byte - measured:
                        // the volume table came out as 1,0,2,0,3,4,0,5,0,6, the resource ids themselves.
                        i_vol[ins_i]  <= hdr[8'd5 + {ins_i, 2'b00}];
                    end else begin
                        i_ok[ins_i]   <= 1'b0;
                    end
                    if (ins_i == 5'd14) begin
                        dv_num <= {16'd0, (delay_arg != 16'd0) ? delay_arg : {hdr[8'd1], hdr[8'd0]}} * 32'd60;
                        dv_den <= 16'd7050;
                        dv_go  <= 1'b1;
                        mst    <= M_DELAY;
                    end else begin
                        ins_i <= ins_i + 5'd1;
                        mst   <= M_INSTR_N;         // ack first, THEN the next target
                    end
                end
            end
            // the ack has to take effect before the next scan is asked for, or the scanner's done flag (a
            // level until acknowledged) is read again on the next cycle and every instrument resolves to the
            // module's own record - measured: i_base[0] = mod_base with len 0.
            M_INSTR_N: if (!sc_done) begin
                sc_ack    <= 1'b0;
                sc_target <= {hdr[8'd2 + {ins_i, 2'b00}], hdr[8'd3 + {ins_i, 2'b00}]};
                mst       <= M_INSTR_G;
            end
            M_INSTR_G: begin
                sc_go <= (sc_target != 16'd0);
                mst   <= M_INSTR;
            end

            M_DELAY: begin
                // the last instrument's acknowledgement is still held here; clear it, or the NEXT cue's scan
                // start lands on SC_IDLE's ack branch and is dropped (measured: a cue after a stop left the
                // player in M_MODSCAN with sc_go 0 and sc_ack 1 forever)
                sc_ack <= 1'b0;
                if (dv_done) begin
                    delay_ms    <= dv_q;
                    tick_cycles <= dv_q * MS_CYCLES;
                    cur_order   <= pos_r;
                    cur_pos     <= 10'd0;
                    tick_cnt    <= 32'd0;
                    if (dv_q == 32'd0) begin
                        mst <= M_IDLE;                // a delay that rounds to 0 ms is not a tempo
                    end else begin
                        running_r <= 1'b1;
                        mst       <= M_TICK;
                    end
                end
            end

            M_TICK: begin
                row_valid <= 1'b1;
                b_addr  <= mod_base + 24'hC0 + {6'd0, ord[cur_order], 10'd0} + {16'd0, cur_pos};
                b_count <= 8'd16;
                b_dst   <= 8'd2;
                b_start <= 1'b1;
                mst     <= M_TICK_S;
            end
            M_TICK_S: begin
                b_start <= 1'b0;
                mst     <= M_PAT;
            end

            M_PAT: begin
                b_start <= 1'b0;
                b_ack   <= 1'b0;
                if (b_done) begin
                    b_ack <= 1'b1;
                    mst   <= M_PAT_W;
                end
            end
            M_PAT_W: begin
                b_ack <= 1'b0;
                if (!b_done) begin
                    ch_idx <= 3'd0;
                    mst    <= M_CH;
                end
            end

            M_CH: begin
                note1 <= cn1;
                note2 <= cn2;
                if (cn1 == 16'hFFFD) begin
                    marker_value <= cn2;
                    marker_ch    <= ch_idx[1:0];
                    marker_valid <= 1'b1;
                    mst          <= M_NEXTCH;
                end else if (cn1 == 16'hFFFE) begin
                    cmd_valid   <= 1'b1;
                    cmd_stop    <= 1'b1;                 // 0xFFFE is stopChannel
                    cmd_touch   <= 1'b1;
                    cmd_use_inc <= 1'b0;
                    cmd_ch      <= ch_idx[1:0];
                    cmd_vol     <= 8'd0;
                    mst         <= M_NEXTCH;
                end else begin
                    // note1 == 0 is a row with no note, but its effect field still changes the volume
                    period_r  <= cn1;
                    play_note <= (cn1 != 16'd0);
                    mst       <= M_NOTE_SAMPLE;
                end
            end

            M_NOTE_SAMPLE: begin
                if (have_ins) begin
                    cmd_valid   <= 1'b1;
                    cmd_stop    <= 1'b0;
                    cmd_touch   <= 1'b0;                     // volume only, exactly as setChannelVolume does
                    cmd_use_inc <= 1'b0;
                    cmd_ch      <= ch_idx[1:0];
                    cmd_vol     <= note_vol_w;
                end
                mst <= play_note ? M_DIV1 : M_NEXTCH;
            end

            M_DIV1: begin
                dv_num <= 32'd7159092;
                dv_den <= {period_r[14:0], 1'b0};            // period * 2
                dv_go  <= 1'b1;
                mst    <= M_DIV2;
            end

            M_DIV2: if (dv_done) begin
                dv_num <= dv_q << 8;
                dv_den <= 16'd48000;
                dv_go  <= 1'b1;
                mst    <= M_CMD;
            end

            M_CMD: if (dv_done) begin
                if (have_ins) begin
                    cmd_valid   <= 1'b1;
                    cmd_stop    <= 1'b0;                     // a play at volume 0 is still a play
                    cmd_touch   <= 1'b1;
                    cmd_use_inc <= 1'b1;
                    cmd_inc     <= dv_q[8:0];
                    cmd_ch      <= ch_idx[1:0];
                    cmd_vol     <= note_vol_w;
                    cmd_len     <= i_len[csample - 4'd1];
                    cmd_lp      <= i_lp[csample - 4'd1];
                    cmd_ll      <= i_ll[csample - 4'd1];
                    cmd_base    <= i_base[csample - 4'd1];
                end
                mst <= M_NEXTCH;
            end

            M_NEXTCH: begin
                if (ch_idx == 3'd3) mst <= M_ADV;
                else begin
                    ch_idx <= ch_idx + 3'd1;
                    mst    <= M_CH;
                end
            end

            M_ADV: begin
                if (cur_pos == 10'd1008) begin
                    cur_pos <= 10'd0;
                    if (cur_order + 8'd1 == num_order) begin
                        ch_idx <= 3'd0;          // stop all four channels starting at 0, in order
                        mst    <= M_STOPALL;
                    end else begin
                        cur_order <= cur_order + 8'd1;
                        tick_cnt  <= 32'd0;
                        mst       <= M_WAIT;
                    end
                end else begin
                    cur_pos  <= cur_pos + 10'd16;
                    tick_cnt <= 32'd0;
                    mst      <= M_WAIT;
                end
            end

            M_WAIT: begin
                tick_cnt <= tick_cnt + 32'd1;
                if (tick_cnt >= tick_cycles) mst <= M_TICK;
            end

            M_STOPALL: begin
                cmd_valid   <= 1'b1;
                cmd_stop    <= 1'b1;
                cmd_touch   <= 1'b1;
                cmd_use_inc <= 1'b0;
                cmd_ch      <= ch_idx[1:0];
                cmd_vol     <= 8'd0;
                if (ch_idx == 3'd3) begin
                    ch_idx    <= 3'd0;
                    running_r <= 1'b0;
                    mst       <= M_IDLE;
                end else begin
                    ch_idx <= ch_idx + 3'd1;
                end
            end

            default: mst <= M_IDLE;
            endcase
        end
    end

endmodule
