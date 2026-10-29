`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// Four-state contention check, for Icarus Verilog (and any other 4-state sim).
//
// The main suite runs on Verilator, which is two-state: if the controller and the
// chip ever drive DQ at the same time with different values, Verilator resolves
// the net to one of them silently and every test passes. On hardware that is a bus
// fight - exactly the kind of thing the 2026-10-12 red screen (ERR_TRAILER) was
// suspected of. This bench exists so that class of bug fails in simulation: it
// counts every cycle DQ carries an X, and it round-trips data through the exact
// sequences the design uses on silicon:
//
//   phase 1: eight CHAINED writes - wr_req held high while each access runs, so
//            every take after the first happens on the previous release edge
//            (S_LAST), with DQ transitioning data->address on that same edge;
//   phase 2: eight reads one at a time, quiesced between them (the S_IDLE path);
//   phase 3: eight reads back-to-back with rd_req held high (the parked-in-idle
//            read path - reads never chain, each parks one cycle after cleanup).
//
// It is deliberately plain Verilog-2005: Icarus refuses the SystemVerilog array
// slices tb_write.sv uses, so this file must stay free of them.
// -----------------------------------------------------------------------------

module tb_iv_check;

    reg clk = 1'b0;
    always #5.3872 clk = ~clk;      // 92.8125 MHz sequence clock (10.77 ns)

    reg         rst     = 1'b1;
    reg         wr_req  = 1'b0;
    reg  [21:0] wr_addr = 22'd0;
    reg  [15:0] wr_data = 16'd0;
    reg  [1:0]  wr_be   = 2'b0;
    reg         rd_req  = 1'b0;
    reg  [21:0] rd_addr = 22'd0;
    reg  [20:0] rd_tag  = 21'd0;

    wire        wr_ready, rd_ready;
    wire [15:0] rd_q;
    wire        rd_q_valid;
    wire [20:0] rd_tag_q;

    wire [5:0]  a;
    wire [15:0] dq;
    wire        adv_n, cre, ce0_n, ce1_n, oe_n, we_n, ub_n, lb_n, psram_clk;

    aw_psram dut (
        .clk(clk), .rst(rst),
        // st_cfg MUST be driven: it is the self-test's control-signal search input,
        // and leaving it floating makes (st_cfg == 2'd2) undefined, which propagates
        // X into CE0#/CE1#. The chip model then sees ce_any = x, decides the chip is
        // not selected, and never drives DQ - so every read "returns z" and none of
        // this file's contention checks mean anything. Normal operation is 0.
        .st_cfg(2'd0),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_be(wr_be),
        .wr_ready(wr_ready),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_tag(rd_tag), .rd_ready(rd_ready),
        .rd_q(rd_q), .rd_q_valid(rd_q_valid), .rd_tag_q(rd_tag_q),
        .psram_wait(1'b1),
        .psram_a(a), .psram_dq(dq), .psram_adv_n(adv_n), .psram_cre(cre),
        .psram_ce0_n(ce0_n), .psram_ce1_n(ce1_n), .psram_oe_n(oe_n),
        .psram_we_n(we_n), .psram_ub_n(ub_n), .psram_lb_n(lb_n),
        .psram_clk(psram_clk)
    );

    aw_psram_model chip (
        .clk(clk), .a(a), .dq(dq), .adv_n(adv_n), .cre(cre),
        .ce0_n(ce0_n), .ce1_n(ce1_n), .oe_n(oe_n), .we_n(we_n),
        .ub_n(ub_n), .lb_n(lb_n), .wait_hi()
    );

    // ---- the check that exists for this file to exist -----------------------
    // Any X on DQ means two drivers were active at once. Count each cycle it
    // happens; even one is a protocol bug, however clean everything else looks.
    integer x_cycles = 0;
    reg x_traced = 1'b0;
    // Verilog-2005 idiom for "any bit is undefined": a defined bit b always
    // satisfies b | ~b == 1, an undefined one does not. ($isunknown is SystemVerilog.)
    // All-Z (both drivers off) is the legal idle state of the bus and must not count;
    // any X - two drivers disagreeing, or a driver carrying an uninitialised value -
    // is a bug. Counted only after reset: before it, every register is legitimately X.
    always @(posedge clk) begin
        if (!rst && ((dq | ~dq) !== 16'hFFFF) && (dq !== 16'hzzzz)) begin
            x_cycles = x_cycles + 1;
            if (!x_traced) begin
                x_traced = 1'b1;
                $display("  X at t=%0t: dq=%h ctl_drive=%b ctl_out=%h chip_drive=%b chip_data=%h oe=%b adv=%b we=%b ce0=%b ce1=%b",
                         $time, dq,
                         dut.dq_drive, dut.dq_out,
                         chip.read_drive, chip.read_data,
                         oe_n, adv_n, we_n, ce0_n, ce1_n);
            end
        end
    end

    integer errors = 0;
    reg [15:0] expect;
    integer i;

    task check_word;
        input [15:0] want;
        begin
            if (rd_q !== want) begin
                errors = errors + 1;
                $display("  FAIL t=%0t tag=%h got=%h want=%h", $time, rd_tag_q, rd_q, want);
            end
        end
    endtask

    // watchdog: a handshake that never completes must fail the run, not hang it
    initial begin
        #1_000_000;
        $display("tb_iv_check: FAIL - timed out (a handshake never completed)");
        $finish;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (8) @(posedge clk);

        // ---- phase 1: chained writes -----------------------------------------
        // req held high the whole time and the payload advanced on the TAKE, so takes
        // 2..8 land on the previous access's release edge (S_LAST) - the DQ
        // data->address transition on that same edge is the thing being looked at.
        //
        // Two rules this file now follows, both learned the hard way:
        //
        //   * advance the payload on the handshake, not on a fixed cycle count. The
        //     old "new pair every six cycles" tested something no producer does -
        //     aw_rom holds wr_req/wr_addr/wr_data stable until wr_ready - and with a
        //     seven-cycle access a six-cycle step skips payloads instead of chaining
        //     them, so it reported lost writes about a controller that was fine;
        //   * drive the stimulus with nonblocking assignments. A blocking assignment
        //     in a process woken by @(posedge clk) races the design's own always
        //     block at that edge (Icarus runs them in arbitrary order), and the
        //     failure looked exactly like a controller bug: the model latched one
        //     access's address with the NEXT access's data on its write bus.
        wr_be   <= 2'b11;
        for (i = 0; i < 8; i = i + 1) begin
            wr_addr <= 22'h00100 + i * 4'd4;
            wr_data <= 16'hA000 + i[15:0];
            wr_req  <= 1'b1;
            @(posedge clk);
            while (!wr_ready) @(posedge clk);      // this edge is the take
        end
        wr_req  <= 1'b0;
        repeat (20) @(posedge clk);      // let the last access finish

        // ---- phase 2: reads, quiesced between --------------------------------
        // The request comes down on the take, not one edge later: the FSM parks in
        // S_IDLE the cycle it captures, so a rd_req still standing up at the edge
        // after rd_q_valid issues a second identical read, and every later iteration
        // waits on the wrong pulse. That showed up as reads lagging one address behind
        // their tags, 5a5a (never written) in the last slot, and a "want" in the
        // failure line belonging to the next iteration.
        for (i = 0; i < 8; i = i + 1) begin
            rd_addr <= 22'h00100 + i * 4'd4;
            rd_tag  <= 21'h100 + i;
            rd_req  <= 1'b1;
            @(posedge clk);
            while (!rd_ready) @(posedge clk);      // this edge is the take
            rd_req  <= 1'b0;
            wait (rd_q_valid);
            @(posedge clk);                        // let the capture's NBA batch land
            check_word(16'hA000 + i[15:0]);
            if (rd_tag_q !== (21'h100 + i[20:0])) begin
                errors = errors + 1;
                $display("  FAIL tag t=%0t got=%h want=%h", $time, rd_tag_q, 21'h100 + i[20:0]);
            end
            repeat (10) @(posedge clk);
        end

        // ---- phase 3: reads back-to-back, req held high -----------------------
        // each read parks one idle cycle after cleanup (reads never chain); the
        // next take must come from that idle state, not from a release edge.
        //
        // Timing note: wait() resumes in the same timestep the valid pulse is set and
        // the next take happens on the very next clock edge, so the next payload is
        // posted here, nonblocking - it lands in this timestep's NBA batch, which is
        // over before that next edge, and rd_q (updated in the same batch as
        // rd_q_valid) is read one delta later so the check cannot see the previous
        // access's value.
        rd_req  <= 1'b1;
        rd_addr <= 22'h00100;
        rd_tag  <= 21'h200;
        for (i = 0; i < 8; i = i + 1) begin
            wait (rd_q_valid && (rd_tag_q == (21'h200 + i[20:0])));
            #0;                                  // after the NBA batch, same timestep
            check_word(16'hA000 + i[15:0]);
            if (i < 7) begin
                rd_addr <= 22'h00100 + (i + 1) * 4'd4;
                rd_tag  <= 21'h200 + (i + 1);
            end
        end
        rd_req  <= 1'b0;
        repeat (20) @(posedge clk);

        if (x_cycles != 0) begin
            errors = errors + 1;
            $display("  FAIL DQ carried X for %0d cycle(s): controller and chip drove it together", x_cycles);
        end

        if (errors == 0)
            $display("tb_iv_check: 24 accesses, 0 X cycles on DQ -> PASS");
        else
            $display("tb_iv_check: %0d error(s) -> FAIL", errors);
        $finish;
    end

endmodule
