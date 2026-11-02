// tb_dbg_console - debug console + UART transmitter for the aw core.
//
// Phase A drives dbg_uart_tx directly with known bytes and checks framing plus
// the baud-rate bit period: 24.75 MHz / DIV must be 115200 +/- a hair, i.e.
// DIV == 215 (measured as real time between two guaranteed edges).
// Phase B drives dbg_console through a deliberately shallow FIFO (DEPTH=4) so
// every message of more than 4 bytes hits real backpressure mid-string; the
// decoded text must still match byte for byte. Also covers: reset banner, all
// seven messages, rom_error edge detection for all three codes, and two events
// in one cycle (priority order).
`timescale 1ns/1ps
`default_nettype none

module tb_dbg_console;

    localparam CLK_PERIOD = 40.40404;   // 24.75 MHz, same numbers as tb_reset_gen
    localparam DIV        = 215;        // expected baud divisor: round(24.75e6/115200)
    localparam BIT        = DIV * CLK_PERIOD;  // one UART bit in sim time

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer errors = 0;
    task expect(input [8*64-1:0] name, input cond);
        begin
            if (!cond) begin
                $display("tb_dbg_console: FAIL %s", name);
                errors = errors + 1;
            end else begin
                $display("tb_dbg_console: ok   %s", name);
            end
        end
    endtask

    // =========================================================================
    // Phase A: dbg_uart_tx alone, direct byte pushes.
    // Bit geometry from the start-bit falling edge (t0): data bit i occupies
    // [(i+1)*BIT, (i+2)*BIT), so its centre is t0 + (i+1.5)*BIT; the stop bit
    // centre is t0 + 9.5*BIT. Sampling at centres makes this independent of
    // which bits happen to alternate.
    // =========================================================================
    reg         a_rst_n = 1'b0;
    reg  [7:0]  a_data = 8'd0;
    reg         a_valid = 1'b0;
    wire        a_ready;
    wire        a_tx;

    dbg_uart_tx #(.CLK_FREQ(24_750_000), .BAUD(115_200)) dut_a (
        .clk(clk), .rst_n(a_rst_n),
        .tx_data(a_data), .tx_valid(a_valid), .tx_ready(a_ready), .dbg_tx(a_tx)
    );

    reg [7:0] byte;
    integer i;
    real t_start, t_edge;

    task decode_frame(output [7:0] out_byte);
        begin
            @(negedge a_tx);                    // start bit begins at t0
            t_start = $time;
            #(1.5 * BIT);
            out_byte[0] = a_tx;
            for (i = 1; i < 8; i = i + 1) begin
                #(BIT);
                out_byte[i] = a_tx;
            end
            #(BIT);                             // now at 9.5*BIT: stop centre
            if (a_tx !== 1'b1) begin
                $display("tb_dbg_console: FAIL stop bit not high");
                errors = errors + 1;
            end
        end
    endtask

    // All stimulus is driven on negedge (mid-cycle) so it is stable across the
    // whole posedge the DUT samples: setting it in the active region of the
    // sampling edge itself races against process scheduling order and iverilog
    // consistently lost that race (byte never seen).
    task push_byte(input [7:0] b);
        begin
            @(negedge clk);
            a_data = b; a_valid = 1'b1;
            @(negedge clk);          // hold across one full sampling edge
            a_valid = 1'b0;
        end
    endtask

    // =========================================================================
    // Phase B: dbg_console -> dbg_uart_tx (shallow FIFO = constant backpressure)
    // =========================================================================
    reg         b_rst_n = 1'b0;
    reg         ev_boot = 1'b0, ev_rom_ok = 1'b0, ev_inmenu = 1'b0, ev_outmenu = 1'b0;
    reg  [1:0]  rom_error = 2'd0;
    wire [7:0]  b_data;
    wire        b_valid, b_ready;
    wire        b_tx;

    // THROTTLE_CYCLES=0: this bench checks back-to-back error lines; the device
    // default (250 ms) is exercised on hardware only, see dbg_console.v.
    // An id of its own on purpose. If both instances printed the same string, the bench could not
    // tell "derived from BUILD_ID" from "hardcoded literal again" - which is the exact regression
    // this parameter exists to prevent, and it was invisible for two releases.
    dbg_console #(.THROTTLE_CYCLES(25'd0), .BUILD_ID(16'd1042), .BUILD_SFX("z")) dut_b (
        .clk(clk), .rst_n(b_rst_n),
        .ev_boot(ev_boot), .ev_rom_ok(ev_rom_ok), .rom_error(rom_error),
        .ev_inmenu(ev_inmenu), .ev_outmenu(ev_outmenu),
        .rom_chk_data(128'h0),
        .rom_dbg_wr_match(32'h0), .rom_dbg_wr_all(32'h0), .rom_dbg_status(16'h0),
        .rom_selftest_die0(16'h0), .rom_selftest_be(16'h0), .rom_selftest_ceneg(16'h0),
        .rom_selftest_cre(16'h0), .rom_selftest_pack0(16'h0),
        .vid_frames(24'h0), .vid_de_per_frame(20'h0), .vid_lit_per_frame(20'h0),
        .rom_rd_bytes(32'h0), .vid_status(8'h0),
        .cen_sum_r(32'h0), .cen_sum_w(32'h0), .cen_qmism(4'h0), .cen_stat(3'b000),
        .dir_valid(1'b0), .dir_bad(1'b0), .pool_ok(1'b0), .part_late(1'b0),
        .rom_part(3'd0), .dir_err(8'd0),
        .tx_data(b_data), .tx_valid(b_valid), .tx_ready(b_ready)
    );

    dbg_uart_tx #(.CLK_FREQ(24_750_000), .BAUD(115_200), .DEPTH(4)) dut_b_uart (
        .clk(clk), .rst_n(b_rst_n),
        .tx_data(b_data), .tx_valid(b_valid), .tx_ready(b_ready), .dbg_tx(b_tx)
    );

    // Phase C: a quiet second instance whose stat period is short enough that the
    // CHK line lands inside the bench window. Known loader-counter values pin the
    // whole 60-byte format, hex nibble order included.
    reg         c_rst_n = 1'b0;
    wire [7:0]  c_data;
    wire        c_valid, c_ready, c_tx;

    dbg_console #(.THROTTLE_CYCLES(25'd0), .STAT_FIRE_AT(25'd4999)) dut_c (
        .clk(clk), .rst_n(c_rst_n),
        .ev_boot(1'b0), .ev_rom_ok(1'b0), .rom_error(2'd0),
        .ev_inmenu(1'b0), .ev_outmenu(1'b0),
        .rom_chk_data(128'h0),
        .rom_dbg_wr_match(32'hDEADBEEF),
        .rom_dbg_wr_all  (32'h00080000),
        .rom_dbg_status  (16'h4000),
        .rom_selftest_die0 (16'hAAAA),
        .rom_selftest_be   (16'hBBBB),
        .rom_selftest_ceneg(16'hCCCC),
        .rom_selftest_cre  (16'hDDDD),
        .rom_selftest_pack0(16'h5678),
        // video/VM liveness: 300 frames, a full 64000-pixel window of which 7500 lit,
        // 0x1255d3 ROM bytes streamed, status {0,saw_hs,saw_vs,inmenu,design_run,
        // video_sel,suppress,rom_ready} = 0111_0101
        .vid_frames(24'h00012C),
        .vid_de_per_frame(20'h0FA00),
        .vid_lit_per_frame(20'h01D4C),
        .rom_rd_bytes(32'h001255D3),
        .vid_status(8'h75),
        // census: finished, contiguous, written sum equals read sum -> 'Z.0'
        .cen_sum_r(32'h1A2B3C4D), .cen_sum_w(32'h1A2B3C4D),
        .cen_qmism(4'h0), .cen_stat(3'b010),
        // paging: a table is installed for part 2 and the pool sums match -> flags 0101
        .dir_valid(1'b1), .dir_bad(1'b0), .pool_ok(1'b1), .part_late(1'b0),
        .rom_part(3'd2), .dir_err(8'd0),
        .tx_data(c_data), .tx_valid(c_valid), .tx_ready(c_ready)
    );

    dbg_uart_tx #(.CLK_FREQ(24_750_000), .BAUD(115_200), .DEPTH(4)) dut_c_uart (
        .clk(clk), .rst_n(c_rst_n),
        .tx_data(c_data), .tx_valid(c_valid), .tx_ready(c_ready), .dbg_tx(c_tx)
    );

    task decode_c(output [7:0] out_byte);
        begin
            @(negedge c_tx);
            #(1.5 * BIT);
            out_byte[0] = c_tx;
            for (i = 1; i < 8; i = i + 1) begin
                #(BIT);
                out_byte[i] = c_tx;
            end
            #(BIT);
        end
    endtask

    task recv_line_c(input [8*160-1:0] want, input integer want_len);
        begin
            nbyte = 0;
            decode_c(got_byte);
            while (got_byte !== 8'h0a && nbyte < 158) begin
                got_line_c[nbyte*8 +: 8] = got_byte;
                nbyte = nbyte + 1;
                decode_c(got_byte);
            end
            line_ok = (got_byte === 8'h0a);
            for (k = 0; k < nbyte && line_ok; k = k + 1)
                if (got_line_c[k*8 +: 8] !== want[(want_len-1-k)*8 +: 8])
                    line_ok = 1'b0;
            if (!line_ok) begin
                $write("GOT [ "); for (k = 0; k < nbyte; k = k + 1) $write("%c", got_line_c[k*8 +: 8]); $write(" ] WANT [ ");
                for (k = 0; k < want_len-1; k = k + 1) $write("%c", want[(want_len-1-k)*8 +: 8]); $write(" ]\n");
            end
            expect("phase C line matches", line_ok);
        end
    endtask

    reg [7:0] got_byte;
    task decode_b(output [7:0] out_byte);   // decodes off b_tx
        begin
            @(negedge b_tx);
            #(1.5 * BIT);
            out_byte[0] = b_tx;
            for (i = 1; i < 8; i = i + 1) begin
                #(BIT);
                out_byte[i] = b_tx;
            end
            // Wake at t0+9.5B, mid-stop-bit: the next frame's start edge lands at
            // ~t0+10B (one extra clock of stop hold), so waiting 2*BIT here would
            // wake AFTER it and re-anchor on a mid-frame edge - garbage bytes.
            #(BIT);
        end
    endtask

    integer nbyte, k;
    reg [8*32-1:0] got_line;
    reg [8*160-1:0] got_line_c;  // phase C: the CHK line is 126 chars
    reg line_ok;

    // want is a string literal right-justified in its 32-byte vector, so char c
    // lives at [(want_len-1-c)*8 +: 8]; the length is passed explicitly.
    task recv_line(input [8*32-1:0] want, input integer want_len);
        begin
            nbyte = 0;
            decode_b(got_byte);
            while (got_byte !== 8'h0a && nbyte < 31) begin
                got_line[nbyte*8 +: 8] = got_byte;
                nbyte = nbyte + 1;
                decode_b(got_byte);
            end
            line_ok = (got_byte === 8'h0a);
            for (k = 0; k < nbyte && line_ok; k = k + 1)
                if (got_line[k*8 +: 8] !== want[(want_len-1-k)*8 +: 8])
                    line_ok = 1'b0;
            // The LENGTH is part of the assertion. Comparing only the characters that arrived means a
            // message that got shorter - a localparam and its msg_len edited out of step, which is
            // precisely the failure class this bench exists to catch - matches its own prefix and
            // passes. Phase C checks this via want_len; phase B did not, and did not print what it
            // received either, so a failure here said only "line matches" with nothing to look at.
            if (nbyte != want_len - 1) line_ok = 1'b0;
            if (!line_ok) begin
                $write("GOT [ ");
                for (k = 0; k < nbyte; k = k + 1) $write("%c", got_line[k*8 +: 8]);
                $write(" ] (%0d chars) WANT [ ", nbyte);
                for (k = 0; k < want_len-1; k = k + 1) $write("%c", want[(want_len-1-k)*8 +: 8]);
                $write(" ] (%0d chars)\n", want_len-1);
                $fflush;
            end
            expect("line matches", line_ok);
        end
    endtask


    // watchdog: report line states if the bench wedges, so a hang is diagnosable
    initial begin : wd
        integer w;
        for (w = 0; w < 1600; w = w + 1) begin   // 40 ms
            #(25_000);
            $display("watchdog t=%0t b_tx=%b bpend=%b bsnd=%b bpres=%b brdy=%b bwr=%0d brd=%0d shif=%b div=%0d bit=%0d",
                     $time, b_tx, dut_b.pend, dut_b.sending, dut_b.presenting,
                     b_ready, dut_b_uart.wr, dut_b_uart.rd,
                     dut_b_uart.shifting, dut_b_uart.divcnt, dut_b_uart.bitcnt);
        end
        $display("tb_dbg_console: WATCHDOG TIMEOUT");
        $finish;
    end

    initial begin
        $display("tb_dbg_console: phase A - uart framing and baud");
        repeat (5) @(posedge clk);
        a_rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 0x55: frame bits 0,1,0,1,... - edge at every boundary, so the first
        // data edge lands exactly DIV clocks after the start edge. Measured on
        // its own frame: decode_frame would re-sync on the next bit, not a
        // fresh start edge.
        push_byte(8'h55);
        @(negedge a_tx);                 t_start = $time;   // start edge
        @(posedge a_tx);                 t_edge  = $time;   // d0 (1) edge
        expect("bit period == DIV clocks",
               (t_edge - t_start) > (DIV-1)*CLK_PERIOD &&
               (t_edge - t_start) < (DIV+1)*CLK_PERIOD);
        #(9.5 * BIT);                    // run out the rest of that frame

        push_byte(8'h55);
        decode_frame(byte);
        expect("byte 0x55 content", byte === 8'h55);

        push_byte(8'haa);
        decode_frame(byte);
        expect("byte 0xAA content", byte === 8'haa);

        // two bytes pushed back-to-back through the FIFO
        @(negedge clk); a_data = 8'h00; a_valid = 1'b1;
        @(negedge clk); a_data = 8'hff;
        @(negedge clk); a_valid = 1'b0;
        decode_frame(byte); expect("byte 0x00 content", byte === 8'h00);
        decode_frame(byte); expect("byte 0xFF content", byte === 8'hff);

        // idle line is high (mark) between frames
        #(2 * BIT);
        expect("idle high between frames", a_tx === 1'b1);

        $display("tb_dbg_console: phase B - console messages");
        b_rst_n = 1'b0; ev_boot = 0; ev_rom_ok = 0; ev_inmenu = 0; ev_outmenu = 0; rom_error = 2'd0;
        repeat (5) @(posedge clk);
        b_rst_n = 1'b1;

        // out of reset: boot tag (build id; the device build re-sends it every ~2 s).
        // want_len is chars + 1 (the \n), like every other call in this bench.
        recv_line("AW 1042z up\n", 12);

        // pack loaded, then game running.
        // Events are level-latched by the console every cycle they are high, so
        // each pulse must span exactly one sampling edge: set on a negedge,
        // clear on the next (one posedge in between).
        @(negedge clk); ev_rom_ok = 1'b1;
        @(negedge clk); ev_rom_ok = 1'b0;
        recv_line("pack loaded ok\n", 15);
        @(negedge clk); ev_boot = 1'b1;
        @(negedge clk); ev_boot = 1'b0;
        recv_line("game running\n", 13);

        // rom_error edges, all three codes
        rom_error = 2'd1; repeat (3) @(posedge clk);
        recv_line("ROM ERR: bad trailer\n", 21);
        rom_error = 2'd2; repeat (3) @(posedge clk);
        recv_line("ROM ERR: psram overflow\n", 23);
        rom_error = 2'd3; repeat (3) @(posedge clk);
        recv_line("ROM ERR: bad directory\n", 23);
        rom_error = 2'd0;

        // menu navigation both ways
        @(negedge clk); ev_inmenu = 1'b1;
        @(negedge clk); ev_inmenu = 1'b0;
        recv_line("in menu\n", 8);
        @(negedge clk); ev_outmenu = 1'b1;
        @(negedge clk); ev_outmenu = 1'b0;
        recv_line("resumed\n", 8);

        // priority: two events in the same cycle -> ok before run
        @(negedge clk); ev_rom_ok = 1'b1; ev_boot = 1'b1;
        @(negedge clk); ev_rom_ok = 1'b0; ev_boot = 1'b0;
        recv_line("pack loaded ok\n", 15);
        recv_line("game running\n", 13);

        // ---- phase C: extended CHK line format, quiet instance, fast stat ----
        c_rst_n = 1'b0;
        repeat (5) @(posedge clk);
        c_rst_n = 1'b1;
        recv_line_c("AW 1044a up\n", 12);     // dut_c takes the defaults: BUILD_ID 1044, suffix 'a'
        // C<err>:<32 hex chk> W<match>/<all> S<status> - the loader counters
        recv_line_c("C0:00000000000000000000000000000000 deadbeef/00080000 S4000 Daaaa Bbbbb Ncccc Rdddd P5678 V00012c F0fa00 L01d4c Y001255d3 X75 Z.0 1a2b3c4d/1a2b3c4d G25 E00\n", 156);

        if (errors == 0) $display("tb_dbg_console: -> PASS");
        else             $display("tb_dbg_console: -> FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
