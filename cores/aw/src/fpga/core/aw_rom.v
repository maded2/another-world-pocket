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

    // ---- debug ----
    // The sixteen bytes the last trailer check read back, byte 0 first. core_top
    // renders these on the red screen: a constant pattern (all FF, all 5A...) says
    // the chip is not responding at all, changing garbage says marginal timing,
    // plausible-but-wrong offsets say address corruption.
    output wire [127:0] rom_chk_data,

    // The rest of that photo. The red screen says "the trailer readback is wrong"
    // without saying whether the bytes ever got here; these split it into three
    // different bugs - no writes on the bridge at all, writes rejected by the
    // window filter, or writes accepted but never latched by the chip.
    output wire [31:0] rom_dbg_wr_match,   // host writes with addr[31:21]==0x080
    output wire [31:0] rom_dbg_wr_all,     // every bridge write seen
    output wire [15:0] rom_dbg_status,     // {overflow, allc_seen, last_match[23:10]}
    // Bytes handed to the VM since reset (clk_core domain) - the one honest proxy for
    // "is the VM executing". A running VM takes ROM bytes; one held off, or stuck in
    // while (mem.busy), takes none. 1036a reached C0 with a black screen and nothing
    // in the report told those two apart.
    output reg  [31:0] rom_dbg_rd_bytes,

    // Whole-pack census (see the census block). sum_w is the sum of every 16-bit word the
    // upload wrote; sum_r the sum of the same range read back afterwards; equal means the
    // chip holds the file. qmism says which quarter(s) disagree, and stat is
    // {timeout, done, gap} where gap means the writes were not contiguous from word 0.
    // Worth the silicon because until now the 2 MiB was verified by exactly two reads -
    // word 0 and the trailer - and dbg_wr_match counted addresses in range, not data
    // committed. A corrupt region in the middle of the pack looked identical to a working
    // boot: C0, rom_ready, and a black screen with the VM eating ROM at 9x the normal rate.
    output wire [31:0] rom_census_sum_w,
    output wire [31:0] rom_census_sum_r,
    output wire [3:0]  rom_census_qmism,
    output wire [2:0]  rom_census_stat,

    // PSRAM self-test readbacks (see the selftest block), reported as
    // "D<d> B<b> N<n> R<r> P<p>" on the CHK line. Expected on a living chip:
    //   D : a5a5 - scratch round-trip, normal operation (byte enables asserted on the
    //       read as well as the write, which is what the part needs to drive DQ at all)
    //   B : a55a - the SAME word written again with only the LOW byte enabled, so a
    //       high byte that survived plus a low byte that changed proves both lanes and
    //       the write mask; a whole-word round-trip cannot tell you either of those
    //   N : a5a5 - the OTHER physical die (normal "die 0" accesses assert CE1#)
    //   R : a5a5 - CRE high instead of low
    //   P : pack word 0 as read back through the chip - written by the UPLOAD, never
    //       by us; 0004 for part1.bin means the upload reached PSRAM
    // Every field that instead reads back the address of its own access means the part
    // still is not driving DQ; a5a5 everywhere with a red screen means the read path is
    // fine and the problem is above the chip.
    output reg  [15:0] rom_selftest_die0,
    output reg  [15:0] rom_selftest_be,
    output reg  [15:0] rom_selftest_ceneg,
    output reg  [15:0] rom_selftest_cre,
    output reg  [15:0] rom_selftest_pack0,

    // ---- view page table: which physical 32 KiB page each view page reads from ----
    // Load port for the paged image. Task #18 drives these from the directory loader; until then
    // core_top ties them to 0 and testbenches drive them, so paging is exercised before the boot
    // FSM exists. Leaving the write port out would let synthesis make this a ROM that can never
    // point at another part, which is the entire feature.
    input  wire        tbl_wr,
    input  wire [5:0]  tbl_widx,
    input  wire [7:0]  tbl_wval,
    output wire        rom_tbl_loaded,   // 0 = identity map, i.e. a single plain pack

    // ---- paged-image directory (task #18) -------------------------------------
    // The part is chosen by a write to 0x00F0_00xx, where bits [4:2] ARE the part number and the
    // data written is ignored. Address-selected rather than value-selected on purpose: it makes the
    // decode independent of the 32-bit byte order, which is the one thing about this bridge that
    // cannot be settled from the docs (the loader's byte order is a declaration we make by tying
    // bridge_endian_little, and interact writes are a different writer). Eight `action` variables
    // in interact.json, one per part, drive it; see the note in core_top about why the value is
    // honoured at boot and not mid-session.
    output wire        rom_dir_valid,    // an AWP1 directory was read and its table installed
    output wire        rom_dir_bad,      // the magic was there and the table was not usable
    output wire [2:0]  rom_part,         // the part the installed table describes
    output wire [6:0]  rom_dir_err,      // 0 clean; bit0 no magic; bit1+entry an entry out of range;
                                         // bit6 the sweep was not served in time
    output wire        rom_dir_busy,     // a sweep owns the chip right now
    output wire        rom_pool_ok,      // the chip's pages 1.. equal the pool sum the image claims
    output wire        rom_part_late,    // a part write arrived after the first byte: next launch

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
    localparam [1:0] ERR_WAIT     = 2'd3;   // no longer reachable: WAIT is not a
                                           // functional pin on the fitted part -
                                           // see aw_psram's header

    // The pack is 2 MB minus a 16-byte trailer, and that trailer sits at
    // (1<<21)-32 = 0x1FFFE0: it is the first thing vm.si ever reads (vm.si:366) and
    // the first thing checked here. It holds four little-endian uint32 offsets,
    // which the VM reads one byte at a time, shifting each into the top of a 128-bit
    // word, so the first byte read ends up in [7:0].
    // ---- address map: stated, not assumed ------------------------------------------
    // Upstream flashes the image at 2 MB (`iceprog -o 2M ROMs/$*.raw`; send.py takes
    // 2097152 as the offset) and the SoC presents flash-absolute addresses: the first
    // acceptance after reset release asks for 24'h3fffe0, which is exactly
    // TRAILER_ADDR + PACK_BASE. So mem_addr[23:21] name a 2 MB bank *of the device* and
    // are not part of the image; the pack offset is mem_addr[20:0].
    //
    // There is one image, so aliasing between banks is the specified behaviour rather than
    // a fold that happens to work. Saying so matters: nothing here used to state which
    // bits mean what, and a plausible-looking "fix" that widened the window to 22 bits -
    // or that reported mem_addr[23:21] != 0 as out-of-range, which is what an earlier
    // version of this plan proposed - would move every read by 2 MB, or reject the boot
    // read itself. tb_rom's bank-aliasing checks pin it.
    localparam [23:0] PACK_BASE    = 24'h200000;  // where the image sits in the device
    localparam [23:0] TRAILER_ADDR = 24'h1fffe0;  // pack offset of the 16 offset words

    // The VM's preload wants an unbroken run of 63 data_available cycles. 32 words
    // covers that run with a byte to spare.
    // (declared with the FIFO below, so that its width matches rd_level exactly)

    // ================================================================ loader ===
    // The bridge can write a 32-bit word per cycle; the chip takes a 16-bit word per
    // two cycles, so anything faster has to wait. There is no flow-control signal
    // from this bridge revision, so the only defence is a wide buffer plus a tripwire
    // that says out loud when bytes were dropped.
    // Window is 4 MiB, which is exactly one die: the pool is 128 pages of 32 KiB and word bit 21
    // is the chip's die select, so an upload can never cross dies. It was 2 MiB because that was
    // the whole image; with paged images the directory plus pool is 2.94 MiB and anything the
    // window does not cover is silently dropped at wr_en below - silently, because this bridge
    // revision has no flow control and no "you wrote past my window" signal.
    localparam LWIDTH = 22 + 32;                 // byte address, then data
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
        .wr_en      (bridge_wr & (bridge_addr[31:22] == 12'h040) & ~ld_abort),
        .wr_data    ({bridge_addr[21:0], bridge_wr_data}),
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
    wire [21:0] ld_baddr = ld_q[LWIDTH-1 -: 22];
    wire [31:0] ld_data  = ld_q[31:0];
    // The APF bridge carries the byte destined for the LOWEST address in the MOST
    // significant byte of the 32-bit write. That is the declaration this core makes -
    // core_top ties bridge_endian_little = 0, the template default - and the proven
    // loader in analogue-pocket-utils (ip/data_loader.sv, whose own test runs with
    // bridge_endian_little = 0) maps bridge_wr_data = 32'hAABBCCDD at address C to
    // C<-AA, D<-BB, E<-CC, F<-DD. Hardware confirms it: on build 1035a the first word
    // of part1.bin (bytes 04 00 e7 00) read back from PSRAM word 0 as 16'he700, and
    // the trailer came back as offsets like 3551396608 - the bytes of 0x0003aed3 in
    // the wrong order. Taking the payload little-endian, as this did until then, put
    // every entry's four bytes in reverse while leaving the entries at the right
    // addresses: a whole pack of corrupt data that no simulation could see, because
    // the benches had been feeding the design the order it assumed. See the note in
    // the testbenches' bridge-write tasks - the wire order is now modelled there.
    wire [31:0] ld_wire  = {ld_data[7:0], ld_data[15:8],
                            ld_data[23:16], ld_data[31:24]};
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

    // Debug counters. clk_bridge is clk_74a and dataslot_allcomplete comes from
    // core_bridge_cmd on that same clock, so nothing here crosses a domain.
    reg [31:0]  dbg_wr_match;
    reg [31:0]  dbg_wr_all;
    reg [23:10] dbg_last_match;
    reg         dbg_allc_seen;

    always @(posedge clk_bridge) begin
        if (rst_bridge) begin
            ld_overflow_b <= 1'b0;
            ld_trailer_b  <= 1'b0;
            ld_quiet_b    <= 1'b0;
            quiet_cnt_b   <= 20'd0;
            dbg_wr_match  <= 32'd0;
            dbg_wr_all    <= 32'd0;
            dbg_last_match<= 14'd0;
            dbg_allc_seen <= 1'b0;
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

                dbg_wr_all <= dbg_wr_all + 32'd1;
                if (bridge_addr[31:21] == 11'h080) begin
                    dbg_wr_match   <= dbg_wr_match + 32'd1;
                    dbg_last_match <= bridge_addr[23:10];
                end
            end else if (quiet_cnt_b >= 20'd742500) begin      // ~10 ms at 74.25 MHz
                ld_quiet_b <= 1'b1;
            end else begin
                quiet_cnt_b <= quiet_cnt_b + 20'd1;
            end
            if (dataslot_allcomplete) dbg_allc_seen <= 1'b1;
        end
    end

    reg [1:0] ov_s;
    always @(posedge clk_psram) ov_s <= {ov_s[0], ld_overflow_b};
    wire seen_overflow = ov_s[1];

    assign rom_dbg_wr_match = dbg_wr_match;
    assign rom_dbg_wr_all   = dbg_wr_all;
    // seen_overflow is the clk_psram-synchronised copy of ld_overflow_b; a debug
    // display does not need another synchroniser stage.
    assign rom_dbg_status   = {seen_overflow, dbg_allc_seen, dbg_last_match};
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
    // One aligned entry is two chip accesses. The controller chains them back to
    // back (seven 92.8125 MHz cycles each, see aw_psram), and this machine starts
    // popping the NEXT entry while the second access of the current one is still in
    // flight - the pop and arm hide inside the access window instead of adding two
    // cycles to it. Steady state: 14 cycles per entry = 150.8 ns, against the
    // 161.7 ns a paced upload sustains (PACE=10 in tb_rom). That margin is what
    // keeps the FIFO from filling; an earlier version paid two extra cycles per
    // entry and overflowed on every full pack.
    //
    // The straddling case takes four byte-masked writes instead, which is twice as
    // slow - the host writes sequentially from address 0, so aligned entries are
    // the norm and straddling is the exception.
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
    // byte lane A[0]. (Bit 21 of the word address is die select and stays 0: the 4 MiB window
    // fills die 0 exactly, and die 1 belongs to the self-test.) The first
    // version of this block wrote words at the byte address instead of the byte
    // address shifted right by one, which is a different mapping from the reader's:
    // every read would have returned the byte two addresses away, and the only reason
    // that is not obvious from the boot check is that the trailer happened to read
    // back offsets that still looked plausible.
    // Gated by ~st_active: while the self-test owns the controller, a taken write is
    // the test's - counting it would advance the drain past a pack byte.
    wire        d_act    = (d_state == D_RUN) & ~st_active;
    wire [20:0] ld_w0    = ld_baddr[21:1];                 // word holding byte 0
    wire [21:0] d_byaddr = ld_baddr + {20'd0, d_step};     // this byte's address
    wire        d_lane   = d_byaddr[0];
    wire [7:0]  d_byte   = ld_wire[{d_step, 3'd0} +: 8];   // payload byte d_step
    // 1 = write that lane. An aligned whole word is therefore 2'b11, not 2'b00: the
    // first version used 00 here, which with ub_n/lb_n = ~be disabled both lanes and
    // so wrote nothing at all, while every read still looked correct.
    wire [1:0]  d_be     = d_odd ? (d_lane ? 2'b10 : 2'b01) : 2'b11;
    wire [21:0] d_addr   = d_odd ? {1'b0, d_byaddr[21:1]}
                                : {1'b0, ld_w0 + {20'd0, d_step[0]}};
    wire [15:0] d_wdata  = d_odd ? (d_lane ? {d_byte, 8'h00} : {8'h00, d_byte})
                                : (d_step[0] ? ld_wire[31:16] : ld_wire[15:0]);
    wire        d_last   = d_odd ? (d_step == 2'd3) : (d_step == 2'd1);

    // ================================================================ selftest ===
    // Round-trip probe for the PSRAM path on the fitted part. It exists because every
    // hardware read from build 1027 to 1033 came back as the address this design had
    // just driven onto DQ - on every address, both dies, and every read timing tried.
    // That is the signature of a bus nobody drove (a floating DQ keeps the last value
    // on it), and the cause was found by reading the known-good driver in
    // analogue-pocket-utils against ours: UB#/LB# are output enables on this part, this
    // controller asserted them only for writes, and so the chip spent every read in
    // output deselect. See aw_psram's header; the fix is unconditional now.
    //
    // What is left here is the rest of the "or is something else wrong" question, one
    // assumption per probe, plus a pack-word-0 readback that only matches the file if
    // the UPLOAD committed.
    // Probe word moved to DIE 1, and it had to move: it used to be 22'h100000, "the first word
    // past the pack", which was true only while a pack was 2 MiB. With the upload window at 4 MiB a
    // paged image writes words up to 0x177FFF, so the periodic probe - which WRITES A5A5 and then
    // 5A5A every ~444 us - would have scribbled over frame 64 of any pool that ever got loaded.
    // Nothing failed today only because a single 2 MiB pack still ends below it. Die 1 is free by
    // construction: a 4 MiB window tops out at word 0x1FFFFF, so bit 21 is never set by an upload,
    // and aw_psram already selects the die from that bit (and the CE-inverted probe exercises it).
    localparam [21:0] ST_ADDR_D0  = 22'h3F_FFFF; // die 1, top word: never an upload target
    localparam [21:0] ST_ADDR_P0  = 22'h000000; // pack word 0 - written by the upload, never by us
    localparam [15:0] ST_PAT      = 16'hA5A5;
    // Probe B's pattern, written with the low byte enabled only, on top of the A5A5
    // probe A put in the same word a moment earlier: the readback must be A55A.
    localparam [15:0] ST_PAT_BE   = 16'h5A5A;
    localparam [15:0] ST_PERIOD   = 16'd41_250;   // ~444 us at 92.8125 MHz (counted in IDLE cycles)

    // One round per period: seq 0..3 are scratch round-trips (0 = normal, 1 = the
    // byte-lane/mask probe, 2 = the other die, 3 = CRE high), seq 4 is the pack word 0
    // readback. st_cfg only carries the two flips that live inside aw_psram; probe B is
    // a byte-enable thing and needs none of them.
    localparam [2:0] ST_SEQ_P0 = 3'd4, ST_SEQ_CEN = 3'd5;

    // ================================================================ census ====
    // Is the 2 MiB in the chip the 2 MiB that was sent?
    //
    // The evidence for asking: the first launch after a power-on shows a black screen with
    // F=fa00 (a full window scanned), L=0 (every pixel decoded black) and Y climbing at
    // ~4.6 kB per frame against the healthy ~0.55 kB - a VM executing something, but not the
    // game. Quitting and relaunching works, and the relaunch re-uploads the pack. That is
    // the shape of "the upload did not commit", which nothing in this design can currently
    // see: dbg_wr_match counts writes whose ADDRESS is in the pack window, and the only real
    // read-backs were word 0 (P=0004) and the trailer's 16 bytes (C0). Everything between
    // those two reads has never been checked as a whole.
    //
    // (The other candidate, uninitialized BRAM, was tested and dismissed: tb_soc +FUZZ_BRAM
    // fills the video pages, the palette and the polygon stack with noise before the game
    // gets them, and it still boots and renders 87 rich frames.)
    //
    // Design: the write side accumulates every 16-bit word it commits below the pack's end,
    // and remembers the highest address written; the census then reads exactly that range
    // back through the self-test's sequencer and accumulates again. Comparing the two needs
    // no knowledge of the file, and a 32-bit sum plus a 32-bit xor over a megabyte of words
    // is not going to agree by accident. Quarters (four sums per side) say where it went
    // wrong without a per-word bitmap, which would cost more than the census is worth.
    //
    // Range is word 0 up to cw_max, not the full 2 MiB: the last four 32-bit words are
    // never counted by dbg_wr_match (0x7fffc, not 0x80000) and scanning cells nobody wrote
    // would turn a harmless tail into a permanent mismatch. If the writes skipped anything,
    // cw_n != cw_max and the gap bit says so instead of lying about the sums.
    //
    // Cost, measured in tb_rom rather than derived: a 32,768-word sweep took 365,169 sequencer
    // cycles, i.e. 11.1 cycles per word, so the full 1,048,568-word pack is ~11.7 M cycles
    // = ~126 ms at 92.8125 MHz, once, with the VM still in reset because rom_ready waits on
    // census_done. A census that stops
    // making progress abandons itself (census_stall saturates after 2^18 = ~2.8 ms) and reports the
    // timeout: a hung census must not become a black screen, which is the thing we are
    // trying to detect.
    // Swept range, as 16-bit words. Full pack by default - that is what goes in the
    // bitstream, and a census that samples cannot say "the pack is intact". A testbench may
    // override it: 1,048,576 back-to-back reads is ~126 ms of simulated time for a check whose
    // mechanism is identical over 32 Ki words, and both sides of the comparison are gated by
    // the same parameter so the numbers stay meaningful.
    // 4 MiB, not 2: die 0 in full. The 2 MiB default was the whole image once, and with a paged
    // image the pool runs to byte 0x2F0000, so a census capped at 2 MiB could never certify the bytes
    // the paging feature exists to store - the difference between a check and a gesture. The sweep
    // still STOPS at cw_max (the highest word actually written), so a plain 2 MiB pack pays exactly
    // what it paid before and a 2.94 MiB pool pays roughly 200 ms more boot. Word bit 21 is die
    // select, so 0x200000 words is precisely die 0: the census cannot wander onto the other die,
    // where the self-test probe now lives.
    parameter [21:0] CENSUS_RANGE = 22'h20_0000;
    localparam [21:0] CEN_LAST    = CENSUS_RANGE - 22'd1;
    // Quarter boundary. The slice is `addr[CEN_QSHIFT +: 2]` - `+: ` starts AT the base bit,
    // so this picks bits [CEN_QSHIFT+1 : CEN_QSHIFT]. It was written `CEN_QSHIFT+1 +: 2`,
    // which for the default range picks bits [20:19] of a word address that only has bits
    // [19:0]: the index could then only ever be 0 or 1, quarters 2 and 3 accumulated nothing,
    // and the whole "which part went bad" half of the census was two live halves plus two
    // registers tied to zero. Nothing in simulation noticed - the total sums, which are what Z
    // reports, are unaffected, and a mismatch would still have been flagged, just with the
    // wrong map. `make check-build` caught it the way it always does: the fitter is the only
    // tool here that reads the design as built, and it said `cw_q[2][*] - Stuck at GND`.
    localparam integer CEN_QSHIFT = $clog2(CENSUS_RANGE) - 2;   // quarter boundary

    reg  [21:0] cw_max;          // highest 16-bit word written, plus one
    reg  [21:0] cw_n;            // how many were written (gap check)
    reg  [31:0] cw_sum, cw_xor;
    reg  [31:0] cw_q [0:3];
    // The sweep's cursor and its last word. Width = the address bits the range can name,
    // because both were 22 bits and bit 21 is the die-select bit that the pack never reaches
    // (a 2 MB pack lives in one die): `make check-build` reported census_addr[21] and
    // census_limit[21] as stuck at GND, and it is right - a register that can only ever hold
    // zero is not a free width, it is the fitter telling you the range does not need it.
    // Holding the *last index* rather than a limit is what makes CEN_AW bits enough: a limit
    // of CENSUS_RANGE itself would need one bit more than the addresses it bounds.
    localparam integer CEN_AW = $clog2(CENSUS_RANGE);
    // Word 16384 = the first word of physical page 1, i.e. the first word that is not the directory.
    // Declared after CEN_AW so the comparison is width-matched instead of silently extended, and a
    // localparam rather than a literal because a bare 16384 next to a 21-bit cursor is the kind of
    // width mismatch that Verilator warns about and Quartus quietly fixes.
    localparam [CEN_AW-1:0] CEN_POOL0 = (1 << 14);
    reg  [CEN_AW-1:0] census_addr, census_last;
    reg  [31:0] cr_sum, cr_xor;
    reg  [31:0] cr_pool_sum;          // census sum of pages 1.. only, for the comparison below
    reg  [15:0] hdr_lo, hdr_hi, hxr_lo, hxr_hi;   // the pool sums the IMAGE declares (words 12..15)
    // The comparison is COMBINATIONAL, and that is load-bearing. It was a register assigned at the end
    // of the census, and the census runs exactly once per power-up (census_done clears only in reset),
    // so pool_ok froze at whatever the directory happened to say at that instant - the tb_dir +POOLSUM
    // run caught it with both sums printed equal and pool_ok low, because the census had finished
    // before the directory was ever written. Measured and declared are different clocks of event now:
    // the census fills one, the sweep fills the other, and the verdict is true whenever both are true.
    //
    // What it cannot do is re-measure the CHIP without a new census, and a census after the first byte
    // would steal the chip from a streaming VM - the same reason the directory sweep freezes. A
    // re-upload is verified by the core restart the framework performs around a dataslot change
    // (data.json parameter bits 7/8), not by a second sweep. A sum check also cannot say WHICH side
    // is wrong; it says the two disagree, and that is what the console needs to know.
    wire pool_ok = census_done & dir_installed & (cr_pool_sum == {hdr_hi, hdr_lo});
    reg  [31:0] cr_q [0:3];
    reg         census_active, census_done, census_to;
    reg  [17:0] census_stall;
    // Both sweeps are armed by the same event (the upload finished) and there is one controller,
    // so one of them would lose the start pulse. Losing the census is how a build reported a
    // census of zero while closing timing, so neither is allowed to depend on catching an edge:
    // each has a pending latch, and the directory wins the START, not the census's existence.
    reg         cen_pend, dir_pend;
    // "Read the directory again" crosses here as a four-phase level handshake, NOT as a toggle.
    // It was a toggle, with a comment saying two events landing between samples collapse into one,
    // "which is fine here" - and then tb_dir proved it is not fine at all: the upload-complete arm
    // and a part-write arm really do land in the same window, the toggle collapsed to no change, and
    // the sweep silently installed the OLD part while reporting dir_valid=1 err=00. The collapse is
    // not a bench artefact either: the framework writes persisted interact values immediately before
    // Reset Exit, which is exactly the neighbourhood of an upload-complete edge.
    //
    // A level that is only cleared after an acknowledge cannot lose a request: a second event during
    // an in-flight handshake re-arms afterwards, and coalescing two arms into one sweep is correct
    // anyway, because the sweep is idempotent and always reads the newest held part.
    reg  [1:0]  arm_req_s;
    reg         arm_ack;
    reg         dir_installed;                     // a table is installed for part_latched
    reg  [2:0]  part_latched;
    // aw_fifo is NOT first-word-fallthrough: rd_q belongs to the cycle AFTER rd_en, which is why the
    // loader consumes it through rd_q_valid. Sampling part_fw in the same cycle as the pop read the
    // PREVIOUS word instead - 0 out of reset - so the sweep ran, installed cleanly and reported no
    // error whatsoever, and gave you part 0 however many parts you had written. That is the nastiest
    // shape of bug this port keeps meeting: a feature that works, is silent, and is wrong.
    localparam [1:0] P_IDLE = 2'd0, P_WAIT = 2'd1;
    reg  [1:0] p_state;
    reg  [2:0] part_val;
    reg        part_held;
    reg  [7:0] p_wcnt;
    reg  [6:0]  dir_err_code;
    reg         dir_bad;                 // a directory was expected and was not usable
    reg  [12:0] dir_stat;                // {installed, bad, pool_ok, part[2:0], err[6:0]} for the console
    reg         dir_stat_tog;
    reg         vfy_arm;              // clk_core: the pack is in (driven further down)
    wire        census_done_core;     // census_done synchronised into clk_core (see below).
                                      // Declared here because rom_ready waits on it, and the
                                      // C++ simulator wants a declaration before the use in
                                      // a way iverilog does not.

    // Armed in clk_core when the pack is in; a two-flop synchroniser and an edge detect
    // make it a one-cycle start in clk_psram. One shot: census_done stops it re-arming, so
    // a level that stays high (pack_written does) cannot restart a finished sweep.
    reg  [1:0] vfy_arm_p;
    wire census_go = vfy_arm_p[0] & ~vfy_arm_p[1] & ~census_done;

    // The arm crosses into this clock in the sequencer below (arm_req_s / arm_ack). Writing the
    // declaration and not the synchroniser is a mistake worth recording: an earlier version declared
    // dir_tog_s and never drove it, so it held its reset value forever, the directory sweep NEVER
    // RAN, and every symptom downstream looked like a paging bug - dir_valid=0 err=00 (a sweep that
    // reports nothing has not run; one that found no magic would have said err bit0) and reads
    // landing on the identity page instead of the mapped one.

    // ---- part select: clk_bridge -> async FIFO -> the sweep's clock --------------------------
    // Three bits, which is precisely the case the CDC rules refuse to hand-roll: a multi-bit signal
    // sampled asynchronously can be caught mid-transition, and the answer is a FIFO or a handshake,
    // never a flip-flop chain. aw_fifo already does this crossing for the loader (clk_bridge in,
    // clk_psram out), so the request rides the same proven module at 1/512th the size.
    //
    // The write is address-selected, so bridge_wr_data is never read here. The byte order of an
    // interact write is not something the docs settle (the loader's order is a declaration WE make,
    // by tying bridge_endian_little=0), and a decode that ignores the data cannot be wrong about it.
    reg  [1:0] streamed_s = 2'b00;
    reg        part_push = 1'b0;   // explicit power-up: a 1 here would push a garbage request
    reg  [2:0] part_din    = 3'd0;
    always @(posedge clk_bridge) begin
        streamed_s <= {streamed_s[0], streamed_q};
        part_push  <= 1'b0;
        // Honoured until the VM has taken its first byte, and not after. That boundary is chosen
        // rather than rom_ready: the framework writes persisted interact values "immediately before
        // Reset Exit", which can be AFTER the upload-complete sweep, so a rom_ready gate would drop
        // the part the user actually picked. Nothing has been streamed at that point, because the VM
        // is held off. After the first acceptance a switch could not work anyway - the VM's reset
        // pin is tied to 0 inside the generated netlist (see core_top), so the game would keep
        // running over another part's bytes - and `part_late` says so out loud instead of failing
        // as a wrong-looking picture. The variable is persisted, so it arrives again next boot.
        if (bridge_wr && bridge_addr[31:12] == 20'h00F00 && !streamed_s[1]) begin
            part_push <= 1'b1;
            part_din  <= bridge_addr[4:2];
        end else if (bridge_wr && bridge_addr[31:12] == 20'h00F00) begin
            part_late <= 1'b1;      // refused: bytes were already flowing. Reported, not fixed.
        end
    end

    wire [2:0] part_fw;
    wire       part_empty;
    wire       part_rv;             // rd_q belongs to THIS cycle, one after rd_en
    reg        streamed_q;          // clk_psram: the VM has taken at least one byte
    reg        part_late = 1'b0;    // clk_bridge: a request was refused, for the console
    reg        part_pop;
    /* verilator lint_off PINCONNECTEMPTY */
    aw_fifo #(.DW(3), .AW(2)) u_partfifo (
        .wr_clk(clk_bridge), .wr_rst(rst_bridge), .wr_en(part_push), .wr_data(part_din),
        .wr_full(), .wr_free(),
        .rd_clk(clk_psram), .rd_rst(rst_psram), .rd_en(part_pop), .rd_q_valid(part_rv),
        .rd_q(part_fw), .rd_level(), .rd_empty(part_empty)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    // A capture is the sequencer's own: the controller serialises accesses, so the read
    // data that lands while we sit in ST_WAIT with the census cursor is the census's.
    // census_addr is the right index here (it advances on this same edge), which is also why
    // it is used instead of rd_addr - the request mux has moved on by the time data returns,
    // and rd_addr_q exists for exactly that reason elsewhere in this file.
    wire cen_captured = rd_q_valid & (st_s == ST_WAIT) & census_active;

    always @(posedge clk_psram) begin
        if (rst_psram) vfy_arm_p <= 2'b00;
        else           vfy_arm_p <= {vfy_arm_p[0], vfy_arm};
    end
    wire [1:0] st_cfg = (st_seq == 3'd2) ? 2'd2 :
                        (st_seq == 3'd3) ? 2'd3 : 2'd0;
    // Probe B masks every write else in this design out of the picture: only the LOW
    // lane, so the high byte on readback is proof the earlier write is still there.
    wire [1:0] st_be     = (st_seq == 3'd1) ? 2'b01 : 2'b11;
    wire [15:0] st_wdata = (st_seq == 3'd1) ? ST_PAT_BE : ST_PAT;
    // The directory sweep reads image page 0 (physical word = image word, since the directory IS
    // physical page 0): words 0 and 1 for the magic, then the 64 entries of the selected part.
    wire [21:0] st_rd_addr = census_active ? {{(22-CEN_AW){1'b0}}, census_addr}
                           : dir_active    ? {12'd0, dir_word}
                           : (st_seq == ST_SEQ_P0) ? ST_ADDR_P0 : ST_ADDR_D0;

    // 3 bits: ST_WAIT is 4 - a 2-bit encoding truncated it to 0 (= ST_IDLE), which
    // made the producer's push gate (st_s != ST_WAIT) drop every read while the
    // self-test sat idle, and gave the case statement two identical items.
    localparam [2:0] ST_IDLE = 3'd0, ST_WR = 3'd1, ST_GAP = 3'd2,
                      ST_RD   = 3'd3, ST_WAIT = 3'd4;
    reg  [2:0] st_s;
    wire       dir_start = (st_s == ST_IDLE) & dir_pend;
    reg  [2:0] st_seq;             // which probe of the round is in flight (0..4)
    reg  [15:0] st_cnt, st_wcnt;
    reg  [2:0] st_gap;
    wire       st_active  = (st_s != ST_IDLE);
    wire       st_rd_take = (st_s == ST_RD);

    // ---- directory sweep, sharing the sequencer (and therefore the arbitration and the
    // watchdog) with the self-test and the census.
    //
    // It shares rather than runs beside them for the reason in the plan: every read here goes
    // through one serialised controller, and a second master would need its own answer to "who owns
    // the chip". 66 reads at ~12 cycles is under a microsecond, so it costs the boot nothing, and
    // it inherits the census's watchdog instead of inventing a way to hang rom_ready forever.
    //
    // Order inside a round is magic, then entries - and it must be magic first, because a plain
    // 2 MB pack has real data at image words 0 and 1 (part1.bin starts 0004) and installing its
    // bytes as a page table would be the worst possible failure mode: every page pointed at frame
    // 4-ish, a plausible picture, and a checksum that still matches because the data is genuinely
    // there. Reading the magic first turns "is this a pool" into two reads instead of a search.
    localparam [15:0] DIR_MAGIC0 = 16'h5741;             // "AW"
    localparam [15:0] DIR_MAGIC1 = 16'h3150;             // "P1"
    localparam [2:0]  ST_SEQ_DIR = 3'd6;
    wire dir_captured = rd_q_valid & (st_s == ST_WAIT) & dir_active;
    // An entry names a physical page in 1..127. 0 is the directory and >=128 is die 1, so an
    // out-of-range entry is not "slightly wrong", it is the corrupted-table case the whole page-0
    // layout exists to make harmless: refuse the whole install and go back to identity.
    wire dir_val_ok   = (rd_q[7:0] >= 8'd1) && (rd_q[7:0] <= 8'd127);
    assign dir_install = dir_captured && (dir_ph >= 7'd6) && dir_val_ok;
    assign rom_dir_busy = dir_active | clr_active;

    always @(posedge clk_psram) begin
        if (rst_psram) begin
            st_s               <= ST_IDLE;
            st_wcnt            <= 16'd0;
            st_cnt             <= 16'd0;
            st_gap             <= 3'd0;
            st_seq             <= 3'd0;
            rom_selftest_die0  <= 16'h0000;
            rom_selftest_be    <= 16'h0000;
            rom_selftest_ceneg <= 16'h0000;
            rom_selftest_cre   <= 16'h0000;
            rom_selftest_pack0 <= 16'h0000;
            // Every census register resets, and not as decoration. Without it Quartus chose
            // the power-up value of census_done itself: it reported "census_done - Stuck at
            // VCC", and from that single freedom the whole feature evaporated - census_go
            // low forever, census_active Stuck at GND, cr_sum's clock_enable tied off, the
            // report permanently reading zero, and a bitstream that still closed timing while
            // never sweeping a word. Verilator zero-inits registers, so every simulation passed.
            // This is the uninitialized-memory trap again, one level up: sim reset is not RTL reset.
            census_active      <= 1'b0;
            census_done        <= 1'b0;
            census_to          <= 1'b0;
            cen_pend           <= 1'b0;
            // dir_done resets HIGH, and that is load-bearing rather than sloppy: an unloaded chip
            // has an identity table, which is a map the VM may legitimately read. "No sweep has run
            // yet, so the map is not ready" is how a census gate once turned tb_write into
            // rom_ready=0 with 231 errors - waiting for a sweep nobody asked for is
            // indistinguishable from waiting forever. This way there is no third gate condition, no
            // arming budget, and no deadlock to reason about at 2 a.m.
            dir_active         <= 1'b0;
            dir_done           <= 1'b1;
            dir_to             <= 1'b0;
            dir_pend           <= 1'b0;
            dir_ph             <= 7'd0;
            dir_part           <= 3'd0;
            dir_stall          <= 18'd0;
            dir_err_code       <= 7'd0;
            hdr_lo             <= 16'd0;
            hdr_hi             <= 16'd0;
            hxr_lo             <= 16'd0;
            hxr_hi             <= 16'd0;
            cr_pool_sum        <= 32'd0;
            part_latched       <= 3'd0;
            arm_ack            <= 1'b0;   // driven here; arm_req_s belongs to its own process
            dir_installed      <= 1'b0;
            clr_req            <= 1'b0;
            census_addr        <= {CEN_AW{1'b0}};
            census_last        <= {CEN_AW{1'b0}};
            census_stall       <= 18'd0;
            cr_sum             <= 32'd0;
            cr_xor             <= 32'd0;
            cr_q[0]            <= 32'd0;
            cr_q[1]            <= 32'd0;
            cr_q[2]            <= 32'd0;
            cr_q[3]            <= 32'd0;
        end else begin
            // Take the request when the controller can honour it, and hold the acknowledge until the
            // sweep that was asked for has actually finished - dir_pend is set on taking it, so the
            // acknowledge condition below cannot be satisfied by the request that has not run yet.
            if (arm_req_s[1] && !dir_pend && !dir_active) dir_pend <= 1'b1;
            if (arm_req_s[1] && !dir_pend && !dir_active && dir_done) arm_ack <= 1'b1;
            else if (!arm_req_s[1]) arm_ack <= 1'b0;
            if (dir_start) dir_pend <= 1'b0;
            if (clr_req && clr_active) clr_req <= 1'b0;   // the RAM process has it from here
            // The census arms the same way. It used to start on the raw census_go edge, and once a
            // second sweep shared this controller that edge could arrive in a cycle the controller
            // was not idle in - and then the census simply never ran, which is the failure this
            // latch exists to prevent: tb_rom came back "census never finished", read sum 00000000
            // against 1f4b8fbe written, with a bitstream that still closed timing.
            if (census_go) cen_pend <= 1'b1;

            case (st_s)
            ST_IDLE: if (dir_pend) begin
                // Directory first, always, and ahead of the census: the boot check reads the
                // trailer through the page table, so a check that runs before the table is
                // installed reads frame body bytes, fails off0 == 0, paints ERR_TRAILER and holds
                // rom_ready low forever. The sweep is 66 reads; the census is a million.
                dir_active    <= 1'b1;
                dir_done      <= 1'b0;
                dir_to        <= 1'b0;
                dir_ph        <= 7'd0;
                dir_stall     <= 18'd0;
                // The part comes from the FIFO if one is waiting, otherwise this is a re-read of
                // the same part (a retry, or an upload that finished while the sweep was already
                // armed) - never a silent fall back to part 0, which would replay part 1's intro
                // under a menu that says part 4.
                // part_held is READ here and cleared by its own process (a single driver per
                // register, per the chk_cnt note below - the sequencer writing it as well is the
                // multiple-constant-driver error Quartus elaborates on and Verilator never shows).
                dir_part      <= part_held ? part_val : part_latched;
                st_seq        <= ST_SEQ_DIR;
                st_s          <= ST_RD;
            end else if (cen_pend) begin
                // Read-only pass: no write phase, and the periodic probes wait for it.
                // The end of the sweep is snapshotted so a late write cannot move the
                // goalposts: sweep words 0..cw_max-1, or 0..CEN_LAST if the range is smaller.
                census_active   <= 1'b1;
                census_addr     <= {CEN_AW{1'b0}};
                census_last     <= (cw_max == 22'd0) ? {CEN_AW{1'b0}}
                                   : (cw_max > CENSUS_RANGE) ? CEN_LAST[CEN_AW-1:0]
                                   : cw_max[CEN_AW-1:0] - {{(CEN_AW-1){1'b0}}, 1'b1};
                cen_pend        <= 1'b0;
                census_stall    <= 18'd0;
                cr_sum          <= 32'd0;
                cr_xor          <= 32'd0;
                cr_q[0]         <= 32'd0;
                cr_q[1]         <= 32'd0;
                cr_q[2]         <= 32'd0;
                cr_q[3]         <= 32'd0;
                st_seq          <= ST_SEQ_CEN;
                st_s            <= ST_RD;
            end else if (st_cnt == ST_PERIOD - 16'd1) begin
                st_cnt <= 16'd0;
                st_seq <= 3'd0;                // first probe of the round
                st_s   <= ST_WR;               // seqs 0..3 have a write phase
            end else begin
                st_cnt <= st_cnt + 16'd1;
            end
            ST_WR: if (st_taken) begin
                st_gap <= 3'd4;                // let the write access finish first
                st_s   <= ST_GAP;
            end
            ST_GAP: begin
                st_s   <= (st_gap == 3'd0) ? ST_RD : ST_GAP;
                st_gap <= (st_gap == 3'd0) ? 3'd0 : st_gap - 3'd1;
            end
            ST_RD: if (rd_taken) begin
                st_s    <= ST_WAIT;
                st_wcnt <= 16'd0;      // the timeout starts when the read is on its way
            end
            // Hold until the readback lands below. Without this explicit item
            // ST_WAIT fell into `default` and cleared itself in one cycle - six
            // cycles too early for rd_q_valid, so the capture could never fire
            // (build 1030a printed T0000 on hardware: the reset value, not a read).
            // ST_WAIT used to wait forever. The sequencer is shared: the producer is gated
            // with ~st_active, so a probe whose readback never arrives does not just lose a
            // probe - it starves the ROM path for the rest of the power cycle, because st_s
            // never leaves a state that reports st_active. A probe that is not answered in
            // ~0.7 ms is a failed probe, and the round is abandoned.
            ST_WAIT: if (&st_wcnt) begin
                st_s   <= ST_IDLE;
                st_seq <= 3'd0;
            end else begin
                st_wcnt <= st_wcnt + 16'd1;
            end
            default: st_s <= ST_IDLE;
            endcase

            // The controller serialises accesses, so the next rd_q_valid after our
            // read is taken is ours - and only ours goes here, never to the stream
            // FIFO (see the producer's push gate). Route it to the probe that owns
            // it, then advance: cfg0 -> cfg1 -> cfg2 -> cfg3 -> pack read -> done.
            if (cen_captured) begin
                // Pages 1 upward only: page 0 is the directory, and its own bytes would otherwise sit
                // inside the sum the directory declares for the pool. The point of comparing against
                // a declared number is that the two are computed from different things.
                if (census_addr >= CEN_POOL0) cr_pool_sum <= cr_pool_sum + rd_q;
                cr_sum       <= cr_sum + rd_q;
                cr_xor       <= cr_xor ^ rd_q;
                cr_q[census_addr[CEN_QSHIFT +: 2]] <=
                    cr_q[census_addr[CEN_QSHIFT +: 2]] + rd_q;
                census_stall <= 24'd0;
                if (census_addr >= census_last) begin
                    census_active <= 1'b0;
                    census_done   <= 1'b1;
                    st_s          <= ST_IDLE;
                end else begin
                    census_addr <= census_addr + 1'b1;
                    st_s        <= ST_RD;
                end
            end

            // Watchdog. Without it a census that stops being served holds the sequencer,
            // rom_ready never rises, and the design we are debugging becomes a black screen
            // for a different reason. 2^18 cycles is ~2.8 ms at 92.8125 MHz against a read
            // that completes in twelve (~130 ns): still eighty thousand times the margin,
            // and short enough that a bench whose PSRAM model never answers - which is what
            // first showed this to me, tb_write coming back rom_ready=0 with 231 errors -
            // gets its boot back in a few thousand cycles instead of never.
            // The sweep's own capture. Note it re-arms st_s <= ST_RD exactly as the census does:
            // the case statement above has already been evaluated against the CURRENT st_s
            // (ST_WAIT), so this neither double-issues nor skips the gap the controller wants.
            if (dir_captured) begin
                dir_stall <= 18'd0;
                if (dir_ph < 7'd2) begin
                    if (rd_q !== ((dir_ph == 7'd0) ? DIR_MAGIC0 : DIR_MAGIC1)) begin
                        // Not a pool. A plain 2 MB pack is the normal case here, so this is not an
                        // error - but the table must be walked back to identity rather than left as
                        // the previous install, because a stale pool table aimed at a fresh plain
                        // pack reads another part's bytes and looks exactly like a bad upload.
                        dir_active    <= 1'b0;
                        dir_done      <= 1'b1;
                        clr_req       <= 1'b1;
                        dir_err_code  <= 7'd1;             // bit0: no magic
                        dir_installed <= 1'b0;
                        dir_bad       <= 1'b0;             // a plain pack is not an error
                        st_s          <= ST_IDLE;
                    end else begin
                        dir_ph <= dir_ph + 7'd1;
                        st_s   <= ST_RD;
                    end
                end else if (dir_ph < 7'd6) begin
                    // header words 12..15: sum.lo, sum.hi, xor.lo, xor.hi
                    case (dir_ph)
                    7'd2:    hdr_lo <= rd_q;
                    7'd3:    hdr_hi <= rd_q;
                    7'd4:    hxr_lo <= rd_q;
                    default: hxr_hi <= rd_q;
                    endcase
                    dir_ph <= dir_ph + 7'd1;
                    st_s   <= ST_RD;
                end else if (!dir_val_ok) begin
                    dir_active    <= 1'b0;
                    dir_done      <= 1'b1;
                    clr_req       <= 1'b1;
                    // bit1 = an entry was out of range; bits[5:0] = which one, so the console names
                    // it instead of reporting "bad"
                    dir_err_code  <= 7'h02 | {1'b1, dir_ph[5:0]};
                    dir_bad       <= 1'b1;
                    dir_installed <= 1'b0;
                    st_s          <= ST_IDLE;
                end else if (dir_ph == 7'd69) begin
                    dir_active    <= 1'b0;
                    dir_done      <= 1'b1;
                    dir_err_code  <= 7'd0;
                    dir_bad       <= 1'b0;
                    dir_installed <= 1'b1;
                    part_latched  <= dir_part;             // what the table now describes
                    st_s          <= ST_IDLE;
                end else begin
                    dir_ph <= dir_ph + 7'd1;
                    st_s   <= ST_RD;
                end
            end

            if (dir_active && !dir_captured) begin
                if (&dir_stall) begin
                    dir_active    <= 1'b0;
                    dir_done      <= 1'b1;
                    dir_to        <= 1'b1;
                    dir_err_code  <= 7'h41;               // bit6: not served in time
                    dir_bad       <= 1'b1;
                    dir_installed <= 1'b0;
                    st_s          <= ST_IDLE;
                end else dir_stall <= dir_stall + 18'd1;
            end

            // One cycle after the status registers settle, so the toggle a other clock domain
            // waits on always arrives with the data behind it stable - the source-domain-data-plus-
            // toggle pattern, which is the only safe way to move a multi-bit status word without a
            // second FIFO. err[6] is kept inside the 12 bits rather than dropped: "sweep not served"
            // and "entry 12 out of range" are different faults with the same symptom otherwise.
            // Status for the console, moved across clocks the only defensible way: the 12-bit word
            // is written first, and the toggle flips on the NEXT change of that word, so a consumer
            // that samples on a toggle edge is always reading a settled value. "err[6]" is kept
            // rather than dropped - "sweep not served" and "entry 12 out of range" would otherwise
            // share one code, and they want different fixes.
            if ({dir_installed, dir_bad, pool_ok, part_latched, dir_err_code} !== dir_stat) begin
                dir_stat     <= {dir_installed, dir_bad, pool_ok, part_latched, dir_err_code};
                dir_stat_tog <= ~dir_stat_tog;
            end

            if (census_active && !cen_captured) begin
                if (&census_stall) begin
                    census_active <= 1'b0;
                    census_done   <= 1'b1;
                    census_to     <= 1'b1;
                    st_s          <= ST_IDLE;
                end else census_stall <= census_stall + 18'd1;
            end

            if (rd_q_valid && st_s == ST_WAIT && !census_active && !dir_active) begin
                case (st_seq)
                3'd0: rom_selftest_die0  <= rd_q;
                3'd1: rom_selftest_be    <= rd_q;
                3'd2: rom_selftest_ceneg <= rd_q;
                3'd3: rom_selftest_cre   <= rd_q;
                default: rom_selftest_pack0 <= rd_q;     // ST_SEQ_P0
                endcase
                if (st_seq == ST_SEQ_P0) begin
                    st_s <= ST_IDLE;                     // round complete
                end else begin
                    st_seq <= st_seq + 3'd1;
                    // the NEXT sequence's first phase: seq 4 is read-only, the rest write
                    st_s   <= (st_seq == 3'd3) ? ST_RD : ST_WR;
                end
            end
        end
    end

    // write side of the chip, driven straight from the state above; the self-test
    // owns it for one access while in ST_WR
    wire        wr_ready;
    // `wr_taken` is any master's access being accepted, and on its own that is a bug: the
    // self-test forces wr_req high for its own probe write while the loader's drain sits in
    // D_RUN, the drain sees wr_taken, and consumes a word whose address and data never went
    // anywhere. Measured in tb_rom at PACE=10: three 16-bit words lost every ST_PERIOD
    // (5,520 words = 11,040 bytes apart, matching the 444 us probe period exactly), which is
    // six bytes of the pack quietly thrown away per probe round in a bench that had been
    // passing 510 checks for weeks. Each master takes its own acceptance signal now.
    wire        wr_taken  = wr_req & wr_ready;
    // ~ld_abort belongs here: it is part of what the drain actually asks for (see the
    // wr_req mux below), and dropping it is a second bug of the same shape - tb_write, the
    // bench that exercises the abort path, went rom_ready=0 with "busy never fell" the first
    // time this was written as d_act & wr_ready.
    wire        d_taken   = d_act & ~ld_abort & wr_ready;   // the drain's word, and only
                                                            // when it owns the bus
    wire        st_taken  = (st_s == ST_WR) & wr_ready;   // the probe's own access
    reg         wr_req;
    reg  [21:0] wr_addr;
    reg  [15:0] wr_wdata;
    always @(*) begin
        if (st_s == ST_WR) begin
            wr_req   = 1'b1;
            wr_addr  = ST_ADDR_D0;     // every write probe hits the same scratch word
            wr_wdata = st_wdata;       // probe B writes 5A5A on the low lane only
        end else begin
            wr_req   = d_act & ~ld_abort;
            wr_addr  = d_addr;
            wr_wdata = d_wdata;
        end
    end
    assign ld_rd = ld_rd_q;

    // Write side of the census: every 16-bit word committed below the pack's end, counted
    // as it is taken by the controller (not as it is queued, so a write that never gets
    // taken cannot make the sums agree). The self-test's own scratch write lives at
    // ST_ADDR_D0, above CEN_LAST, so it is excluded by range rather than by a case.
    always @(posedge clk_psram) begin
        if (rst_psram) begin
            cw_sum <= 32'd0; cw_xor <= 32'd0;
            cw_q[0] <= 32'd0; cw_q[1] <= 32'd0; cw_q[2] <= 32'd0; cw_q[3] <= 32'd0;
            cw_max <= 22'd0; cw_n <= 22'd0;
        end else if (d_taken && wr_addr <= CEN_LAST) begin
            cw_sum <= cw_sum + wr_wdata;
            cw_xor <= cw_xor ^ wr_wdata;
            cw_q[wr_addr[CEN_QSHIFT +: 2]] <= cw_q[wr_addr[CEN_QSHIFT +: 2]] + wr_wdata;
            cw_n   <= cw_n + 22'd1;
            if (wr_addr + 22'd1 > cw_max) cw_max <= wr_addr + 22'd1;
        end
    end

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
            D_RUN: if (d_taken) begin
                if (d_last) begin
                    // The last access of this entry is now in flight. If the next
                    // entry is already queued, start pulling it out on this very
                    // cycle: the registered FIFO output appears next cycle, which is
                    // still eight cycles before the chip will take the next write.
                    if (!ld_empty && !ld_abort) begin
                        ld_rd_q <= 1'b1;
                        d_state <= D_ARM;
                    end else begin
                        d_state <= D_IDLE;
                    end
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
    // byte.
    //
    // The buffer is not a margin here, it is the whole mechanism, and that is arithmetic
    // rather than a choice: one chip access is twelve sequence cycles plus the idle cycle
    // every read parks in (140 ns), while a gapless fill consumes a word every two core
    // cycles (80.8 ns). A single ZBT access on one bus cannot go faster than that, whatever
    // clock it runs on - this design's read side is one access per 140 ns, the reference's
    // is one per 225 ns - so the only way a 63-byte fill stays gapless is that the bytes
    // come out of a buffer someone filled earlier. Which is why PREFILL_WORDS is a hard
    // gate on the first byte and not a hint.
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

    // A held acceptance must not gap once it has started, and this number is what decides
    // whether it can afford not to. 32 words = 64 bytes covers the 63 a preload asks for, but
    // with ZERO margin: an acceptance that starts on an odd byte address spends half of its
    // first word, and the reader's delivery rhythm (pop a word, hand out two bytes, one word
    // every two core cycles) has no slack either, so the last byte of a fill depends on a
    // handoff that had nothing left in reserve. Measured on hardware that is exactly where the
    // stream loses a cycle - and a lost cycle inside a fill is not a stall, it moves every later
    // write (see c_start).
    //
    // 40 words = 80 bytes: the 63 asked for, plus 17 bytes that cannot be spent no matter how
    // the acceptance lands. LOOKAHEAD is already 40, so the producer was ALWAYS willing to run
    // this far ahead; the gate simply never asked. The cost is prefill latency on held
    // acceptances - part1 runs about 4.8 of them per frame, and 8 extra words is ~1.1 us, which
    // is nothing against 16.7 ms - and it is what keeps `resume_addr` from ever being needed.
    localparam [SDB:0] PREFILL_WORDS = 1 << 5;   // 32 -> see below
    localparam [SDB:0] PREFILL_MARGIN = 8;       // 40 words buffered before the first byte
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

    reg  [19:0] start_addr_r;   // word address of the current stream; written at the
                                // acceptance and unchanged while c_run is low
    reg  [2:0]  run_s;
    always @(posedge clk_psram) run_s <= {run_s[1:0], c_run};
    wire p_start = run_s[1] & ~run_s[2];

    // Registered, and that is the whole point of the flop. Unregistered, this comparison sat
    // in front of the PSRAM controller's chip-facing output registers: aw_psram's `take` is
    // what loads psram_ub_n/psram_lb_n in S_IDLE, and rd_req is one of the two terms of take.
    // Build 1039a measured the consequence - 4 paths, worst -0.385 ns setup, from
    // u_sfifo|rptr_sync2[5] through the grey-to-binary conversion, the occupancy subtract and
    // the compare into u_psram|psram_lb_n, six logic levels with 56 % of the delay in
    // interconnect, because the fifo lives three columns from the cram0 I/O cells and the
    // fitter has no reason to pull them together. Putting a flop here ends that comparison in
    // a register beside the fifo and leaves one level between the flag and the chip bus. It
    // also contains the asynchronous `sf_level` sample in a single flop instead of letting it
    // propagate through arithmetic into a chip control register.
    //
    // What one cycle of staleness costs: at most one extra accepted read beyond what the live
    // comparison would have allowed. FETCH_HEADROOM is 7 words and the controller can have two
    // reads in flight at the very most (a 7-cycle access, data back twelve cycles later), so
    // the conservative direction still has four words of margin. The flag only ever decides
    // *when* fetching starts and stops - never what lands where - and the request stays a
    // level held until the controller takes it, which is the contract aw_psram depends on.
    reg p_allow_q;
    always @(posedge clk_psram) begin
        if (rst_psram) p_allow_q <= 1'b0;
        else           p_allow_q <= run_s[2] & (sf_free >= FETCH_HEADROOM)
                                   & (sf_level <= LOOKAHEAD);
    end
    wire p_allow = p_allow_q;

    // ============================== view page table =============================
    // The VM's view is the pack and stays the pack: byte address [20:0], word address [19:0]. The
    // trailer at 0x1fffe0, the benches' address masks and resume_from_start = ~c_start[20] &
    // (acc_cnt < 64) all keep working untouched, because the VM never learns there was a pool.
    // What is mapped is the PSRAM side: view word N lives at psram word {page[N>>14], N[13:0]}.
    //
    // A bare CONCATENATION, deliberately. Worst slack is +0.135 ns, and the paths into the cram0
    // output registers are exactly where build 1039a lost 4 paths at -0.385 ns through arithmetic
    // the fitter had no reason to place near the I/O cells. An adder here - a header offset, a
    // frame base that is not page aligned - would repeat that mistake to save 32 KiB of image.
    // So scripts/build_combined_image.py puts the directory on page 0, numbers frames from page 1,
    // and refuses any page >= 128: page bit 7 IS die select, and die 1 is the self-test's space.
    //
    // With no table installed the map is the IDENTITY, so a plain 2 MiB pack reads exactly as it
    // did before this code existed. That is what makes the change falsifiable against the benches
    // that already pass instead of needing new ones to be believed.
    // 20 bits, not 22. The view is 1 Mi words (2 MiB) and since the page map went in, the fetch
    // address is {page_phys, p_addr[13:0]} - so p_addr[21] had no fanout at all and check-build said
    // so. Leaving a register bit that can only ever hold zero is not free (see the census_addr note
    // above: the fitter is telling you the range does not need the width), and this one is a width my
    // own change made dead, so it is mine to remove rather than to explain.
    reg  [19:0] p_addr;                                  // view word address of the next fetch
    localparam integer PGTBL_AW = 6;                     // 64 view pages of 32 KiB
    reg  [7:0] pgtbl [0:(1<<PGTBL_AW)-1];                // view page -> physical 32 KiB page
    // Power-up identity, and that is a safety property rather than tidiness: without it the RAM
    // starts as X in simulation and random config bits in hardware, and writing ONE entry (which
    // is all `tbl_loaded` used to signal) silently re-pointed the other 63 pages at page 0. tb_rom
    // found this - 188 bank-alias mismatches after a single set_page() - and the design is wrong
    // for it, not the test. Quartus honours this as M10K power-up content, so a partial load
    // changes exactly the pages it changes and the identity map is what an unloaded core does
    // rather than a special case bolted onto it.
    integer pgtbl_i;
    initial for (pgtbl_i = 0; pgtbl_i < (1 << PGTBL_AW); pgtbl_i = pgtbl_i + 1)
        pgtbl[pgtbl_i] = pgtbl_i[7:0];
    // Install writers, one mux, priority order stated because two of them can be simultaneously
    // true and the choice is a behaviour: the bench port first (it is the only thing that can test
    // a table the boot logic would reject), then the identity walk-back, then the sweep's entries.
    reg                  clr_active;                     // walk the whole table back to identity
    reg  [5:0]           clr_i;
    reg                  clr_req;                        // the sequencer's ask; owned by IT, and the
                                                         // only thing it may drive here (see below)
    wire                 dir_install;
    reg                  dir_active, dir_done, dir_to;
    reg  [6:0]           dir_ph;                         // 0,1 = magic words; 2..65 = table entries
    reg  [2:0]           dir_part;                       // part sampled at sweep start
    reg  [17:0]          dir_stall;
    reg  [9:0]           dir_base;                       // first table word of dir_part, in words
    always @(*) begin
        case (dir_part)
            3'd0:      dir_base = 10'd16;
            3'd1:      dir_base = 10'd88;
            3'd2:      dir_base = 10'd160;
            3'd3:      dir_base = 10'd232;
            3'd4:      dir_base = 10'd304;
            3'd5:      dir_base = 10'd376;
            3'd6:      dir_base = 10'd448;
            default:   dir_base = 10'd520;
        endcase
    end
    // Six header reads then the table. Words 0,1 are the magic; words 12..15 are the pool's declared
    // word-sum and xor (HDR "<4sHHHHIIIII": byte 24 -> word 12, little-endian pairs). Read in the same
    // sweep because the sweep is already sitting on page 0, four reads is nothing, and a pool sum the
    // core has never looked at is a number in a file rather than a check.
    wire [9:0] dir_word = (dir_ph <= 7'd1) ? {3'b0, dir_ph[6:0]}
                              : (dir_ph <= 7'd5) ? (10'd10 + {3'b0, dir_ph[6:0]})
                              : (dir_base + {3'b0, dir_ph[6:0]} - 10'd6);

    reg  [7:0]           tbl_rdat;                       // synchronous (M10K) read result
    reg  [PGTBL_AW-1:0]  tbl_rdat_idx;                   // ... and which page it belongs to
    reg                  tbl_loaded;                     // 0 = identity, a single plain pack

    // Writing while the producer reads is not expected (a load happens with the VM in reset and
    // the stream idle); the M10K would read the OLD value, and page_ready below holds the producer
    // off the bus for a cycle anyway.
    wire [PGTBL_AW-1:0] p_view_page = p_addr[19:14];     // page of the word about to be fetched

    always @(posedge clk_psram) begin
        if (rst_psram) begin
            // The table itself is NOT cleared here: its power-up identity is what an unloaded core
            // maps with, and rst_psram cannot re-write 64 RAM cells anyway. tbl_loaded is only a
            // report of whether anything has been installed - the mapping never depends on it, so
            // it cannot disagree with the RAM.
            tbl_loaded   <= 1'b0;
            tbl_rdat     <= 8'd0;
            tbl_rdat_idx <= {PGTBL_AW{1'b0}};
            clr_active   <= 1'b0;
            clr_i        <= 6'd0;
        end else begin
            tbl_rdat     <= pgtbl[p_view_page];
            tbl_rdat_idx <= p_view_page;
            if (tbl_wr) begin
                pgtbl[tbl_widx] <= tbl_wval;
                tbl_loaded      <= 1'b1;
            end else if (clr_active) begin
                pgtbl[clr_i] <= {2'b0, clr_i};
                if (clr_i == 6'd63) clr_active <= 1'b0;
                else                clr_i <= clr_i + 6'd1;
            end else if (clr_req) begin
                clr_active <= 1'b1;
                clr_i      <= 6'd0;
            end else if (dir_install) begin
                pgtbl[dir_ph[5:0] - 6'd6] <= rd_q[7:0];
                tbl_loaded <= 1'b1;
            end
        end
    end
    assign rom_tbl_loaded = tbl_loaded;

    // The read result is only usable for the page it was fetched for: the RAM output is
    // registered, so on the cycle a page crossing happens it still belongs to the previous page.
    // Holding the fetch off for that cycle costs exactly ONE cycle per 16,384 words (and one at
    // the start of each acceptance) against FETCH_HEADROOM 7 and LOOKAHEAD 40. It is applied
    // always, identity or not, so there is one path rather than a special case that paging
    // silently bypasses - which is the kind of difference that never shows up until it does.
    // The one cycle where this could bite is the first cycle after rst_psram: tbl_rdat_idx and
    // tbl_rdat both hold their reset values, so page_ready can be true with un-read data. That is
    // only true when p_view_page is 0, whose identity value is also 0, so the fetch is correct
    // anyway - and a table load happens with the stream idle and takes at least 64 cycles, so the
    // pipeline is long settled before the VM asks for anything. Stated because "it works out" is
    // not something a reader should have to re-derive at 2 a.m.
    wire       page_ready = (tbl_rdat_idx == p_view_page);
    wire [7:0] page_phys  = tbl_rdat;

    // The self-test read preempts while presented (one access every ~444 us); the
    // producer is paused for that window and must not book its traffic as its own.
    // It also addresses PHYSICAL psram and so bypasses the page map entirely.
    assign rd_req   = st_rd_take | (p_allow & ~st_active & page_ready);
    assign rd_addr  = st_rd_take ? st_rd_addr : {page_phys, p_addr[13:0]};
    // The tag is the VIEW word address, never the physical one: the consumer matches it against
    // c_addr[20:1], and a paged read that tagged where the byte physically lived would look like
    // a stream that skipped. Separating tag from address is why paging costs the consumer nothing.
    // The tag keeps its 21-bit width - the consumer's match is the most load-bearing comparison in
    // this file and is not being changed to tidy a register. Bit 20 is simply a constant now, fed by
    // the concatenation instead of by a register that could never set it.
    wire [TW-1:0] rd_tag_w = st_rd_take ? st_rd_addr[TW-1:0] : {1'b0, p_addr};

    wire        rd_taken   = rd_req & rd_ready;
    wire        prod_taken = rd_taken & ~st_rd_take;

    always @(posedge clk_psram) begin
        if (rst_psram) begin
            p_addr   <= 20'd0;
            sf_wr    <= 1'b0;
            sf_wdata <= {SWIDTH{1'b0}};
        end else begin
            sf_wr <= 1'b0;
            if (p_start) begin
                p_addr <= start_addr_r;
            end else if (prod_taken) begin
                p_addr <= p_addr + 20'd1;
            end
            if (rd_q_valid && st_s != ST_WAIT) begin
                sf_wr    <= 1'b1;
                sf_wdata <= {rd_addr_q, rd_q};   // the address the controller read
                                                 // (ST_WAIT is the self-test's own
                                                 // readback - captured in its block)
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
    // The address the CURRENT acceptance began at. Deleted in 1041a when its last reader went
    // away, and back by demand of hardware: the two consumers of this bus want OPPOSITE resume
    // points, so the reader has to know both (see `resume_addr` below).
    //
    //   bytecode fill (vm.si:491) holds in_ready for 63 bytes and writes them with
    //       data.addr = data.wenable ? (data.addr + 1) : 0
    //   so a cycle without data_available sends ITS write pointer back to 0. Continuing such a
    //   stream at the next byte owed hands the byte for base+0x2c to fill[0]: every later byte
    //   lands shifted, the interpreter executes ROM data as opcodes, and the Pocket stops with
    //   opcode 0x80 and no more page swaps ~10 s into the intro. Confirmed in sim - build 1041's
    //   policy under a forced gap shifts 121 of 282 fill writes and the design never swaps a
    //   page again, while the c_start policy shifts nothing.
    //
    //   op_drawString (vm.si:935) holds pix_waddr across gaps, so it survives a gap perfectly
    //   well and is destroyed by being RE-SERVED: that is the 4-px-per-row text shear build 1040
    //   showed. It wants the next byte owed.
    reg  [20:0] c_start;                // first byte of this acceptance - the fill's continuation
    reg  [6:0]  acc_cnt;                // bytes delivered since `accept`, saturating at 64:
                                        // how deep into the acceptance a restart would land
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
    // See the address map above: [23:21] are the device bank, [20:0] is the pack offset.
    wire [20:0] mem_pack_addr = mem_addr[20:0];
    wire [20:0] acc_addr = chk_kick ? TRAILER_ADDR[20:0] : mem_pack_addr;

    wire host_rdy = chk_active ? (chk_cnt != 5'd0) : inr[0];

    wire          landing   = pend;
    wire [TW-1:0] land_addr = sf_q[SWIDTH-1 -: TW];
    wire [15:0]   land_word = sf_q[15:0];

    wire [TW-1:0] want_word = {1'b0, c_addr[20:1]};        // word the next byte lives in
    wire [TW-1:0] next_word = c_waddr + {{(TW-1){1'b0}}, 1'b1};

    // A held request needs the whole fill buffered before its FIRST byte; a pulsed one
    // (readByte, in_ready long dropped by the time any memory can answer) never does.
    // The gate is on host_rdy - whoever is asking, and whether they are asking in a way
    // that forbids a gap - not on inr[0], because the boot check's readiness is chk_cnt,
    // not the VM's. Keying it on inr[0] alone meant the check saw "host not ready",
    // skipped the prefill, and served byte 0 from a drained FIFO; with a twelve-cycle
    // read word 1 could not be there two core cycles later, so it rewound, re-served
    // into the same chk_data shift register, and the trailer never validated however
    // perfectly the chip answered (that is what held this design in reset once the read
    // stopped being faster than the consumer). Prefilling costs the check about 4 us
    // and every holder of a held stream needs it anyway.
    // Held acceptances wait for PREFILL_WORDS + PREFILL_MARGIN; a pulsed one (readByte) never
    // waits at all, because by the time any memory can answer its in_ready is long gone and
    // host_rdy is already low.
    wire prefill_ok = ~host_rdy | (sf_level >= (PREFILL_WORDS + PREFILL_MARGIN));
    wire want       = c_run & (host_rdy | ~c_served);

    // ~stall_block here (and only here) is the simulation knob making the wanted word ABSENT,
    // which is what the chip does when the successor misses its landing cycle. Gating `take`
    // instead was wrong and made the knob lie: it blocked a take whose word was present, so the
    // reader tore down a stream it could have continued and the experiment measured the knob.
    wire word_ok = c_v & (c_waddr == want_word) & ~stall_block;
    wire take_raw = (c_state == C_RUN) & want & word_ok & (c_served | prefill_ok);

`ifdef AW_STALL
    // "A byte would go out THIS cycle if nothing were in the way" - deliberately independent of
    // stall_block, so the counter below keeps its own time and the stimulus is identical in every
    // variant of this file that scripts/ab_resume_policy.sh patches. Declared INSIDE the ifdef:
    // a wire nothing reads in the synthesised netlist is exactly the dead logic
    // `make check-build CORE_DIR=cores/aw` is there to catch, and a simulation knob should not be
    // able to produce that report.
    wire stall_tick = (c_state == C_RUN) & want & c_v & (c_waddr == want_word)
                    & (c_served | prefill_ok) & ~chk_active;
    // Simulation-only: force the condition the modelled PSRAM never produces.
    //
    // Why this exists: on the Pocket, part1's streams DO drain and the reader DOES restart, and
    // that is the only place a restart-address change can bite. Measured on hardware: the c_start
    // policy plays the intro with sheared text, the c_addr policy plays it straight and freezes
    // at ~10 s, same place every launch. In sim the modelled chip answers fast enough that part1
    // shows 0 restarts, so every policy delivers a byte-identical stream and the bench cannot
    // tell them apart - the mistake recorded in memory: prove the changed path executes in the
    // run being compared, or the A/B is measuring nothing.
    //
    // So stop waiting for the failure and schedule it: make the wanted word absent for ONE cycle
    // every STALL_EVERY delivered bytes, which is exactly what twelve cycles of tAA at the pins
    // does when the successor misses its landing cycle.
    //
    // The one-cycle-wide clearing is the whole shape of this thing, and the first version got it
    // wrong: it updated stall_block only `else if (take_raw)`, while stall_block itself forces
    // take_raw low - so once it went high it could never come back, and the run that appeared to
    // show "31 restarts then the machine kept streaming" was NOT this code (it predates the
    // word_ok change by three minutes). A stimulus that can only be raised and never dropped is
    // not a stall, it is a dead design, and it will be blamed on whatever it is testing.
    //
    // -DSTALL_EVERY=<n> defines a PREPROCESSOR macro, so read it with a backtick into a
    // localparam: a bare STALL_EVERY token makes verilator look for a variable of that name and
    // the build dies with "Can't find definition of variable".
    `ifdef STALL_EVERY
        localparam integer STALL_N_BYTES = `STALL_EVERY;
    `else
        localparam integer STALL_N_BYTES = 64;
    `endif
    integer stall_n = 0;
    reg     stall_block = 1'b0;
    always @(posedge clk_core) begin
        if (rst_core) begin
            stall_n     <= 0;
            stall_block <= 1'b0;
        end else begin
            // Always droppable, exactly one cycle wide.
            if (stall_block) stall_block <= 1'b0;
            // Never inside the boot check: its 16-byte trailer read is a held acceptance whose
            // whole point is a gapless prefill, and stalling it hangs the design at frame 0 -
            // which is NOT the hardware symptom (the Pocket animates for ~10 s first), so it
            // would have sent me chasing a different bug.
            else if (stall_tick) begin
                stall_n <= (stall_n == STALL_N_BYTES - 1) ? 0 : stall_n + 1;
                if (stall_n == STALL_N_BYTES - 1) stall_block <= 1'b1;
            end
        end
    end
`else
    wire stall_block = 1'b0;
`endif

    wire take    = take_raw;

    // The request level crosses into this clock here, and the acknowledge crosses back in the
    // sequencer. Written as its own process because arm_req_s is read there and driven here - and
    // "declared it, never drove it" is the second time that exact mistake has cost this feature a
    // silent no-op, so the synchroniser is deliberately the first thing after the FIFO it feeds.
    always @(posedge clk_psram) begin
        if (rst_psram) arm_req_s <= 2'b00;
        else           arm_req_s <= {arm_req_s[1:0], arm_req};
    end

    // Drain the request FIFO into part_val as soon as one is waiting and nothing has streamed, so a
    // sweep start finds a HELD part instead of racing a registered FIFO output. Own process, one
    // driver; the timeout is here because a read side that never answers must not leave this in
    // P_WAIT forever - the census watchdog's reasoning, one level down.
    always @(posedge clk_psram) begin
        if (rst_psram) begin
            p_state   <= P_IDLE;
            part_pop  <= 1'b0;
            part_val  <= 3'd0;
            part_held <= 1'b0;
            p_wcnt    <= 8'd0;
        end else begin
            part_pop <= 1'b0;
            if (dir_start) part_held <= 1'b0;   // consumed at the sweep start, right or wrong part
            case (p_state)
            P_IDLE: if (!part_empty && !streamed_q) begin
                        part_pop <= 1'b1;
                        p_wcnt   <= 8'd0;
                        p_state  <= P_WAIT;
                    end
            P_WAIT: if (part_rv) begin
                        part_val  <= part_fw;
                        part_held <= 1'b1;
                        p_state   <= P_IDLE;
                    end else if (&p_wcnt) begin
                        p_state <= P_IDLE;        // never answered: drop it, never wedge
                    end else p_wcnt <= p_wcnt + 8'd1;
            default: p_state <= P_IDLE;
            endcase
        end
    end

    // The one-way gate on part requests. Once the VM has taken a byte, re-pointing the page table
    // would swap the bytes under a running game, and the game cannot be restarted from here: the
    // VM's reset pin is tied to constant 0 inside the generated netlist (see the reset section of
    // core_top), which is upstream's choice - its ROM was SPI flash, readable from the first clock.
    // Own process, own reset, one driver: the multiple-constant-driver failure in this module is
    // documented once already by the boot check's chk_cnt.
    // accept_vm, NOT take. take is "the stream advanced a word" and the consumer runs ahead of the
    // host, so gating on it closed the part-select window before the VM had read a single byte -
    // tb_dir's second run reported streamed=1 late=1 with no reads at all, and the select was
    // refused for a reason that had nothing to do with the game running. The event meant here is the
    // rising edge of the VM's in_ready: the first byte genuinely asked for.
    always @(posedge clk_psram) begin
        if (rst_psram) streamed_q <= 1'b0;
        else if (accept_vm) streamed_q <= 1'b1;
    end
    wire [7:0] c_byte = c_addr[0] ? c_word[15:8] : c_word[7:0];
    wire exhausted  = take & c_addr[0];

    // prefetch is kept only if it is the word that comes after the one handing out
    wire n_keep     = n_v & (n_addr == next_word);
    // The primary handoff window is the cycle a word is exhausted: its successor must
    // already be prefetched or landing. But the FIFO's read side can only be popped
    // every other core cycle (pend is a register), so the consumer's ceiling is exactly
    // the two core cycles (80.8 ns) a continuous stream needs per word, and a PSRAM read
    // (twelve 92.8125 MHz cycles plus the idle cycle every read parks in = 140 ns) is
    // slower than that. Where a stream starts in the fetch pipeline therefore decides
    // whether the successor lands ON the exhausting cycle or one cycle AFTER it, and the
    // late arrival has to count too. Without it the reader rewinds every other word on
    // any continuous stream, which is how the boot check's sixteen bytes degenerated
    // into four repeated zeros.
    wire late_handoff = (c_state == C_RUN) & want & c_served & ~take_raw
                       & landing & (land_addr == next_word) & ~stall_block;
    wire handoff    = (exhausted & (n_keep | (landing & (land_addr == next_word)))
                       | late_handoff) & ~stall_block;
    // Wanted a byte and cannot deliver one. `& ~word_ok` keeps this from firing when the word IS
    // in hand and something else held the take (the prefill gate: `take` also requires
    // `c_served | prefill_ok`, and a held acceptance with a low FIFO level blocks a byte that is
    // sitting right there). Restarting in that case throws away the word the restart needs, then
    // re-aims the producer through the two-flop synchroniser and drains stale FIFO words before
    // it can arrive again - which is why a frequent restart freezes the machine while a rare one
    // recovers. Do not restart if you can hand the byte out; wait for the gate instead.
    wire rewind     = (c_state == C_RUN) & want & c_served & ~take & ~handoff & ~word_ok;

    // ---- where a restarted stream picks up, decided by WHO is waiting ----------------
    // There is no single right answer, and the year of symptoms in this file is what proves it:
    // build 1040 resumed at the acceptance's first byte and played the intro with sheared text;
    // build 1041 resumed at the next byte owed and played it straight, then froze at ~10 s. Each
    // half was correct for one consumer and fatal for the other, so the reader has to tell them
    // apart instead of choosing. It can, exactly and cheaply:
    //
    //   * op_drawString and the boot-header read ask for data with address bit 20 set - vm.si
    //     builds them as `(1<<20) | (start<<8) + (start<<6)` and `(1<<21) - 32` (op_drawString
    //     935, header 366). Both hold their own write position across a gap, so they must NOT be
    //     served a byte twice: that is the shear.
    //   * A bytecode fill asks for an address in the low megabyte (segBytecode is one of the four
    //     segment offsets and the boot check requires off0 == 0, so a fill is always a bytecode
    //     offset), and its write pointer is the thing a gap resets. It must be restarted from the
    //     top - not because that is where the VM is, but because that is where ITS pointer went.
    //   * A palette load (vm.si:763) also sits below the megabyte and DOES hold its position, so
    //     this rule re-serves it after a gap and shifts that palette. That is the one knowingly
    //     imperfect corner: it is cosmetic, it needs a gap inside a 64-byte read, and the
    //     PREFILL_MARGIN above is what makes it rare - whereas the alternative corner is a dead
    //     machine. It is written here rather than hidden because it will be the first thing a
    //     reader wants to argue with.
    wire resume_from_start = ~c_start[20] & (acc_cnt < 7'd64);
    wire [20:0] resume_addr = resume_from_start ? c_start : c_addr;

    // Between streams the FIFO is drained, so a check can never serve a word left
    // over from the previous stream (its seek would terminate on the stale entry).
    wire drain = (c_state == C_IDLE) & ~sf_empty;
    // Pop whenever there is no USEFUL prefetch in hand - not merely no prefetch.
    //
    // The first version asked ~n_v here, and that silently locked the bus on a slow
    // chip. A seek leaves n_word holding whatever landed while it was looking (the
    // C_SEEK landing handler drops those words and does not touch the prefetch), so
    // the reader entered C_RUN with n_v=1 and n_addr pointing somewhere else: ~n_v
    // said "do not pop", nothing could land, so no handoff could happen, and the
    // first exhausted word rewound a fill that had 32 perfectly good words sitting
    // in the FIFO behind it. It went unseen at seven cycles per read because the
    // producer was then fast enough that the landing word was always the one wanted
    // on the very cycle it mattered; at twelve cycles per read (what tAA at the pins
    // actually requires - see aw_psram) the stale prefetch holds the bus and the
    // stream never gets past its first two bytes. n_keep is the honest predicate:
    // a prefetch you cannot use is the same as no prefetch, and the landing handler
    // below already replaces it on exactly that condition.
    wire pop   = drain | (c_run & ~sf_empty & ~pend & ((c_state == C_SEEK) | ~n_keep));

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
            rom_dbg_rd_bytes <= 32'd0;
            gap          <= 2'd0;
            c_addr       <= 21'd0;
            c_start      <= 21'd0;
            acc_cnt      <= 7'd0;
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
                start_addr_r <= acc_addr[20:1];
                c_start      <= acc_addr;   // who is asking, and from where: see resume_addr
                acc_cnt      <= 7'd0;
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
                // Restart the READ, not the stream. The signal keeps its old name (the benches
                // probe it) and the name is the wrong word for what has to happen here.
                //
                // This used to do `c_addr <= c_start`: back to the address the acceptance began,
                // handing out again bytes the VM has already consumed. Nothing tells the VM. It
                // keeps its own position - op_drawString holds in_ready for a whole strip and
                // advances pix_waddr once per byte - so every re-served byte shifted everything
                // written after it.
                //
                // Measured on the copy-protection screen (build log /tmp/p0c.log): 405 restarts,
                // every one of them after exactly 158 bytes, because a PSRAM word costs ~140 ns
                // while the VM eats two bytes every ~80 ns and the prefetch FIFO therefore drains.
                // The 200-row text strip became the same 158-byte pattern repeated, and since
                // 320 mod 158 = 4, each row of it began four pixels along from the row above:
                // the "every line of text is offset to the left" report, to the pixel.
                //
                // c_addr already names the next byte the consumer has NOT been given, so the
                // recovery is to seek the word containing that byte and hand it out. Nothing is
                // repeated. The boot check benefits the same way - its shift register used to be
                // re-fed from the trailer start, which is one reason the trailer could fail to
                // validate however well the chip answered.
                // Keep a prefetch that IS the word the restart needs. This is the whole fix:
                // the word containing c_addr routinely lands in the prefetch slot one cycle before
                // the stall (measured in build/logs/rt-stall200.log: LAND addr=00008b while
                // want=00008a, then REWIND from=000116, whose word is 00008b). Clearing n_v there
                // discarded it, and getting it back costs the full teardown: producer re-aim
                // through the two-flop synchroniser, then popping every stale word still queued
                // behind it before the re-read surfaces (the trace shows want=00008b held while
                // LANDs run 00008c..0000a2 and the level falls 24->14). Adopting it instead costs
                // one register load and no bus traffic at all.
                //
                // The position moves to resume_addr - and this line is the whole difference
                // between "the intro plays with straight text" and two symptoms that have now
                // been chasing each other through four builds. The first version of this fix
                // declared resume_addr, described it at length, let tb_soc probe it - and left the
                // rewind resuming at c_addr anyway, which the A/B caught in one run: 121 shifted
                // fills, identical to build 1041. A wire nothing consumes is not a policy.
                //
                //   * resuming at c_addr (a strip, or anything past a fill's budget): nothing is
                //     repeated, which is what a consumer that keeps its own pixel pointer needs.
                //   * resuming at c_start (a bytecode fill): bytes the VM has already had are
                //     handed out AGAIN, and that is right here, because the gap reset the fill's
                //     write pointer to 0 - its byte 0 is the next byte it will write, whatever
                //     the reader thinks it owes. Self-healing too: if the re-served stream gaps
                //     again, the pointer is already 0 and it restarts from 0 again.
                if (n_v && n_addr == {1'b0, resume_addr[20:1]}) begin
                    c_word  <= n_word;
                    c_waddr <= n_addr;
                    c_v     <= 1'b1;
                    n_v     <= 1'b0;
                    c_addr  <= resume_addr;
                    acc_cnt <= resume_from_start ? 7'd0 : acc_cnt;
                    c_state <= C_RUN;      // no gap, no seek, no producer re-aim
                end else begin
                    c_addr       <= resume_addr;
                    acc_cnt      <= resume_from_start ? 7'd0 : acc_cnt;
                    start_addr_r <= resume_addr[20:1];
                    c_v          <= 1'b0;
                    n_v          <= 1'b0;
                    c_served     <= 1'b0;
                    c_state      <= C_GAP;
                    gap          <= 2'd2;
                end
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
                // How deep into this acceptance we are, saturating at 64: the only evidence the
                // reader has that a fill's 63-byte budget is spent and the waiter can no longer
                // be one (see resume_addr).
                if (acc_cnt != 7'h7f) acc_cnt <= acc_cnt + 7'd1;
                // count the bytes the VM got, not the boot check's own reads
                if (!chk_active) rom_dbg_rd_bytes <= rom_dbg_rd_bytes + 32'd1;
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
                // busy follows the caller: a held acceptance keeps it high, a pulsed one sees
                // it fall with the byte it was waiting for. During the boot check it follows
                // the bytes that remain instead, because host_rdy is (chk_cnt != 0) and on the
                // sixteenth byte that is still 1: the check latched busy_q high, busy_q is only
                // ever updated on `take`, and with the VM held off by that same busy no further
                // take could arrive - the VM waits in `while (mem.busy) {}`, so the design
                // booted nothing at all: 0 bytes, forever, at 60 Hz.
                //
                // Clearing busy_q when the consumer parks was tried and is wrong twice over:
                // without c_served it cleared between an acceptance and the byte landing, so
                // tb_rom's readByte latch took the bus early (first byte 5a, the model's
                // unloaded-fill value, then a one-byte-per-read drift, 22 errors); with
                // c_served it never fired in the assembled design at all, because the check
                // leaves through `rewind`, which clears c_served on the way to C_IDLE. This
                // fixes the actual claim - the check's last byte lowers busy - and does not
                // touch the VM's own path, where chk_active is 0 by definition.
                busy_q <= chk_active ? (chk_cnt != 5'd1) : host_rdy;
            end

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

            // Armed by the directory sweep finishing, NOT by the upload edge. That ordering is the
            // whole point of this block: the boot check reads the trailer through the page table, so
            // a check that runs while the table is still identity reads frame body bytes, fails
            // off0 == 0, paints ERR_TRAILER and holds rom_ready low forever on every paged image.
            // dir_done_rise also covers the un-armed case - dir_done resets high, so the first sync
            // produces a rise and a check runs, which is what a plain pack has always done.
            if (dir_done_rise) chk_pending <= 1'b1;

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

    // ---- directory arming and status, seen from clk_core --------------------------------------
    // Three events ask for the directory to be read: an upload finished, the retry timer expired,
    // and a part write landed in the interact window. All three toggle, and the sweep's clock
    // watches the toggle change rather than a level - see the arming note in the sequencer.
    // Three events ask for the directory: an upload finished, the retry timer expired, and a part
    // write landed in the interact window. They set a sticky pending, and the handshake below is the
    // only thing that clears it - after the far side has acknowledged. An event that arrives while a
    // handshake is in flight sets pending again and gets its own sweep, which is the property the
    // collapsed toggle did not have.
    reg arm_pending, arm_req;
    reg [1:0] arm_ack_s, arm_phase;
    reg pack_written_d;
    // EDGES only. pack_written is a level that stays high for as long as the trailer has been written
    // and the bridge has gone quiet - which is forever - and feeding it to a re-triggerable handshake
    // armed a sweep, which finished, was armed again, and again, forever. rom_ready could then only
    // rise in the gap between two sweeps, and tb_top's "rom_ready rose after the trailer check" timed
    // out at 27 ms while every other bench kept passing, because the others do not watch for rom_ready
    // staying up. The old code fed the same level to a one-shot chk_pending, where it was harmless -
    // which is exactly how a level/edge mistake survives a refactor of the block around it.
    // ... and only until the VM has taken its first byte, which is the same rule the part select
    // uses and for the same reason: after that the answer cannot change, because a switch is refused
    // and a re-read of the same directory installs the same table. Without this gate the sweep runs
    // again about ten milliseconds after the upload (pack_written rises when the bridge goes quiet,
    // which is AFTER the boot check passed and the VM started), steals the chip for a microsecond
    // from a streaming VM, and tb_soc then loses the anchor of one legitimate 64-byte fill - 64
    // writes "with no acceptance open", whose bytes are in fact correct (found at 0x10dc of
    // part0.bin, one word past where the bench had recorded the acceptance). The design was right
    // and the measurement was disturbed, which is a bad trade for a diagnostic that must be trusted.
    wire arm_evt = (allc_edge | (pack_written & ~pack_written_d) | (&retry_cnt)) & ~streamed_c;
    always @(posedge clk_core) begin
        if (rst_core) begin
            arm_pending <= 1'b0;
            arm_req     <= 1'b0;
            arm_ack_s      <= 2'b00;
            arm_phase      <= 2'd0;
            pack_written_d <= 1'b0;
        end else begin
            arm_ack_s      <= {arm_ack_s[0], arm_ack};
            pack_written_d <= pack_written;
            if (arm_evt) arm_pending <= 1'b1;
            case (arm_phase)
            2'd0: if (arm_pending) begin arm_req <= 1'b1; arm_phase <= 2'd1; end
            2'd1: if (arm_ack_s[1]) begin
                      arm_req <= 1'b0;
                      arm_phase <= 2'd2;
                      // only consumed if nothing new arrived in this same cycle
                      if (!arm_evt) arm_pending <= 1'b0;
                  end
            2'd2: if (!arm_ack_s[1]) arm_phase <= 2'd0;   // wait for the drop before re-asserting
            default: arm_phase <= 2'd0;
            endcase
        end
    end

    reg  [1:0]  streamed_c;      // streamed_q in clk_core: the directory is frozen after this
    reg  [1:0]  dd_s;
    reg  [12:0] dir_stat_c;
    reg         dir_stat_tog_c;
    reg  [2:0]  late_s;
    always @(posedge clk_core) begin
        if (rst_core) begin
            dd_s            <= 2'b00;
            dir_stat_c      <= 13'd0;
            dir_stat_tog_c  <= 1'b0;
            late_s          <= 3'd0;
            streamed_c      <= 2'b00;
        end else begin
            dd_s <= {dd_s[0], dir_done};
            // Sampled on the edge, never continuously: the producer writes the word first and flips
            // the toggle after, so an edge-sampled read cannot see a half-updated status.
            if (dir_stat_tog !== dir_stat_tog_c) begin
                dir_stat_tog_c <= dir_stat_tog;
                dir_stat_c     <= dir_stat;
            end
            late_s     <= {late_s[1:0], part_late};  // single bit: a chain is the right tool here
            streamed_c <= {streamed_c[0], streamed_q};
        end
    end
    wire dir_done_core = dd_s[1];
    wire dir_done_rise = dd_s[1] & ~dd_s[0];

    assign rom_dir_valid = dir_stat_c[12];
    assign rom_dir_bad   = dir_stat_c[11];
    assign rom_pool_ok   = dir_stat_c[10];
    assign rom_part      = dir_stat_c[9:7];
    assign rom_dir_err   = dir_stat_c[6:0];
    assign rom_part_late = late_s[2];

    assign rom_chk_data = chk_data;

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
        $display("  CHECK data=%h off=[%0d %0d %0d %0d] ok=%b ovf=%b",
                 chk_data, off0, off1, off2, off3, offs_ok, seen_overflow);
`endif

    always @(posedge clk_core) begin
        if (rst_core) begin
            rom_ready <= 1'b0;
            rom_error <= ERR_NONE;
        end else begin
            // Overflow is the fatal report: it says the drain is too slow, which is
            // a fact about this design. (The old ERR_WAIT path is gone - WAIT idles
            // high on the fitted part and was never a handshake; see aw_psram.)
            if (seen_overflow) rom_error <= ERR_OVERFLOW;
            // rom_ready also waits for the census - not for it to agree, on this first cut:
            // reporting is the point, and a census bug must not become a boot that never
            // happens. The ordering is what makes the number meaningful: the VM does not
            // start streaming while the sweep still owns the chip.
            //
            // Only when one was armed though. Gating unconditionally is how tb_write came
            // back rom_ready=0 with 231 errors: that bench never completes an upload, so
            // nothing arms a census, and a design waiting for a sweep nobody asked for is
            // indistinguishable from a design waiting forever.
            // A sweep in flight drops rom_ready, and the check re-raises it (the sweep's completion
            // arms the check above). That is what makes a boot-time part select honest: the trailer
            // that was validated is the trailer under the table now installed, not the one that
            // happened to be readable when the upload finished.
            if (!dir_done_core) rom_ready <= 1'b0;
            if (chk_done && !seen_overflow && dir_done_core
                && (!vfy_arm | census_done_core | cen_budget_out)) begin
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

    // ============================================================ census out ====
    // Arm the sweep once the pack is in. pack_written is a level and stays high, which is
    // fine: census_done in the other domain makes the start a one-shot.
    always @(posedge clk_core) begin
        if (rst_core)             vfy_arm <= 1'b0;
        else if (allc_edge | pack_written) vfy_arm <= 1'b1;
    end

    // Crossing to clk_core: three single-bit flags get two-flop synchronisers, and the sums
    // cross as quasi-static data - the accumulators stop changing the cycle census_done
    // rises, and the flag is two flops old by the time anything downstream is told to
    // believe them. That is the case the CDC rules allow without a fifo; a wide bus clocked
    // blind across an async boundary is still not, so these words go to the debug console
    // and nowhere near control.
    //
    // An earlier revision latched them into clk_core registers on the synchronised done
    // flag, and that copy never ran under the C++ simulator: the condition was true and
    // observable (flag synchronised, copied flag low, reset low), the generated C++ looked
    // correct, and the reported sums sat at 00000000 while the accumulator inside the design
    // held the right number - in two different block layouts. A pipeline stage whose only job
    // is to move settled numbers is the first thing to delete when it misbehaves: the
    // alternative is trusting a report you cannot test, and being testable is why the census
    // exists.
    // A budget, not a lease: if no census finishes within ~0.67 s of arming (five times the
    // 135 ms a full sweep needs), boot proceeds without it and the report says so. rom_ready
    // must never depend on a diagnostic - that is how "add a check" turns into a black screen.
    reg  [23:0] cen_budget;
    wire        cen_budget_out = &cen_budget;
    reg [1:0] cen_done_p, cen_gap_p, cen_to_p;
    always @(posedge clk_core) begin
        if (rst_core) cen_budget <= 24'd0;
        else if (census_done_core) cen_budget <= 24'd0;
        else if (vfy_arm && !cen_budget_out) cen_budget <= cen_budget + 24'd1;
    end

    always @(posedge clk_core) begin
        if (rst_core) begin
            cen_done_p <= 2'b00;
            cen_gap_p  <= 2'b00;
            cen_to_p   <= 2'b00;
        end else begin
            cen_done_p <= {cen_done_p[0], census_done};
            cen_gap_p  <= {cen_gap_p[0],  (cw_n != cw_max)};
            cen_to_p   <= {cen_to_p[0],   census_to};
        end
    end
    assign census_done_core = cen_done_p[1];

    assign rom_census_sum_r = cr_sum;
    assign rom_census_sum_w = cw_sum;
    assign rom_census_qmism = { (cw_q[3] != cr_q[3]), (cw_q[2] != cr_q[2]),
                                (cw_q[1] != cr_q[1]), (cw_q[0] != cr_q[0]) };
    assign rom_census_stat  = { cen_to_p[1] | cen_budget_out, census_done_core, cen_gap_p[1] };

    // =============================================================== the chip ===
    aw_psram u_psram (
        .clk         (clk_psram),
        .rst         (rst_psram),
        .st_cfg      (st_cfg),

        .wr_req      (wr_req),
        .wr_addr     (wr_addr),
        .wr_data     (wr_wdata),
        // The self-test owns the byte enables for its own access; the loader's are the
        // straddling-entry mask. Both are held stable until wr_ready, which is the
        // controller's contract - it latches wr_be on the take edge.
        .wr_be       (st_s == ST_WR ? st_be : d_be),
        .wr_ready    (wr_ready),

        .rd_req      (rd_req),
        .rd_addr     (rd_addr),
        .rd_tag      (rd_tag_w),        // the address being issued, latched with the read
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
