`ifndef TRACE_LEFT
`define TRACE_LEFT 0   // +define+TRACE_LEFT=24 to watch the chip accesses
`endif
// -----------------------------------------------------------------------------
// Behavioural model of one Pocket cellular PSRAM chip (ZBT SRAM), for simulation.
//
// Not part of the core: nothing here goes into the bitstream. It models the
// FITTED PART's protocol, not the controller's convenience - that is the whole
// point. The first version of this model accepted whatever the controller did
// (any WE# pulse width, data available exactly one cycle after ADV), so a
// controller that violated the part's real timings passed every simulation and
// then sat on amber/red screens on hardware (2026-10-10/11). The timings below
// are the same datasheet values the known-good Pocket core (agg23 SNES
// psram.sv, MIT) is built around:
//
//   * the address is latched on the ADV# falling edge (CE# low);
//   * a write commits only when WE# rises after having been held low for at
//     least T_WP cycles - a shorter pulse is silently lost, exactly as on
//     hardware;
//   * **UB#/LB# are output enables.** OE# low is not enough to make the part drive
//     DQ: with a byte enable high that byte is in "output deselect" and stays
//     high-Z, per byte. Every known-good driver for this part (agg23's
//     analogue-pocket-utils ip/mem/psram.sv) asserts both enables for reads, and
//     this model used to ignore them - which is precisely why a controller that
//     left them deselected on reads passed all 510 checks in here and echoed its own
//     address back on hardware (builds 1030-1033, T=f000). A bus that nobody drives
//     keeps what was last on it, and the last thing is always the address;
//   * read data appears on DQ while OE# is low and a byte enable is low, one cycle
//     after OE# falls (the part's access time) and no sooner than T_AA after the
//     ADV# edge - where T_AA includes what the FPGA's own pins cost, see below;
//   * WAIT is not a functional pin on the fitted part (its known-good
//     neighbours never read it). force_wait remains as a test hook only: a
//     controller must complete its accesses whether or not it is held.
//
// 4 MiWords x 16 = 8 MB, which is one chip (two dies behind CE0#/CE1#, address
// bit 21 selecting between them). clk is the simulation timebase (the part's
// own CLK pin is held low by the controller and plays no part here).
//
// Run with:  scripts/sim_rom.sh          (see cores/aw/src/sim/)
// -----------------------------------------------------------------------------
`timescale 1ns/10ps

module aw_psram_model (
    input  wire        clk,
    input  wire [5:0]  a,
    inout  wire [15:0] dq,
    input  wire        adv_n,
    input  wire        cre,
    input  wire        ce0_n,
    input  wire        ce1_n,
    input  wire        oe_n,
    input  wire        we_n,
    input  wire        ub_n,
    input  wire        lb_n,
    output reg         wait_hi     // test hook only - see the header
);

    localparam WORDS = 1 << 22;         // 4M words = 8 MB
    // WE# low pulse width the part requires to commit a write (t_wp = 45 ns),
    // converted to cycles of the controller's sequence clock. The model samples
    // once per cycle, so this is a ceiling - and if the clock ever changes and
    // this underestimates, writes are lost exactly as on hardware, which is the
    // point of the model. (At 92.8125 MHz / 10.77 ns that is 5; aw_psram holds 6.)
    parameter T_WP_NS = 45,
              CLK_PERIOD_PS = 10774;
    localparam T_WP = (T_WP_NS * 1000 + CLK_PERIOD_PS - 1) / CLK_PERIOD_PS;

    reg [15:0] mem [0:WORDS-1];
    reg [21:0] addr;
    reg        addr_valid;

    // ---- the part -----------------------------------------------------------
    reg        we_n_d, adv_n_d;
    reg [3:0]  we_low_cnt;             // cycles WE# has been low (saturating)
    reg [15:0] wr_shadow;              // DQ as seen while WE# is low - the part captures
    reg [1:0]  wr_be_shadow;           // its write data and byte enables during the pulse,
                                       // not after it (the controller releases all of them
                                       // on the same edge)

    // Read data appears one cycle after OE# falls (tCO) AND only once the part has
    // had its full access time from ADV# low (tAA, datasheet max 70 ns) - and the
    // access time is counted in the currency a datasheet means: nanoseconds between
    // PINS. The controller's ADV# does not fall on its clock edge; it leaves the
    // FPGA ~7.4 ns later (measured clock-to-pin on the cram0 outputs) plus ~1 ns of
    // trace, and the controller's capture is owed ~2.5 ns of setup plus ~1 ns back.
    // So a capture on sequence edge N only asks the part for N x period - 12 ns, and
    // the earliest legal N is ceil((tAA + 12) / period) = 8 at 92.8125 MHz. The old
    // T_AA = floor(70/period) = 6 let a seven-cycle read pass here while the real
    // part, at its own pins, had 63 ns of a 70 ns budget: 7 ns short, in every
    // simulation, cheerfully.
    //
    // One more cycle of pessimism is built in by the quantisation itself (the model
    // only sees pins on clock edges), so the earliest capture this model accepts is
    // edge 9 = 96.9 ns against a true legal 83 ns. Being late to say "legal" is the
    // right direction for a model of a part that has already fooled us twice.
    parameter T_AA_NS = 70,
              // clock-to-pin + traces out + trace back + capture setup
              T_PIN_NS = 13;
    localparam T_AA = (T_AA_NS * 1000 + T_PIN_NS * 1000 + CLK_PERIOD_PS - 1)
                      / CLK_PERIOD_PS;               // ceil: 8 at 92.8125 MHz
    reg [3:0]  adv_age;            // cycles since the last ADV# falling edge
    reg [1:0]  read_drive;         // per byte: 1 = this half of DQ is being driven
    reg [15:0] read_data;
    // Per-byte drive, because that is what the part does: a deselected byte of a
    // selected read floats, it does not read as zero and it does not read as X.
    assign dq = { read_drive[1] ? read_data[15:8] : 8'hzz,
                  read_drive[0] ? read_data[7:0]  : 8'hzz };

    // The first `TRACE_LEFT chip accesses are printed, which is how the write path is
    // diagnosed at all: compile with +define+TRACE_LEFT=24 to see them. Nothing
    // downstream can tell "the address is wrong" apart from "the write never happened" -
    // a controller that writes nothing can still read back exactly what it expects.
    integer trace_left = `TRACE_LEFT;

    wire ce_any = ~ce0_n | ~ce1_n;

    always @(posedge clk) begin
        if (trace_left > 0) begin
            if (~adv_n && ce_any) begin
                $display("  psram %0t ADV addr=%0h ce0=%b ce1=%b",
                         $time, {~ce0_n, a[4:0], dq}, ce0_n, ce1_n);
                trace_left = trace_left - 1;
            end else if (ce_any) begin
                $display("  psram %0t DATA addr=%0h dq=%0h we_n=%b oe_n=%b lb=%b ub=%b",
                         $time, addr, dq, we_n, oe_n, lb_n, ub_n);
                trace_left = trace_left - 1;
            end
        end

        adv_n_d <= adv_n;
        we_n_d  <= we_n;

        // tAA runs from the ADV# falling edge through the whole access - but ADV#
        // itself goes back high one cycle later (the pulse), so "while ADV# is low"
        // would reset this count immediately. Count from the edge instead; it
        // saturates harmlessly, because every new access starts with a fresh fall.
        if (!adv_n && adv_n_d)
            adv_age <= 4'd1;
        else if (adv_age != 4'hF)
            adv_age <= adv_age + 4'd1;

        if (!we_n && ce_any) begin
            wr_shadow    <= dq;        // whatever the bus carries while the pulse is on
            wr_be_shadow <= {~ub_n, ~lb_n};
        end

        if (we_n || !ce_any)
            we_low_cnt <= 4'd0;
        else
            we_low_cnt <= (we_low_cnt == 4'hF) ? 4'hF : we_low_cnt + 4'd1;

        // address multiplexed on the data bus, latched on the ADV# falling edge;
        // the die bit comes from the chip select that is asserted
        if (!adv_n && adv_n_d && ce_any) begin
            addr       <= {~ce0_n, a[4:0], dq};
            addr_valid <= 1'b1;
        end

        // a write commits when WE# rises, and only if the pulse was wide enough -
        // a too-short pulse is lost without a trace, as on the real part. The data
        // captured is what the bus carried during the pulse (wr_shadow), because by
        // the edge after the rise the controller has already released the bus.
        if (!we_n_d && we_n && addr_valid && we_low_cnt >= T_WP) begin
            if (wr_be_shadow[0]) mem[addr][7:0]  <= wr_shadow[7:0];
            if (wr_be_shadow[1]) mem[addr][15:8] <= wr_shadow[15:8];
        end

        // while OE# is low, an address is latched, and at least one byte enable is
        // low, the part drives the bus - one cycle after OE# fell (tCO) AND only once
        // tAA has elapsed since ADV# went low; for as long as all of it holds.
        //
        // The -1 is the quantisation rule in action: the falling edge is seen one
        // cycle late (pins are only visible on clock edges), so adv_age reads one
        // less than the true cycle count. Without it, data would appear on DQ only
        // after the very posedge a legal controller samples it - losing a race the
        // real chip does not lose, because its DQ transition lands mid-cycle.
        //
        // {~ub_n, ~lb_n} is the whole point of the byte enables on a read: enable one
        // of them and only that byte is driven, enable neither and the part is in
        // output deselect and the bus keeps whatever the controller last put on it.
        if (!oe_n && addr_valid && ce_any && (adv_age >= T_AA - 1)
            && (~ub_n | ~lb_n)) begin
            read_data  <= mem[addr];
            read_drive <= {~ub_n, ~lb_n};
        end else begin
            read_drive <= 2'b00;
        end
    end

    // ---- test hook ---------------------------------------------------------------
    // Hold this high from the testbench: on the fitted part this pin idles high and is
    // not a handshake, so a correct controller must complete its accesses anyway. It
    // exists to keep that requirement tested - see aw_psram's header for the two
    // hardware runs that established it.
    reg force_wait = 1'b0;
    always @(*) wait_hi = force_wait;

    // start in a known-but-clearly-not-a-pack state, so that a core which reads
    // before loading shows up as a trailer failure rather than looking correct
    initial begin : fill
        integer i;
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'h5A5A;
    end

endmodule
