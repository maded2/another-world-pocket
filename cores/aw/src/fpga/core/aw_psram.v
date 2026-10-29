// -----------------------------------------------------------------------------
// Another World / Pocket - controller for one cellular PSRAM chip (cram0).
//
// The Pocket's cellular RAM is an asynchronous ZBT SRAM: 16 bits wide, address
// multiplexed onto the data bus behind ADV#, two dies per chip selected by
// CE0#/CE1# (top address bit = die select), no refresh and no init sequence.
//
// The protocol below is the one in agg23's known-good Pocket PSRAM driver
// (https://github.com/agg23/analogue-pocket-utils, ip/mem/psram.sv, MIT) - the same
// part on the same Pocket mainboard, carrying cartridge save RAM today - with the
// part's datasheet timings made explicit instead of assumed, and with the two places
// where this design needs something different spelled out under DEVIATIONS below.
//
// THE BYTE ENABLES ARE OUTPUT ENABLES TOO. UB#/LB# low do not merely open a write
// lane: on this family of parts they gate the output drivers as well, and OE# low
// with both of them high is *output deselect* - the part obeys the address and
// drives nothing. The reference asserts both of them for reads, held from the ADV#
// edge through the capture. This controller asserted them only for writes, and that
// alone accounts for everything the hardware has said since build 1027: the part was
// deselected, the bus floated, and a floating bus keeps whatever was last driven on
// it - the address. Which is exactly what every self-test probe reported, on both
// dies, at every timing (T=f000 = the low 16 bits of its own scratch address, builds
// 1030-1033). No read-timing theory is needed once you see that.
//
//   * the chip's CLK pin is held LOW. The part runs in async mode; the first
//     version drove it from a 49.5 MHz clock and the fitted chip simply did
//     not respond on hardware (2026-10-11). Because the sequence is timed in
//     nanoseconds, not chip cycles, it may run on any fast clock - the
//     reference times its sequence at 133 MHz. This design uses the PLL's
//     92.8125 MHz output (VCO/8, 10.77 ns/cycle): fast enough that a seven-cycle
//     write (75.4 ns, two chained = 150.8 ns per 32-bit bridge word) stays under the
//     161.7 ns a paced upload sustains, slow enough that this fabric's ~7.4 ns
//     clock-to-pin on the cram0 outputs still settles inside a period with
//     room to spare (123.75 MHz failed STA on exactly those paths). The step
//     up from 82.5 was forced by hardware: at six cycles per access the read
//     sampled 72.7 ns after ADV# with OE# low for only two cycles, and the
//     fitted part had not driven DQ yet - reads came back as the address that
//     had just been on the bus (build 1031's self-test: T=f000).
//   * WAIT (cram0_wait) is NOT used. The known-good core declares the pin and
//     never reads it: on the fitted part it idles high, so counting it latched
//     a false ERR_WAIT 1.3 ms after boot (2026-10-10), and gating the count by
//     bus activity did not help because it is high during accesses too
//     (2026-10-11). The pin is not a handshake on this part; data integrity is
//     the trailer check's job, not WAIT's.
//   * writes hold WE# low from the trigger through a pulse of at least t_wp
//     (45 ns) and complete at least t_aw (70 ns) after ADV# went low; write
//     data reaches the bus one full cycle after the address is released, so its
//     setup before WE# rises clears t_dw (20 ns) with cycles to spare. The
//     first version pulsed WE# for a single 20.2 ns cycle - under half t_wp.
//   * reads hold OE# low and sample the bus only after the part's max access
//     time (70 ns from ADV# low) - measured at the PINS, not at the FPGA's clock
//     edge. ADV# leaves this fabric 7.4 ns after the edge that changed it (measured
//     clock-to-pin on these paths) plus ~1 ns of trace, and the capture register is
//     owed ~2.5 ns of setup plus ~1 ns back, so a capture on sequence edge N really
//     asks the part for (N x 10.77 - 12) ns. N=7 - build 1032's shape, which every
//     simulation passed - asked 63 ns of a part whose budget starts at 70. Reads now
//     run twelve cycles: the capture lands 129.3 ns after the ADV# edge, ~117 ns of
//     window at the pins against a 70 ns maximum, with OE# low for ~86 ns of that
//     (the reference gets ~60 ns and works, so this is not where the story was - but
//     it is no longer a datasheet violation waiting for a slower part or a corner).
//
// DEVIATIONS from the reference, both deliberate:
//
//   1. Read length. The reference samples thirty 7.51 ns cycles (225 ns) after ADV#;
//      it is cartridge save RAM and nothing about it is rate-limited. Here a read is
//      twelve cycles plus the idle cycle it parks in = 140 ns per word, against the
//      80.8 ns a gapless VM fill consumes per word. The difference is covered by
//      aw_rom's stream FIFO, which must hold >= 32 prefilled words before a held
//      fill may start (its prefill gate) while the producer adds ~18 more during the
//      2.5 us of the fill itself. Copying the reference's thirty cycles would need
//      ~80 words buffered for the same margin, for no timing gain.
//   2. Write chaining. The reference keeps at least one fully deasserted cycle
//      between every access. Here a write may start on the previous write's release
//      edge (see S_LAST), which is what keeps the loader ahead of a paced upload.
//      On hardware this is inert - the bridge delivers a word about every 75 clk_74a
//      cycles (~1 us), so the load FIFO is empty and nothing chains.
//
// Every parameter below carries at least a full cycle of margin at 10.77 ns,
// and scripts/sim_write.sh runs against aw_psram_model, which enforces these
// same timings - including the byte enables as output enables, and a tAA measured
// from the ADV# pin edge with this fabric's clock-to-pin and capture setup added
// in. A controller that shortcuts any of them fails in simulation instead of on
// the device.
//
// Reads are NOT chained, and that is deliberate: can_start (below) only allows a
// new access from S_IDLE or off a write's release edge, so every read parks in idle
// for one full cycle after cleanup - exactly the gap the reference keeps between
// every access. That gap is what lets the part finish releasing DQ (tOE,
// unpublished) before the next address appears; chaining a read would put the new
// address on the bus on the same edge OE# rises, with both drivers briefly active
// while the part latches its address. The cost is one cycle per read: twelve cycles
// plus the park = 140 ns per word, which the stream FIFO absorbs rather than the
// chip (DEVIATIONS 1); tb_rom streams every access pattern the VM uses at this rate,
// including the 63-byte gapless fill that is the tightest thing on this bus.
// -----------------------------------------------------------------------------
`default_nettype none

module aw_psram (
    input  wire             clk,        // 92.8125 MHz sequence clock (10.77 ns)
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

    input  wire             psram_wait, // not used - see the header
    // Self-test control-signal search (aw_rom drives it; 0 = normal operation).
    // Each nonzero mode re-runs the scratch round-trip with one control assumption
    // flipped, so a hardware readback names which one is wrong:
    //   2: the OTHER physical die (normal "die 0" accesses assert CE1#; this asserts
    //      CE0#) - is one die dead and the other fine? A pure board-level polarity
    //      flip cannot explain total silence: exactly one CE# is always low, so an
    //      inverted board would just swap which die answers and still round-trip.
    //   3: CRE high instead of low - does async mode want CRE asserted?
    // Mode 1 used to be "byte enables held low through the read", which was the
    // suspected fault; the reference comparison found it is what the part requires
    // (they are output enables), so it is now unconditional here and the slot is
    // retired - aw_rom gives probe B a different job (byte-lane write mask).
    input  wire [1:0]       st_cfg,

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

    // Access shape (cycles of 10.77 ns each at 92.8125 MHz; see the header for the
    // ns values). Both start identically; they differ only in how long the data
    // phase runs, because only the read is racing the part's access time:
    //
    //   write:  ADV pulse | bus free | data out | hold data + WE#          | release
    //           E0        E1         E2         E3..E6                     E7  (75.4 ns)
    //   read:   ADV pulse | bus free | OE# low  | part drives ................
    //           E0        E1         E2         E3..........................E11 sample
    //                                                     + release      E12  (129.3 ns)
    //
    // Seven cycles per write, twelve per read. Both byte enables are asserted for a
    // read as well as a write - on this part they gate the output drivers, and with
    // both high the part is deselected and never drives DQ at all (see the header;
    // that was the read bug behind every address-echoing readback on hardware).
    //
    // An earlier note here claimed the known-good reference samples at ~75 ns with
    // OE# low for ~45 ns, and that is what made a seven-cycle read look validated.
    // It was a misreading: the reference's read states run from READ_INITIAL_COUNT=20
    // to STATE_READ_DATA_RECEIVED = 20 + TOTAL_READ_CYCLE_COUNT = 30, so it samples
    // thirty cycles (225 ns at 133 MHz) after ADV# and holds OE# low for eight of
    // them (~60 ns). Its read is deliberately unhurried. Twelve cycles here gives
    // ~117 ns of access window at the chip pins against a 70 ns maximum and ~86 ns
    // of OE# hold, i.e. more OE# time than the reference and 47 ns of tAA margin,
    // while still being 1.6x faster than the reference per word so the VM's stream
    // stays fed from a 64-word FIFO instead of a 256-word one.
    //
    // Back-to-back: when a WRITE finishes and another request is already waiting,
    // its setup happens on the release edge itself - seven cycles per access makes
    // two chained accesses 14 cycles = 150.8 ns per 32-bit bridge word, which is
    // what keeps the load FIFO draining faster than a paced upload fills it.
    // Only writes chain: the part never drives DQ on a write, so there is nothing
    // to wait for. Reads park one idle cycle after cleanup (see the header).
    // Last S_DATA cycle before the release/write-commit (E6 for a write, E11 for a
    // read): the read is the longer one purely because of tAA.
    localparam [3:0] HOLD_WRITE = 4'd3,   // E3..E6 -> capture at E7  (75.4 ns)
                     HOLD_READ  = 4'd8;   // E3..E11 -> capture at E12 (129.3 ns)

    localparam S_IDLE  = 3'd0,   // all chip signals deasserted
               S_ADV   = 3'd1,   // ADV# low; address on DQ; (write) WE#/BE asserted
               S_GAP   = 3'd2,   // bus free: address released, data/OE not out yet
               S_DATA  = 3'd3,   // write: data on DQ. read: OE# low, part driving
               S_LAST  = 3'd4;   // one cycle before release/sample

    reg [2:0]  state;
    reg [3:0]  data_cnt;          // counts the S_DATA hold (E3..E6 / E3..E11)
    reg [15:0] wdata;
    reg        is_write;
    reg [20:0] tag_cur;           // tag of the access in progress

    // A new access can start from idle, or - for a write that just finished - on
    // its own release edge (see the back-to-back note above).
    wire can_start = (state == S_IDLE) || (state == S_LAST && is_write);
    assign wr_ready = can_start;
    assign rd_ready = can_start && !wr_req;

    wire take_wr = wr_req &&  wr_ready;
    wire take_rd = rd_req &&  rd_ready;
    wire take    = take_wr | take_rd;
    wire [21:0] req_addr = take_wr ? wr_addr : rd_addr;

    // the data bus carries the address during the ADV phase and write data during
    // the write phase; tri-stated otherwise so the part can drive a read result
    reg        dq_drive;
    reg [15:0] dq_out;

    // Die select. Bit 21 of the word address picks the die, and also rides the A[5]
    // pin exactly as the reference drives cram_a[21:16]; the CE# pair is what the
    // part actually selects on. Normally die 0 = CE1#, die 1 = CE0#; the self-test's
    // mode-2 probe swaps them, and it has to swap them on the chained-start path
    // too - both places now read these one pair of wires instead of each spelling
    // the polarity out again (the chained path used to ignore st_cfg outright, a
    // latent bug the self-test never reached because its accesses are 450 ms apart).
    wire ce0_sel = (st_cfg == 2'd2) ?  req_addr[21] : ~req_addr[21];
    wire ce1_sel = (st_cfg == 2'd2) ? ~req_addr[21] :  req_addr[21];

    assign psram_dq  = dq_drive ? dq_out : 16'hzzzz;
    // The fitted part runs in async mode and its known-good neighbours hold this
    // pin low (see the header); driving it from clk left the chip not responding.
    assign psram_clk = 1'b0;

    always @(posedge clk) begin
        rd_q_valid <= 1'b0;
        psram_cre  <= (st_cfg == 2'd3);   // low normally (as in the reference); mode 3 tests high

        if (rst) begin
            state       <= S_IDLE;
            data_cnt    <= 4'd0;
            dq_drive    <= 1'b0;
            rd_q_valid  <= 1'b0;
            rd_tag_q    <= 21'd0;
            tag_cur     <= 21'd0;
            psram_a     <= 6'd0;
            psram_adv_n <= 1'b1;
            psram_oe_n  <= 1'b1;
            psram_we_n  <= 1'b1;
            psram_ce0_n <= 1'b1;
            psram_ce1_n <= 1'b1;
            psram_ub_n  <= 1'b1;
            psram_lb_n  <= 1'b1;
        end else begin
            case (state)
            // ------------------------------------------------------------------
            // Nothing on the bus. All chip signals deasserted - including CE#,
            // which the first version left asserted after the first access.
            S_IDLE: begin
                psram_adv_n <= 1'b1;
                psram_oe_n  <= 1'b1;
                psram_we_n  <= 1'b1;
                psram_ce0_n <= 1'b1;
                psram_ce1_n <= 1'b1;
                psram_ub_n  <= 1'b1;
                psram_lb_n  <= 1'b1;
                dq_drive    <= 1'b0;
                if (take) begin
                    wdata     <= wr_data;
                    is_write  <= take_wr;
                    tag_cur   <= rd_tag;
                    // All six address pins carry addr[21:16], exactly as the known-good
                    // reference does (die select rides on CE#; bit 21 also lands on A[5]).
                    // The earlier {1'b0, addr[20:16]} was identical for die 0 but wrong
                    // for die 1, which the self-test below exercises.
                    psram_a     <= req_addr[21:16];
                    psram_ce0_n <= ce0_sel;      // mode 2 swaps the dies (see above)
                    psram_ce1_n <= ce1_sel;
                    dq_out      <= req_addr[15:0];
                    dq_drive    <= 1'b1;
                    psram_adv_n <= 1'b0;          // ADV pulse starts now (t_vp)
                    if (take_wr) begin
                        // from the stable input, not a register: this is the trigger cycle,
                        // and a register set in this same block still holds its old value -
                        // which is how the first write after reset lost both bytes. WE# goes
                        // low one cycle later, in S_ADV (see there).
                        psram_ub_n <= ~wr_be[1];
                        psram_lb_n <= ~wr_be[0];
                    end else begin
                        // A READ asserts both byte enables too, on the same edge as
                        // CE# and the address, and holds them until the capture. They
                        // are output enables on this part: leave either one high and
                        // the chip sits out the read in "output deselect", which is
                        // every silent readback this design has ever produced. The
                        // reference does exactly this (STATE_NONE, read branch).
                        psram_ub_n <= 1'b0;
                        psram_lb_n <= 1'b0;
                    end
                    state       <= S_ADV;
                end
            end

            // ------------------------------------------------------------------
            // ADV pulse done: ADV# high. CE# went low a cycle earlier, which clears
            // t_cvs (7 ns); the address was stable before the pulse (t_avs) and
            // stays on the bus for a full cycle after it (t_avh), so it is released
            // in S_GAP, not here.
            //
            // A write's WE# goes low HERE, one cycle after the trigger - not on the
            // trigger edge itself. That one cycle of WE# high between the release of
            // one chained write and this assertion is what separates their pulses: a
            // ZBT part commits a write when WE# rises, so two back-to-back writes with
            // no gap in between are one long pulse and only the second commits.
            // The budgets still clear: the pulse is six cycles = 64.6 ns >= t_wp (45),
            // and WE# rises 75.4 ns after ADV# went low >= t_aw (70).
            S_ADV: begin
                psram_adv_n <= 1'b1;
                if (is_write) psram_we_n <= 1'b0;  // held low until cleanup
                state       <= S_GAP;
            end

            // ------------------------------------------------------------------
            // The address is off the bus now; one full cycle of silence, as the
            // reference keeps between the unlatch and whatever comes next (its
            // "data/OE after addr unlatch" margins - guesses, not spec).
            S_GAP: begin
                dq_drive <= 1'b0;
                data_cnt <= 4'd0;
                state    <= S_DATA;
            end

            // ------------------------------------------------------------------
            // First cycle: a write puts its data out (setup before WE# rises is then
            // four cycles = 43.1 ns >= t_dw 20), a read enables the part's outputs
            // (OE# one cycle after the unlatch, clearing the reference's 3 ns guess;
            // the part cannot drive for several cycles yet - tCO - so no fight).
            // After that: hold until the access has had its full time. The hold is
            // what build 1031 lacked: two cycles of OE# (24.2 ns at the old clock)
            // sampled a bus the part had not driven yet, and the read came back as
            // the address that had just been on it. Reads hold it to E11 rather than
            // E6 so the capture at E12 clears tAA at the pins, not just on paper -
            // see the header's pin-level arithmetic.
            S_DATA: begin
                if (data_cnt == 4'd0) begin
                    if (is_write) begin
                        dq_out   <= wdata;
                        dq_drive <= 1'b1;
                    end else begin
                        psram_oe_n <= 1'b0;       // OE# low: the part starts driving
                    end
                end
                // E6 for a write (release at E7), E11 for a read (capture at E12)
                if (data_cnt == (is_write ? HOLD_WRITE : HOLD_READ)) state <= S_LAST;
                else                       data_cnt <= data_cnt + 4'd1;
            end

            // ------------------------------------------------------------------
            // Release, and start the next access on this same edge if one is waiting.
            //
            // Write: WE# has been low since E1: six cycles = 64.6 ns >= t_wp (45),
            // and the write completes 75.4 ns after ADV# went low >= t_aw (70).
            // Data has been stable since E3, so its setup before WE# rises is four
            // cycles = 43.1 ns >= t_dw (20) - counted from when it first appeared.
            // Read: sample now - 129.3 ns after the ADV# edge, which is ~117 ns
            // measured at the part's pins against its 70 ns maximum, with OE# low for
            // ~86 ns of it (the reference's proven values are 225 ns and ~60 ns) -
            // and release.
            S_LAST: begin
                if (!is_write) begin
                    rd_q       <= psram_dq;
                    rd_q_valid <= 1'b1;
                    rd_tag_q   <= tag_cur;
                    psram_oe_n <= 1'b1;
                end
                psram_we_n  <= 1'b1;
                psram_ub_n  <= 1'b1;
                psram_lb_n  <= 1'b1;
                psram_ce0_n <= 1'b1;
                psram_ce1_n <= 1'b1;
                dq_drive    <= 1'b0;

                if (take) begin
                    // Back-to-back, writes only: take_rd cannot be high here, because
                    // rd_ready needs can_start, which is false in S_LAST of a read -
                    // reads always park in idle for the tOE gap (see the header).
                    wdata     <= wr_data;
                    is_write  <= take_wr;
                    tag_cur   <= rd_tag;
                    psram_a     <= req_addr[21:16];
                    psram_ce0_n <= ce0_sel;
                    psram_ce1_n <= ce1_sel;
                    dq_out      <= req_addr[15:0];
                    dq_drive    <= 1'b1;
                    psram_adv_n <= 1'b0;
                    if (take_wr) begin
                        // WE# follows one cycle later, in S_ADV - same reason as the
                        // idle path above: chained pulses must not merge.
                        psram_ub_n <= ~wr_be[1];
                        psram_lb_n <= ~wr_be[0];
                    end else begin
                        // Defensive: reads cannot reach S_LAST's take today (see the
                        // note above), but if that ever changes, a read started here
                        // must get its byte enables low just like the S_IDLE path, or
                        // it comes back deselected and silent.
                        psram_ub_n <= 1'b0;
                        psram_lb_n <= 1'b0;
                    end
                    state       <= S_ADV;
                end else begin
                    state       <= S_IDLE;          // nothing queued: park
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
