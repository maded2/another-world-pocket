// dbg_console.v - turns core lifecycle events into short log lines for dbg_uart_tx.
//
// All inputs are already in the clk_core domain (core_top synchronises the one
// exception, osnotify_inmenu, before calling us). Events set bits in a pending
// register rather than being dropped: if two happen close together (pack loaded
// and game start on the same boot), both lines get sent, in priority order.
//
// Handshake with the UART push FIFO: `presenting` is a registered state that
// drives tx_valid combinationally. A byte is presented only while tx_ready is
// high, held until the cycle where the FIFO actually accepts it (the same
// tx_ready sample the FIFO uses), then pos advances. Nothing can be lost or
// duplicated regardless of how long backpressure lasts.

module dbg_console (
    input  wire        clk,          // clk_core (24.75 MHz)
    input  wire        rst_n,        // active low (~rst_core)
    input  wire        ev_boot,      // pulse: design_run rose - game is running
    input  wire        ev_rom_ok,    // pulse: rom_ready rose - pack loaded, trailer ok
    input  wire [1:0]  rom_error,    // level: aw_rom error code, 0 = none
    input  wire        ev_inmenu,    // pulse: osnotify_inmenu rose
    input  wire        ev_outmenu,   // pulse: osnotify_inmenu fell
    input  wire [127:0] rom_chk_data,  // last trailer readback (periodic CHK dump)
    input  wire [31:0]  rom_dbg_wr_match,  // bridge writes accepted into the pack window
    input  wire [31:0]  rom_dbg_wr_all,    // every bridge write seen
    input  wire [15:0]  rom_dbg_status,    // {overflow, allc_seen, last_match[23:10]}
    input  wire [15:0]  rom_selftest_die0,   // self-test matrix: normal-op scratch round-trip
    input  wire [15:0]  rom_selftest_be,     // self-test: byte-lane/write-mask round-trip (a55a expected)
    input  wire [15:0]  rom_selftest_ceneg,  // self-test matrix: CE-inverted round-trip
    input  wire [15:0]  rom_selftest_cre,    // self-test matrix: CRE-high round-trip
    input  wire [15:0]  rom_selftest_pack0,  // self-test: pack word 0 readback (0004 for part1)
    // Video / VM liveness, so a black screen can be told apart from a loaded one without
    // a logic analyser. 1036a reached C0 (pack validated, rom_ready high, VM released) and
    // the panel stayed black: everything below the render path now reports success on
    // hardware, so the next question is which side of the SoC's video output is silent.
    input  wire [23:0]  vid_frames,          // game-path vsync pulses counted since boot
    input  wire [19:0]  vid_de_per_frame,    // de pulses in the last complete frame (64000 = fa00)
    input  wire [19:0]  vid_lit_per_frame,   // of those, how many were non-black
    input  wire [31:0]  rom_rd_bytes,        // bytes aw_rom has streamed to the VM
    input  wire [7:0]   vid_status,          // {saw_hs,saw_vs,inmenu,design_run,video_sel,suppress,_,rom_ready}
    output reg  [7:0]  tx_data,
    output wire        tx_valid,
    input  wire        tx_ready
);

// message ids
localparam MID_UP      = 3'd0,   // "AW 1026a up\n"            console out of reset (tag = build id)
           MID_RUN     = 3'd1,   // "game running\n"
           MID_OK      = 3'd2,   // "pack loaded ok\n"
           MID_ERR1    = 3'd3,   // "ROM ERR: bad trailer\n"
           MID_ERR2    = 3'd4,   // "ROM ERR: psram overflow\n"
           MID_ERR3    = 3'd5,   // "ROM ERR: wait state (n/a)\n"
           MID_MENUIN  = 3'd6,   // "in menu\n"
           MID_MENUOUT = 3'd7,   // "resumed\n"
           MID_CHK     = 4'd8;   // "C<err>:<32 hex chk_data> <m>/<a> S<s> D<d> B<b> N<n> R<r> P<p>\n"

// localparam widths must EXACTLY match the string length in bits: Verilog
// right-justifies a shorter literal and the byte extraction below assumes char 0
// sits in the MSB.
// The tag in the boot line is the build id - the first thing a hardware session
// prints, so any capture identifies which bitstream is actually in the FPGA.
localparam [8*12-1:0]  MSG_UP      = "AW 1037a up\n";   // diag build: also re-sent every ~2 s (tag_cnt)
localparam [8*13-1:0]  MSG_RUN     = "game running\n";
localparam [8*15-1:0]  MSG_OK      = "pack loaded ok\n";
localparam [8*21-1:0]  MSG_ERR1    = "ROM ERR: bad trailer\n";
localparam [8*23-1:0]  MSG_ERR2    = "ROM ERR: psram overflow\n";
localparam [8*25-1:0]  MSG_ERR3    = "ROM ERR: wait state (n/a)\n";
localparam [8*8-1:0]   MSG_MENUIN  = "in menu\n";
localparam [8*8-1:0]   MSG_MENUOUT = "resumed\n";

// pending event bits; priority high to low: err, ok, up, run, outmenu, inmenu
//
// A bit is cleared ONLY on the cycle its message actually starts (i.e. while
// !sending). Clearing with the plain pick wires loses events that arrive mid-
// message: the bit gets ORed in and masked out in the same update while the
// start branch is still gated off by sending - the line never goes out.
reg [6:0] pend;                        // {stat, err, ok, up, run, outmenu, inmenu}
reg [1:0] err_latch;                   // rom_error code when the error bit was set

// Diagnostic build 1028b: cap how often an error line may START, so a failing
// check that re-fires faster than the UART can drain cannot starve the periodic
// CHK dump (lowest priority) forever. 6.2e6 cycles ~= 250 ms at 24.75 MHz.
// The TB passes 0 to keep its back-to-back error sequence intact.
parameter THROTTLE_CYCLES = 25'd6_200_000;
reg [24:0] err_throttle;
wire       err_allowed = (err_throttle == 25'd0);

// edge-detect the level input here so core_top only has to hand it over
reg [1:0] err_prev;
wire      err_pulse = (rom_error != err_prev) && (rom_error != 2'd0);

// periodic status dump (~1 s): fires well after the boot drop window, so it reaches a
// UART bridge that is not ready during the first milliseconds after cart power. It is
// the lowest-priority message, so real events always go out first.
// Benches pass a small value to exercise the CHK line inside their time window.
parameter STAT_FIRE_AT = 25'd24_749_999;         // ~1 s at clk_core 24.75 MHz
reg [24:0] stat_cnt;
wire stat_fire = (stat_cnt == STAT_FIRE_AT);
always @(posedge clk) begin
    if (!rst_n)         stat_cnt <= 25'd0;
    else if (stat_fire) stat_cnt <= 25'd0;
    else                stat_cnt <= stat_cnt + 25'd1;
end

// Diagnostic build 1028b: re-send the boot tag every ~2 s. A capture that starts
// mid-session (the normal case - the UART bridge is not ready during the first
// milliseconds after cart power) then still identifies which bitstream is in the
// FPGA. The period is far outside any sim window, so benches never see it.
reg [25:0] tag_cnt;
wire tag_fire = (tag_cnt == 26'd49_499_999);     // ~2 s at clk_core 24.75 MHz
always @(posedge clk) begin
    if (!rst_n)         tag_cnt <= 26'd0;
    else if (tag_fire)  tag_cnt <= 26'd0;
    else                tag_cnt <= tag_cnt + 26'd1;
end

// ---- pick one pending message --------------------------------------------------
wire pick_err   = pend[5] && err_allowed;
wire pick_ok    = !pick_err   && pend[4];
wire pick_up    = !pick_err && !pick_ok   && pend[3];
wire pick_run   = !pick_err && !pick_ok && !pick_up && pend[2];
wire pick_mout  = !pick_err && !pick_ok && !pick_up && !pend[2] && pend[1];
wire pick_min   = !pick_err && !pick_ok && !pick_up && !pend[2] && !pend[1] && pend[0];
wire pick_stat  = !pick_err && !pick_ok && !pick_up && !pick_run
              && !pick_mout && !pick_min && pend[6];

// events this cycle, and the mask that clears the picked bit - applied only on
// a cycle where the message actually starts (see the note above).
//
// The mask bits MUST match the pend bit layout {stat, err, ok, up, run, mout, min}
// = {6, 5, 4, 3, 2, 1, 0}. Getting one wrong does not just repeat that message: a
// stuck err bit (top priority) starves every lower message forever - the on-device
// "ROM ERR: bad trailer" flood of build 1026a was exactly this.
wire [6:0] ev_now    = {stat_fire, err_pulse, ev_rom_ok, tag_fire, ev_boot, ev_outmenu, ev_inmenu};
wire [6:0] pick_mask = (!sending) ? (
                         pick_err    ? 7'b0100000 :   // bit5 = err
                         pick_ok     ? 7'b0010000 :   // bit4 = ok
                         pick_up     ? 7'b0001000 :   // bit3 = up/tag
                         pick_run    ? 7'b0000100 :   // bit2 = run
                         pick_mout   ? 7'b0000010 :   // bit1 = outmenu
                         pick_min    ? 7'b0000001 :   // bit0 = inmenu
                         pick_stat   ? 7'b1000000 :   // bit6 = stat
                         7'b0000000)
                          : 7'b0;

reg [3:0] msg_id;
// 7 bits: the CHK line is 66 bytes (positions 0..65) - 6 bits truncated it to 2
reg [6:0] pos;
reg       sending;
reg       presenting;                  // tx_valid is high while this is set

always @(posedge clk) begin
    if (!rst_n) begin
        pend      <= 7'b0001000;       // bit3 = up: boot tag goes out first
        err_prev  <= 2'd0;
        err_latch <= 2'd0;
        err_throttle <= 25'd0;
        msg_id    <= MID_UP;
        pos       <= 6'd0;
        sending   <= 1'b0;
        presenting<= 1'b0;
    end else begin
        err_prev <= rom_error;
        if (err_pulse) err_latch <= rom_error;

        // capture events; clear the picked bit only when we actually start it
        pend <= (pend | ev_now) & ~pick_mask;

        if (!sending) begin
            presenting <= 1'b0;
            if (pick_err) begin
                msg_id <= (err_latch == 2'd1) ? MID_ERR1 :
                          (err_latch == 2'd2) ? MID_ERR2 : MID_ERR3;
                pos    <= 6'd0;
                sending<= 1'b1;
                err_throttle <= THROTTLE_CYCLES;   // next error line no sooner than this
            end else if (pick_ok) begin
                msg_id <= MID_OK;      pos <= 6'd0; sending <= 1'b1;
            end else if (pick_up) begin
                msg_id <= MID_UP;      pos <= 6'd0; sending <= 1'b1;
            end else if (pick_run) begin
                msg_id <= MID_RUN;     pos <= 6'd0; sending <= 1'b1;
            end else if (pick_mout) begin
                msg_id <= MID_MENUOUT; pos <= 6'd0; sending <= 1'b1;
            end else if (pick_min) begin
                msg_id <= MID_MENUIN;  pos <= 6'd0; sending <= 1'b1;
            end else if (pick_stat) begin
                msg_id <= MID_CHK;     pos <= 6'd0; sending <= 1'b1;
            end
        end else if (presenting) begin
            // tx_valid is high this cycle; the FIFO accepts exactly when its
            // ready was high this same cycle - that sample decides here too
            if (tx_ready) begin
                presenting <= 1'b0;
                pos      <= pos + 6'd1;
                if (pos == msg_len - 6'd1) sending <= 1'b0;
            end
            // else: hold the byte, retry next cycle
        end else if (tx_ready) begin
            presenting <= 1'b1;        // present tx_data next cycle
        end
    end
end

assign tx_valid = presenting;

reg [6:0] msg_len;

always @(*) begin
    case (msg_id)
        MID_UP:      msg_len = 7'd12;
        MID_RUN:     msg_len = 6'd13;
        MID_OK:      msg_len = 6'd15;
        MID_ERR1:    msg_len = 6'd21;
        MID_ERR2:    msg_len = 6'd23;
        MID_ERR3:    msg_len = 6'd25;
        MID_MENUIN:  msg_len = 6'd8;
        MID_MENUOUT: msg_len = 6'd8;
        MID_CHK:     msg_len = 7'd126;
        default:     msg_len = 6'd8;
    endcase
end

// nibble -> ASCII hex char (for the periodic CHK dump)
function [7:0] hxn;
    input [3:0] n;
    begin
        case (n)
            4'd0:   hxn = 8'h30; 4'd1:  hxn = 8'h31; 4'd2:  hxn = 8'h32;
            4'd3:   hxn = 8'h33; 4'd4:  hxn = 8'h34; 4'd5:  hxn = 8'h35;
            4'd6:   hxn = 8'h36; 4'd7:  hxn = 8'h37; 4'd8:  hxn = 8'h38;
            4'd9:   hxn = 8'h39; 4'd10: hxn = 8'h61; 4'd11: hxn = 8'h62;
            4'd12:  hxn = 8'h63; 4'd13: hxn = 8'h64; 4'd14: hxn = 8'h65;
            4'd15:  hxn = 8'h66;
        endcase
    end
endfunction

// byte pos of the current message; string literals store char 0 in the MSB, so
// char p lives at bits [(LEN-1-p)*8 +: 8]
always @(*) begin
    case (msg_id)
        MID_CHK: begin
            // "C<err>:<32 hex chk_data> <match 8hex>/<all 8hex> S<status 4hex>
            //  D<normal rt> B<BE-low rt> N<CE-inverted rt> R<CRE-high rt> P<pack word 0>
            //  V<frames 6hex> F<de/frame 5hex> L<lit/frame 5hex> Y<rom bytes 8hex> X<vid status 2hex>\n"
            // X bits: 0 rom_ready, 1 design_run, 2 video_sel, 3 suppress, 4 inmenu,
            // 5 saw a game vsync, 6 saw a game hsync. F=fa00 (64000) means the display
            // window is being scanned; L=0 with F correct means it is scanning black.
            // The W/S fields are the aw_rom loader counters (also on the error screen,
            // rows 8-10). D/B/N/R are the control-signal search: the same scratch
            // round-trip under normal operation and with one assumption flipped each;
            // a5a5 in exactly one of them names the wrong assumption. P is the pack
            // word 0 readback - 0004 (part1) once reads return chip data at all.
            if      (pos == 6'd0)  tx_data = 8'h43;                    // 'C'
            else if (pos == 6'd1)  tx_data = 8'h30 + rom_error[1:0];   // err digit
            else if (pos == 6'd2)  tx_data = 8'h3a;                    // ':'
            else if (pos <= 6'd34) tx_data = hxn(rom_chk_data[(6'd34 - pos)*4 +: 4]);
            else if (pos == 6'd35) tx_data = 8'h20;                    // ' '
            else if (pos <= 6'd43) tx_data = hxn(rom_dbg_wr_match[(6'd43 - pos)*4 +: 4]);
            else if (pos == 6'd44) tx_data = 8'h2f;                    // '/'
            else if (pos <= 6'd52) tx_data = hxn(rom_dbg_wr_all[(6'd52 - pos)*4 +: 4]);
            else if (pos == 6'd53) tx_data = 8'h20;                    // ' '
            else if (pos == 6'd54) tx_data = 8'h53;                    // 'S'
            else if (pos <= 6'd58) tx_data = hxn(rom_dbg_status[(6'd58 - pos)*4 +: 4]);
            else if (pos == 6'd59) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd60) tx_data = 8'h44;                    // 'D'
            else if (pos <= 7'd64) tx_data = hxn(rom_selftest_die0[(7'd64 - pos)*4 +: 4]);
            else if (pos == 7'd65) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd66) tx_data = 8'h42;                    // 'B'
            else if (pos <= 7'd70) tx_data = hxn(rom_selftest_be[(7'd70 - pos)*4 +: 4]);
            else if (pos == 7'd71) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd72) tx_data = 8'h4e;                    // 'N'
            else if (pos <= 7'd76) tx_data = hxn(rom_selftest_ceneg[(7'd76 - pos)*4 +: 4]);
            else if (pos == 7'd77) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd78) tx_data = 8'h52;                    // 'R'
            else if (pos <= 7'd82) tx_data = hxn(rom_selftest_cre[(7'd82 - pos)*4 +: 4]);
            else if (pos == 7'd83) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd84) tx_data = 8'h50;                    // 'P'
            else if (pos <= 7'd88) tx_data = hxn(rom_selftest_pack0[(7'd88 - pos)*4 +: 4]);
            else if (pos == 7'd89) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd90) tx_data = 8'h56;                    // 'V' frames
            else if (pos <= 7'd96) tx_data = hxn(vid_frames[(7'd96 - pos)*4 +: 4]);
            else if (pos == 7'd97) tx_data = 8'h20;                    // ' '
            else if (pos == 7'd98) tx_data = 8'h46;                    // 'F' de per frame
            else if (pos <= 7'd103) tx_data = hxn(vid_de_per_frame[(7'd103 - pos)*4 +: 4]);
            else if (pos == 7'd104) tx_data = 8'h20;                   // ' '
            else if (pos == 7'd105) tx_data = 8'h4c;                   // 'L' lit per frame
            else if (pos <= 7'd110) tx_data = hxn(vid_lit_per_frame[(7'd110 - pos)*4 +: 4]);
            else if (pos == 7'd111) tx_data = 8'h20;                   // ' '
            else if (pos == 7'd112) tx_data = 8'h59;                   // 'Y' ROM bytes to the VM
            else if (pos <= 7'd120) tx_data = hxn(rom_rd_bytes[(7'd120 - pos)*4 +: 4]);
            else if (pos == 7'd121) tx_data = 8'h20;                   // ' '
            else if (pos == 7'd122) tx_data = 8'h58;                   // 'X' status
            else if (pos <= 7'd124) tx_data = hxn(vid_status[(7'd124 - pos)*4 +: 4]);
            else                   tx_data = 8'h0a;                    // '\n'
        end
        MID_UP:      tx_data = MSG_UP      [(11 - pos)*8 +: 8];
        MID_RUN:     tx_data = MSG_RUN     [(12 - pos)*8 +: 8];
        MID_OK:      tx_data = MSG_OK      [(14 - pos)*8 +: 8];
        MID_ERR1:    tx_data = MSG_ERR1    [(20 - pos)*8 +: 8];
        MID_ERR2:    tx_data = MSG_ERR2    [(22 - pos)*8 +: 8];
        MID_ERR3:    tx_data = MSG_ERR3    [(24 - pos)*8 +: 8];
        MID_MENUIN:  tx_data = MSG_MENUIN  [(7  - pos)*8 +: 8];
        default:     tx_data = MSG_MENUOUT [(7  - pos)*8 +: 8];
    endcase
end

endmodule
