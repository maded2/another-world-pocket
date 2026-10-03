// -----------------------------------------------------------------------------
// AW Pocket: pack ROM
//
// The original design keeps the executable in a 2 MB SPI flash read over quad-SPI.
// The Pocket has no user-addressable flash, so the host uploads the pack into the
// cellular PSRAM through the APF bridge, and this module turns it back into the byte
// stream the VM expects. It also owns the PSRAM controller, because both paths it
// serves use that one chip.
//
//   loader :  APF bridge (clk_74a) -> async FIFO -> PSRAM writes
//   reader :  PSRAM reads -> async FIFO -> byte stream with the VM's handshake
//
// The reader must reproduce what spiflash_rom_core presents to vm.si, and the two
// callers there disagree more than they look:
//
//   readByte() (vm.si:55)
//       mem.in_ready = 1;                 // one cycle
//       ++:
//       while (mem.busy) { mem.in_ready = 0; }
//       mem.addr = mem.addr + 1;
//   so a single byte is requested by a one-cycle pulse and is then awaited with
//   in_ready LOW. A reader that only delivers while in_ready is high hangs here -
//   and busy must still be high when the caller first tests it, one cycle after the
//   pulse, which is sooner than any memory can answer. Hence mem_busy has a
//   combinational term in the request itself; see below.
//
//   the 64-byte preload (vm.si:483)
//       mem.in_ready = 1;
//       while (data.addr != 63) {
//           data.addr    = data.wenable ? (data.addr + 1) : 0;
//           data.wenable = mem.data_available;
//       }
//   so a held in_ready means "stream bytes, one per data_available cycle", and -
//   because a cycle without data_available resets the write pointer to 0 - once a
//   byte has been delivered the rest of the fill must be gapless, or the VM writes
//   later bytes at the start of its buffer. This port mirrors that reset: a gap
//   rewinds this reader's address too (see gap below). That is what makes a stall
//   harmless instead of silently corrupting the thread's instruction buffer.
//
// "Stop when in_ready falls" cannot retract a read already issued to the chip, so the
// reader over-fetches. Each acceptance carries a generation number, every word in the
// stream FIFO is tagged with the generation that fetched it (the tag rides through
// the PSRAM controller with the read, so it survives any stretching), and the
// consumer discards anything not tagged current.
//
// That replaces flushing the FIFO per acceptance, which deadlocks: the flush needs
// the producer to stop writing, the producer stops once the FIFO has drained, and the
// FIFO drains only once the consumer starts delivering, which it was waiting for the
// flush to finish in order to do. A first version of this file had exactly that
// deadlock; tb_rom showed it as zero bytes in two million cycles.
//
// No transfer-complete signal can be relied on either. This APF revision does have
// dataslot_allcomplete from core_bridge_cmd, but a plain file dropped into a bridge
// window need not be accompanied by the command that produces it, so completion is
// also inferred: writes reached the trailer area and then went quiet. The check is
// retried, because the only real proof that the pack is complete is that the trailer
// reads back sensibly, and that is also what holds the design in reset until then.
// -----------------------------------------------------------------------------

`default_nettype none

module aw_rom (
    // ---- design clock: the byte stream, on the clock the VM runs on ----
    input  wire        clk_core,
    input  wire        rst_core,        // active high, synchronous release

    // ---- the contract the VM proper expects ----
    /* verilator lint_off UNUSEDSIGNAL */
    // Bits 23:21 are unused on purpose: the pack is 2 MB and vm.si never addresses
    // past it (its largest constant is (1<<21)-32), so the window is the whole
    // address space the VM can name.
    input  wire [23:0] mem_addr,
    // The VM's request, and whether the VM is out of reset.
    //
    // Both are needed. M_main drives out_mem_in_ready *high while held in reset* (it is
    // the VM's default "I am ready for a byte", not something its reset clears), and
    // core_top holds that reset until this module says rom_ready. Taken on its own, the
    // request therefore says the VM wants a byte from before the pack exists: the reader
    // starts streaming, competes with the loader for the ZBT, the load never finishes, and
    // the design reports the bridge overrunning. tb_soc found this; nothing else could,
    // because it needs the VM, the ROM and the reset sequencing in the same simulation.
    //
    // So a request counts only when the VM is running. Until then the only thing that
    // drives this reader is the internal boot check.
    input  wire        vm_running,
    input  wire        mem_in_ready,
    output reg  [7:0]  mem_data,
    output reg         mem_data_available,   // one cycle per byte
    output wire        mem_busy,             // no byte yet; see the busy note above
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- PSRAM clock domain ----
    input  wire        clk_psram,
    input  wire        rst_psram,

    // ---- APF bridge: the pack arrives here, 32-bit words ----
    input  wire        clk_bridge,
    input  wire        rst_bridge,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    input  wire        dataslot_allcomplete,

    // ---- status ----
    output reg         rom_ready,            // pack present and trailer sane
    output reg  [1:0]  rom_error,            // 0 none, 1 bad trailer, 2 overflow, 3 partial
    output wire        rom_loading,

    // ---- the chip ----
    output wire [5:0]  cram0_a,
    inout  wire [15:0] cram0_dq,
    input  wire        cram0_wait,
    output wire        cram0_clk,
    output wire        cram0_adv_n,
    output wire        cram0_cre,
    output wire        cram0_ce0_n,
    output wire        cram0_ce1_n,
    output wire        cram0_oe_n,
    output wire        cram0_we_n,
    output wire        cram0_ub_n,
    output wire        cram0_lb_n
);

    localparam [1:0] ERR_NONE     = 2'd0;
    localparam [1:0] ERR_TRAILER  = 2'd1;
    localparam [1:0] ERR_OVERFLOW = 2'd2;
    localparam [1:0] ERR_WAIT     = 2'd3;   // the chip has not accepted anything

    // The pack is 2 MB minus a 16-byte trailer, and that trailer sits at
    // (1<<21)-32 = 0x1FFFE0: it is the first thing vm.si ever reads (vm.si:366) and
    // the first thing checked here. It holds four little-endian uint32 offsets,
    // which the VM reads one byte at a time, shifting each into the top of a 128-bit
    // word, so the first byte read ends up in [7:0].
    localparam [23:0] TRAILER_ADDR = 24'h1fffe0;

    // The VM's preload wants an unbroken run of 63 data_available cycles. 32 words
    // covers that run with a byte to spare.
    // (declared with the FIFO below, so that its width matches rd_level exactly)

    // ================================================================ loader ===
    // The bridge can write a 32-bit word per cycle; the chip takes a 16-bit word per
    // two cycles, so anything faster has to wait. There is no flow-control signal
    // from this bridge revision, so the only defence is a wide buffer plus a tripwire
    // that says out loud when bytes were dropped.
    localparam LWIDTH = 21 + 32;                 // word address, then data
    localparam LDB    = 9;                       // 512 entries = 64 KB in flight

    wire              ld_full;
    wire              ld_empty;
    wire [LWIDTH-1:0] ld_q;
    wire              ld_rd;
    wire              ld_abort;

    // lint_off: outputs left unobserved on purpose. The loader takes a whole entry
    // out at a time and never needs levels, and rd_q_valid would just repeat rd_en.
    /* verilator lint_off PINCONNECTEMPTY */
    aw_fifo #(.DW(LWIDTH), .AW(LDB)) u_ldfifo (
        .wr_clk     (clk_bridge),
        .wr_rst     (rst_bridge),
        .wr_en      (bridge_wr & (bridge_addr[31:21] == 11'h080) & ~ld_abort),
        .wr_data    ({bridge_addr[20:0], bridge_wr_data}),
        .wr_full    (ld_full),
        .wr_free    (),
        .rd_clk     (clk_psram),
        .rd_rst     (rst_psram),
        .rd_en      (ld_rd),
        .rd_q_valid (),
        .rd_q       (ld_q),
        .rd_level   (),
        .rd_empty   (ld_empty)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    reg         ld_overflow;      // the bridge outran the drain: bytes were dropped

    // An entry carries a 32-bit word's address, so its payload bytes are at
    // {word address, byte 0..3} and the byte offset inside the word is ld_q[33:32].
    wire [20:0] ld_baddr = ld_q[LWIDTH-1 -: 21];
    wire [31:0] ld_data  = ld_q[31:0];
    wire [1:0]  ld_ba    = ld_q[33:32];

    // Only overflow aborts the drain. A trailer that does not make sense must NOT:
    // the usual reason for that is an upload still in progress, and aborting would
    // guarantee it never finishes.
    assign ld_abort = ld_overflow;

    // ---------------------------------------------------------------------------
    // What the bridge has done, judged in the bridge's own clock.
    //
    // bridge_wr is a one-cycle pulse in clk_74a. Sampling it from clk_psram - which
    // the first version of this file did - misses it or invents it, since the two
    // clocks are asynchronous. So the facts are latched here and only the resulting
    // levels cross.
    // ---------------------------------------------------------------------------
    reg ld_overflow_b, ld_trailer_b, ld_quiet_b;
    reg [19:0] quiet_cnt_b;

    always @(posedge clk_bridge) begin
        if (rst_bridge) begin
            ld_overflow_b <= 1'b0;
            ld_trailer_b  <= 1'b0;
            ld_quiet_b    <= 1'b0;
            quiet_cnt_b   <= 20'd0;
        end else begin
            // A full FIFO in the middle of a transfer is normal. A FIFO that stays
            // full while the host keeps writing means the drain cannot keep up, and
            // silently dropping program bytes is the worst failure this module could
            // have: the game would boot into a screen of garbage. There is no
            // flow-control signal on this bridge, so this is the only defence.
            if (ld_full && bridge_wr) ld_overflow_b <= 1'b1;

            if (bridge_wr) begin
                // at or past the last 32 bytes, which covers the trailer
                if (bridge_addr[20:5] >= 16'hFFFF) ld_trailer_b <= 1'b1;
                quiet_cnt_b <= 20'd0;
                ld_quiet_b  <= 1'b0;
            end else if (quiet_cnt_b >= 20'd742500) begin      // ~10 ms at 74.25 MHz
                ld_quiet_b <= 1'b1;
            end else begin
                quiet_cnt_b <= quiet_cnt_b + 20'd1;
            end
        end
    end

    reg [1:0] ov_s;
    always @(posedge clk_psram) ov_s <= {ov_s[0], ld_overflow_b};
    wire seen_overflow = ov_s[1];
    // ld_trailer_b and ld_quiet_b are needed where the check is issued, in clk_core,
    // and are synchronised there rather than relayed through this domain.

    // ---------------------------------------------------------------------------
    // Drain state machine.
    //
    // The write request is presented combinationally from the state and the FIFO
    // head and held until the controller takes it. That is not stylistic: the first
    // version asserted a registered one-cycle request after seeing ready high, which
    // loses the write whenever ready is low on the cycle the pulse arrives - and in
    // simulation, where the memory is always ready, that bug is invisible.
    //
    // One entry takes four cycles (pop, then two chip accesses with one wait cycle
    // between them), which is about 40 MB/s: the ceiling of a x16 ZBT part accessed
    // with an address phase, and comfortably above what the bridge sustains in
    // practice. The straddling case takes four byte-masked writes instead, which is
    // four times slower - the host writes sequentially from address 0, so aligned
    // entries are the norm and straddling is the exception.
    // ---------------------------------------------------------------------------
    localparam D_IDLE = 2'd0, D_ARM = 2'd1, D_RUN = 2'd2;

    reg  [1:0] d_state;
    reg  [1:0] d_step;                 // which piece of the current entry is out
    reg        d_odd;                  // entry straddles a word boundary
    reg        ld_rd_q;

    // Pieces, in order: an aligned entry is two whole words; a straddling entry is
    // four byte-masked writes.
    //
    // The mapping both paths use: byte address A of the pack lives in word A[20:1],
    // byte lane A[0]. (Bit 21 of the word address is die select and stays 0 - a 2 MB
    // pack fits in one of the two dies, and the other die is left alone.) The first
    // version of this block wrote words at the byte address instead of the byte
    // address shifted right by one, which is a different mapping from the reader's:
    // every read would have returned the byte two addresses away, and the only reason
    // that is not obvious from the boot check is that the trailer happened to read
    // back offsets that still looked plausible.
    wire        d_act    = (d_state == D_RUN);
    wire [19:0] ld_w0    = ld_baddr[20:1];                 // word holding byte 0
    wire [20:0] d_byaddr = ld_baddr + {19'd0, d_step};     // this byte's address
    wire        d_lane   = d_byaddr[0];
    wire [7:0]  d_byte   = ld_data[{d_step, 3'd0} +: 8];   // payload byte d_step
    // 1 = write that lane. An aligned whole word is therefore 2'b11, not 2'b00: the
    // first version used 00 here, which with ub_n/lb_n = ~be disabled both lanes and
    // so wrote nothing at all, while every read still looked correct.
    wire [1:0]  d_be     = d_odd ? (d_lane ? 2'b10 : 2'b01) : 2'b11;
    wire [21:0] d_addr   = d_odd ? {2'b00, d_byaddr[20:1]}
                                : {2'b00, ld_w0 + {19'd0, d_step[0]}};
    wire [15:0] d_wdata  = d_odd ? (d_lane ? {d_byte, 8'h00} : {8'h00, d_byte})
                                : (d_step[0] ? ld_data[31:16] : ld_data[15:0]);
    wire        d_last   = d_odd ? (d_step == 2'd3) : (d_step == 2'd1);

    // write side of the chip, driven straight from the state above
    wire        wr_ready;
    wire        wr_taken = wr_req & wr_ready;
    reg         wr_req;
    reg  [21:0] wr_addr;
    reg  [15:0] wr_wdata;
    always @(*) begin
        wr_req   = d_act & ~ld_abort;
        wr_addr  = d_addr;
        wr_wdata = d_wdata;
    end
    assign ld_rd = ld_rd_q;

    always @(posedge clk_psram) begin
        if (rst_psram) begin
            d_state   <= D_IDLE;
            d_step    <= 2'd0;
            d_odd     <= 1'b0;
            ld_rd_q   <= 1'b0;
            ld_overflow <= 1'b0;
        end else begin
            ld_rd_q <= 1'b0;
            if (seen_overflow) ld_overflow <= 1'b1;

            case (d_state)
            // wait for data, and take it out of the FIFO as soon as we can: the
            // registered FIFO output appears the cycle after the read
            D_IDLE: if (!ld_empty && !ld_abort) begin
                ld_rd_q <= 1'b1;
                d_state <= D_ARM;
            end

            // the entry is now on ld_q; work out which shape it is and start
            D_ARM: begin
                d_step  <= 2'd0;
                d_odd   <= (ld_ba != 2'b00);
                d_state <= D_RUN;
            end

            // hold the request up; the controller accepts it whenever it is idle or
            // at the data phase of the access in progress, so this chains at the
            // chip's own rate
            D_RUN: if (wr_taken) begin
                if (d_last) begin
                    d_state <= D_IDLE;
                end else begin
                    d_step  <= d_step + 2'd1;
                end
            end

            default: d_state <= D_IDLE;
            endcase
        end
    end

    // ================================================================ reader ===
    // PSRAM reads -> stream FIFO -> the VM's byte stream.
    //
    // Two rules shape this, and both come from how the VM consumes.
    //
    // 1) Every FIFO entry carries the address it was read from, and the consumer uses a
    //    word only if its address is the one it is at. The earlier version stamped
    //    entries with a per-acceptance generation counter instead; the consumer's copy and
    //    the producer's are in different clock domains, kept in step by a pulse, and there
    //    are two things that restart a stream (a new acceptance and a rewind), so a
    //    restart could be missed by the producer while the consumer had already moved on -
    //    after which no tag ever matches and the ROM looks dead with busy held high.
    //    Addresses are not counted, so they cannot drift: a word either is or is not the
    //    one being asked for.
    //
    //    The tag is 21 bits, not 20. The producer speculatively runs past the end of the
    //    2 MB window and the consumer is meant to discard those words; with 20 bits,
    //    0x100000 aliases onto 0x00000 and the first word read outside the pack was handed
    //    out as byte 0 of it.
    //
    // 2) The VM's gap rule (vm.si:483): a cycle without data_available during the 64-byte
    //    preload resets the buffer's write pointer. So a mid-stream stall is not merely
    //    slow, it invalidates everything already delivered - which means the reader must
    //    (a) not start a held stream until a whole fill is buffered, and (b) when it does
    //    stall anyway, restart at the address the acceptance started, because that is what
    //    the VM is about to do with its own pointer. Rewinding is one-shot: c_served
    //    clears, and a continuing absence of data does not re-trigger it.
    //
    // Look-ahead is deliberately small (LOOKAHEAD, a little over one 64-byte fill) rather
    // than "fill the FIFO", for two reasons. Seeking past stale words costs one cycle per
    // word, so a deep buffer makes every restart expensive - the first version buffered
    // 256 words and spent tens of thousands of cycles discarding them before a single
    // byte. And at full rate the producer supplies exactly one word per core cycle while
    // the consumer takes exactly one word per core cycle: the buffer is the entire margin,
    // so what matters is having a fill's worth of it, not having a lot of it.
    //
    // The FIFO's read is registered (rd_en at T puts the word on rd_q at T+1, per
    // aw_fifo's header), hence the two stages: n_word is the prefetched next word, c_word
    // the one handing out bytes. The hand-off may take the landing word directly, in the
    // cycle c_word runs out; without that bypass there is an empty cycle every two bytes,
    // which the preload reads as a restart - forever.
    localparam TW      = 21;                      // address tag bits, see above
    localparam SWIDTH  = TW + 16;
    localparam SDB     = 6;                       // 64 words: one fill plus slack

    wire [SDB:0]      sf_free;
    wire              sf_empty;
    wire [SDB:0]      sf_level;
    wire [SWIDTH-1:0] sf_q;

    // A held acceptance must not gap once it has started. 32 words covers the 63 the
    // preload asks for, with a byte to spare.
    localparam [SDB:0] PREFILL_WORDS = 1 << 5;
    // Stop fetching a little past a fill. FETCH_HEADROOM covers the reads already in
    // flight, so the producer can be left running while the consumer uses what it has.
    localparam [SDB:0] LOOKAHEAD      = (1 << 5) + 8;
    localparam [SDB:0] FETCH_HEADROOM = 7;

    reg               sf_wr;
    reg  [SWIDTH-1:0] sf_wdata;
    reg               sf_rd;

    /* verilator lint_off PINCONNECTEMPTY */
    aw_fifo #(.DW(SWIDTH), .AW(SDB)) u_sfifo (
        .wr_clk     (clk_psram),
        .wr_rst     (rst_psram),
        .wr_en      (sf_wr),
        .wr_data    (sf_wdata),
        .wr_full    (),
        .wr_free    (sf_free),
        .rd_clk     (clk_core),
        .rd_rst     (rst_core),
        .rd_en      (sf_rd),
        .rd_q_valid (),
        .rd_q       (sf_q),
        .rd_level   (sf_level),
        .rd_empty   (sf_empty)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Shared between the reader's two halves, declared here because the file sets
    // `default_nettype none` and they refer to each other across a clock boundary.
    wire         c_run;
    reg          chk_active;
    reg          chk_pending;
    reg          chk_kick;
    reg          chk_done;
    reg  [4:0]   chk_cnt;
    reg  [127:0] chk_data;   // sixteen bytes, shifted in at the top as vm.si does it, so
                             // offset n is a little-endian uint32 at [32n +: 32]

    // ------------------------------------------------ producer (clk_psram) ----
    wire        rd_req;
    wire [21:0] rd_addr;
    wire        rd_ready;
    wire [15:0] rd_q;
    wire        rd_q_valid;
    wire [TW-1:0] rd_addr_q;

    reg  [21:0] start_addr_r;   // word address of the current stream; written at the
                                // acceptance and unchanged while c_run is low
    reg  [2:0]  run_s;
    always @(posedge clk_psram) run_s <= {run_s[1:0], c_run};
    wire p_start = run_s[1] & ~run_s[2];
    wire p_allow = run_s[2] & (sf_free >= FETCH_HEADROOM) & (sf_level <= LOOKAHEAD);

    assign rd_req  = p_allow;
    assign rd_addr = p_addr;

    reg  [21:0] p_addr;
    wire        rd_taken = rd_req & rd_ready;

    always @(posedge clk_psram) begin
        if (rst_psram) begin
            p_addr   <= 22'd0;
            sf_wr    <= 1'b0;
            sf_wdata <= {SWIDTH{1'b0}};
        end else begin
            sf_wr <= 1'b0;
            if (p_start) begin
                p_addr <= start_addr_r;
            end else if (rd_taken) begin
                p_addr <= p_addr + 22'd1;
            end
            if (rd_q_valid) begin
                sf_wr    <= 1'b1;
                sf_wdata <= {rd_addr_q, rd_q};   // the address the controller read
            end
        end
    end

    // ------------------------------------------------ consumer (clk_core) -----
    // C_GAP exists for the producer's benefit: the restart is a rising edge on c_run seen
    // through a two-flop synchroniser, so the low phase must outlast two producer cycles.
    // The shortest honest gap - run, idle one core cycle, run again - is exactly two of
    // them, which is not a margin, and gets missed often enough to show up in simulation.
    // C_SEEK is the state where the reader is looking for the word it is at: it pops every
    // cycle and ignores what does not match, which is what keeps a restart cheap.
    localparam [1:0] C_IDLE = 2'd0, C_GAP = 2'd1, C_SEEK = 2'd2, C_RUN = 2'd3;

    reg  [1:0]  c_state;
    reg  [1:0]  gap;
    reg  [20:0] c_addr;                 // next byte this reader owes
    reg  [20:0] c_start;
    reg         c_served;
    reg         c_v;
    reg  [15:0] c_word, n_word;
    reg  [TW-1:0] c_waddr, n_addr;
    reg         n_v, pend;
    reg         busy_q;

    assign c_run = (c_state == C_SEEK) || (c_state == C_RUN);

    wire req = mem_in_ready & vm_running;

    reg  [1:0] inr;
    always @(posedge clk_core) inr <= {inr[0], req};

    // The boot check drives this same machine from the inside. It only runs while
    // rom_ready is low and the design holds the VM in reset until then, but a VM
    // acceptance still outranks it: the check is idempotent, a swallowed acceptance hangs
    // the VM with busy held high.
    wire accept_vm = inr[0] & ~inr[1];
    wire accept    = accept_vm | chk_kick;
    wire [20:0] acc_addr = chk_kick ? TRAILER_ADDR[20:0] : mem_addr[20:0];

    wire host_rdy = chk_active ? (chk_cnt != 5'd0) : inr[0];

    wire          landing   = pend;
    wire [TW-1:0] land_addr = sf_q[SWIDTH-1 -: TW];
    wire [15:0]   land_word = sf_q[15:0];

    wire [TW-1:0] want_word = {1'b0, c_addr[20:1]};        // word the next byte lives in
    wire [TW-1:0] next_word = c_waddr + {{(TW-1){1'b0}}, 1'b1};

    wire prefill_ok = chk_active | ~inr[0] | (sf_level >= PREFILL_WORDS);
    wire want       = c_run & (host_rdy | ~c_served);

    wire word_ok = c_v & (c_waddr == want_word);
    wire take    = (c_state == C_RUN) & want & word_ok & (c_served | prefill_ok);
    wire [7:0] c_byte = c_addr[0] ? c_word[15:8] : c_word[7:0];
    wire exhausted  = take & c_addr[0];

    // prefetch is kept only if it is the word that comes after the one handing out
    wire n_keep     = n_v & (n_addr == next_word);
    wire handoff    = exhausted & (n_keep | (landing & (land_addr == next_word)));
    // wanted a byte, cannot deliver one: the VM's fill pointer is about to reset, so
    // this reader restarts at the address the acceptance began
    wire rewind     = (c_state == C_RUN) & want & c_served & ~take & ~handoff;

    wire pop = c_run & ~sf_empty & ~pend & ((c_state == C_SEEK) | ~n_v);

`ifdef READ_TRACE
    always @(posedge clk_core) begin
        if (accept)  $display("  R%0t ACCEPT addr=%h", $time, acc_addr);
        if (rewind)  $display("  R%0t REWIND from=%h", $time, c_addr);
        if (landing) $display("  R%0t LAND addr=%h word=%h st=%0d want=%h lvl=%0d",
                              $time, land_addr, land_word, c_state, want_word, sf_level);
        if (take)    $display("  R%0t TAKE addr=%h byte=%h cw=%h tag=%h lvl=%0d n_v=%b",
                              $time, c_addr, c_byte, c_word, c_waddr, sf_level, n_v);
        if (chk_kick) $display("  R%0t CHK_KICK", $time);
    end
`endif

    always @(posedge clk_core) begin
        if (rst_core) begin
            c_state      <= C_IDLE;
            gap          <= 2'd0;
            c_addr       <= 21'd0;
            c_start      <= 21'd0;
            start_addr_r <= 22'd0;
            c_v          <= 1'b0;
            c_served     <= 1'b0;
            c_word       <= 16'd0;
            c_waddr      <= 21'd0;
            n_word       <= 16'd0;
            n_addr       <= 21'd0;
            n_v          <= 1'b0;
            pend         <= 1'b0;
            busy_q       <= 1'b0;
            mem_data     <= 8'd0;
            mem_data_available <= 1'b0;
            sf_rd        <= 1'b0;
            chk_cnt      <= 5'd0;
            chk_data     <= {128{1'b0}};
        end else begin
            sf_rd              <= 1'b0;
            mem_data_available <= 1'b0;

            if (accept) begin
                c_start      <= acc_addr;
                start_addr_r <= {2'b0, acc_addr[20:1]};
                c_addr       <= acc_addr;
                c_v          <= 1'b0;
                n_v          <= 1'b0;
                c_served     <= 1'b0;
                c_state      <= C_GAP;
                gap          <= 2'd2;
                // busy_q is the VM-facing "a transaction is in flight" flag, so only a VM
                // acceptance may set it. `accept` is also the boot check's own kick (accept =
                // accept_vm | chk_kick), and setting busy_q for that left busy asserted when
                // the check finished: the consumer parks in C_IDLE, the only clear lives on
                // the running path (busy_q <= host_rdy), and host_rdy needs inr[0], which
                // needs the VM to leave `while (mem.busy) {}` - which busy_q was holding it
                // inside. Deadlock, measured: busy_q=1 chk_active=0 c_state=0 in_ready=0.
                // It went unnoticed because the VM used to be running during the load (the
                // garbage boot), so a real acceptance always came along to clear it.
                busy_q       <= accept_vm;
            end else if (rewind) begin
                c_addr       <= c_start;
                start_addr_r <= {2'b0, c_start[20:1]};
                c_v          <= 1'b0;
                n_v          <= 1'b0;
                c_served     <= 1'b0;
                c_state      <= C_GAP;
                gap          <= 2'd2;
            end else if (c_state == C_GAP) begin
                // Always to C_SEEK, never cancelled by the caller having dropped
                // in_ready: readByte() raises it for one cycle and then waits for busy,
                // so by the time a gap has run out host_rdy is always low for a single
                // byte, and honouring it here lost every pulsed read. An acceptance is
                // over when its byte has been delivered and the caller is not asking for
                // more - the rule below - not when in_ready happens to be low.
                if (gap != 2'd0) gap <= gap - 2'd1;
                else             c_state <= C_SEEK;
            end else if (c_run & c_served & ~host_rdy) begin
                c_state  <= C_IDLE;
                c_v      <= 1'b0;
                n_v      <= 1'b0;
                c_served <= 1'b0;
            end

            if (pop) sf_rd <= 1'b1;
            pend <= pop;

            // a word pulled last cycle arrives, with the address it was read from
            if (landing) begin
                if (c_state == C_SEEK) begin
                    // the sought word: hand it out from next cycle
                    if (land_addr == want_word) begin
                        c_word  <= land_word;
                        c_waddr <= land_addr;
                        c_v     <= 1'b1;
                    end
                end else if (!n_v | ~n_keep) begin
                    n_word <= land_word;
                    n_addr <= land_addr;
                    n_v    <= 1'b1;
                end
            end

            // byte out
            if (take) begin
                mem_data <= c_byte;
                c_served <= 1'b1;
                c_addr   <= c_addr + 21'd1;
                if (!chk_active) mem_data_available <= 1'b1;
                else begin
                    // Shifted in at the top, exactly as vm.si does it (segOffsets =
                    // {mem.data, segOffsets[8,...]}): the first byte read ends up in
                    // [7:0], so each offset is already a little-endian uint32 at
                    // chk_data[32n +: 32]. Shifting at the bottom leaves them
                    // byte-reversed - and the trailer reads back perfectly, which is what
                    // makes that mistake so hard to see: the check then reports
                    // 3844341760 where 9445 belongs.
                    chk_data <= {c_byte, chk_data[127:8]};
                    chk_cnt  <= chk_cnt - 5'd1;
                end
                // busy follows the caller: a held acceptance keeps it high, a pulsed one
                // sees it fall with the byte it was waiting for
                busy_q <= host_rdy;
            end

            // busy_q means "a VM transaction is in flight", so it cannot survive the
            // consumer parking. It used to: on the boot check's sixteenth byte, host_rdy is
            // still (chk_cnt != 0) = 1, so busy_q latched high, and busy_q is only ever
            // updated on `take` - with the check over and the VM held off by that same busy,
            // no further take could arrive. The VM waits in `while (mem.busy) {}`, so the
            // design booted nothing at all: 0 bytes, forever, at 60 Hz.
            if ((c_state == C_IDLE) && !req) busy_q <= 1'b0;

            // driven from here, and only from here, along with chk_data: the check counts
            // its sixteen bytes as the consumer delivers them
            if (chk_kick) chk_cnt <= 5'd16;

            if (handoff) begin
                c_word  <= n_keep ? n_word : land_word;
                c_waddr <= n_keep ? n_addr : land_addr;
                c_v     <= 1'b1;
                n_v     <= n_v & ~handoff & n_keep;
            end

            // a seek that has the word is over; a seek whose caller gave up is not our
            // problem any more
            if ((c_state == C_SEEK) && c_v && (c_waddr == want_word))
                c_state <= C_RUN;
        end
    end

    // busy has a combinational term in the request itself: the caller tests it one cycle
    // after raising in_ready (vm.si:58), sooner than any memory can have answered, so
    // without it readByte() would leave its wait and take a stale byte.
    //
    // And busy has to stay HIGH while the VM is not allowed to run. vm.si opens its boot
    // sequence with `while (mem.busy) {}` and then loads the segment table straight out of
    // mem.data:
    //     while (mem.busy) {}
    //     mem.addr = (1<<21) - 32;  ...  segOffsets = {mem.data, segOffsets[8+:120]};
    // Gating only `req` on vm_running made busy fall to 0 during the pack load, so the wait
    // passed and the VM latched whatever happened to be on the byte bus as its four segment
    // offsets - and then ran forever computing addresses from them. This is what the
    // `in_ready=1 addr=3fffe0 busy=0` line in tb_soc has been reporting since the day it was
    // added, printed and not read: a held-off slave that answers "not busy" is a slave
    // handing out garbage. Holding the reset line does not help either - the VM's reset is
    // wired to 0 inside the generated netlist, which is the whole reason vm_running exists.
    assign mem_busy = busy_q | inr[0] | inr[1] | req | chk_active | ~vm_running;

    // ============================================================ boot check ===
    // Nothing says reliably that an upload has finished: this APF revision does have
    // dataslot_allcomplete from core_bridge_cmd, but a file dropped into a bridge
    // window need not be accompanied by the command that produces it. So a check is
    // requested by any of three things - that command, the trailer area having been
    // written and then writes going quiet, or a slow retry timer - and the check
    // itself is the only real evidence: sixteen bytes read back through the same path
    // the VM will use, whose four offsets have to make sense.
    //
    // The offsets are checked as
    //     off0 == 0, all others in [16, 2 MB], off1 >= off2, off3 >= off1
    // which was verified against all eight extracted packs before being written down
    // (part1: 0, 9445, 4321, 11493 ... part8: 0, 22912, 2886, 24960).
    //
    // Failing does not stop anything: an upload still in progress looks exactly like a
    // bad trailer at the moment it is sampled, so the check is retried until it passes
    // and rom_ready is held low meanwhile, which keeps the VM in reset. A design that
    // started anyway would run the VM over 0x5A5A-filled memory.
    reg  [20:0] retry_cnt;
    reg  [2:0] ac_s;
    reg  [1:0] tr_c, qt_c;

    always @(posedge clk_core) begin
        ac_s <= {ac_s[1:0], dataslot_allcomplete};
        tr_c <= {tr_c[0], ld_trailer_b};
        qt_c <= {qt_c[0], ld_quiet_b};
    end
    wire allc_edge    = ac_s[2] & ~ac_s[1];
    wire pack_written = tr_c[1] & qt_c[1];

    always @(posedge clk_core) begin
        if (rst_core) begin
            chk_active  <= 1'b0;
            chk_pending <= 1'b0;
            chk_kick    <= 1'b0;
            chk_done    <= 1'b0;
            retry_cnt   <= 21'd0;
        end else begin
            chk_kick <= 1'b0;
            chk_done <= 1'b0;

            if (allc_edge | pack_written) chk_pending <= 1'b1;

            // The VM outranks this diagnostic. The check is idempotent and will be
            // requested again; a swallowed acceptance hangs the VM forever, because its
            // readByte() waits on busy and busy is held high while a check is running.
            // In the assembled design the VM sits in reset until a check has passed, so
            // the two should never meet - but the first version assumed that, and a
            // testbench that asks for a byte while a check is in flight got that byte
            // shifted into the check's register instead, with busy never falling.
            if (accept_vm) begin
                chk_active <= 1'b0;
            end
            // chk_cnt itself lives with the consumer, which is what decrements it: two
            // always blocks driving one register is legal Verilog, Verilator tolerates it,
            // and Quartus fails elaboration with "Can't resolve multiple constant drivers"
            // - a simulation/synthesis mismatch that is cheapest avoided by keeping every
            // register driven from exactly one process.
            if (chk_kick) begin
                chk_active <= 1'b1;
            end else if (chk_active && chk_cnt == 5'd1 && take) begin
                chk_active <= 1'b0;
                chk_done   <= 1'b1;          // validate with the complete chk_data
            end

            if (chk_pending && !chk_active && (c_state == C_IDLE) && !rom_ready
                && !req) begin
                chk_kick    <= 1'b1;
                chk_pending <= 1'b0;
                retry_cnt   <= 21'd0;
            end else if (!rom_ready) begin
                retry_cnt <= retry_cnt + 21'd1;
                if (&retry_cnt) chk_pending <= 1'b1;   // ~84 ms at 24.75 MHz
            end
        end
    end

    wire [31:0] off0 = chk_data[31:0];
    wire [31:0] off1 = chk_data[63:32];
    wire [31:0] off2 = chk_data[95:64];
    wire [31:0] off3 = chk_data[127:96];
    wire offs_ok = (off0 == 32'd0)
                 && (off1 >= 32'd16) && (off2 >= 32'd16) && (off3 >= 32'd16)
                 && (off1 <= 32'h200000) && (off2 <= 32'h200000) && (off3 <= 32'h200000)
                 && (off1 >= off2) && (off3 >= off1);

`ifdef CHECK_TRACE
    always @(posedge clk_core) if (chk_done)
        $display("  CHECK data=%h off=[%0d %0d %0d %0d] ok=%b ovf=%b stall=%b",
                 chk_data, off0, off1, off2, off3, offs_ok, seen_overflow, ps_stall);
`endif

    always @(posedge clk_core) begin
        if (rst_core) begin
            rom_ready <= 1'b0;
            rom_error <= ERR_NONE;
        end else begin
            // Overflow is the more actionable of the two fatal reports: it says the
            // drain is too slow, which is a fact about this design, whereas a held
            // WAIT says nothing is moving at all.
            if (ps_stall)    rom_error <= ERR_WAIT;
            if (seen_overflow) rom_error <= ERR_OVERFLOW;
            if (chk_done && !seen_overflow && !ps_stall) begin
                if (offs_ok) begin
                    rom_ready <= 1'b1;
                    // ERR_TRAILER is a diagnosis of the moment, not a verdict: a check
                    // that ran while the host was still writing reports exactly what a
                    // half-written trailer looks like, and must not stay painted once a
                    // later check passes. Overflow and a held WAIT are different - those
                    // say bytes were lost or the chip is dead, and neither gets better by
                    // asking again - so they outlive rom_ready.
                    if (rom_error == ERR_TRAILER) rom_error <= ERR_NONE;
                end else begin
                    rom_error <= ERR_TRAILER;
                end
            end
        end
    end

    // waiting for a pack, rather than waiting for anything else
    assign rom_loading = ~rom_ready;

    // =============================================================== the chip ===
    wire ps_stall;

    aw_psram u_psram (
        .stall_wait  (ps_stall),
        .clk         (clk_psram),
        .rst         (rst_psram),

        .wr_req      (wr_req),
        .wr_addr     (wr_addr),
        .wr_data     (wr_wdata),
        .wr_be       (d_be),
        .wr_ready    (wr_ready),

        .rd_req      (rd_req),
        .rd_addr     (rd_addr),
        .rd_tag      (p_addr[TW-1:0]),  // the address being issued, latched with the read
        .rd_ready    (rd_ready),
        .rd_q        (rd_q),
        .rd_q_valid  (rd_q_valid),
        .rd_tag_q    (rd_addr_q),

        .psram_wait  (cram0_wait),

        .psram_a     (cram0_a),
        .psram_dq    (cram0_dq),
        .psram_adv_n (cram0_adv_n),
        .psram_cre   (cram0_cre),
        .psram_ce0_n (cram0_ce0_n),
        .psram_ce1_n (cram0_ce1_n),
        .psram_oe_n  (cram0_oe_n),
        .psram_we_n  (cram0_we_n),
        .psram_ub_n  (cram0_ub_n),
        .psram_lb_n  (cram0_lb_n),
        .psram_clk   (cram0_clk)
    );

endmodule

`default_nettype wire
