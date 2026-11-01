// -----------------------------------------------------------------------------
// Testbench for aw_rom: does the pack get into the PSRAM and come back out as the
// byte stream the VM expects?
//
// The VM's whole view of the game is five signals, and two access patterns
// (single-byte readByte, 64-byte preload). This drives a real pack through them
// and compares every byte against the file it came from. It is deliberately
// written as the VM would behave - wait on busy, count data_available, hold
// in_ready - because a testbench that polls differently can pass while the core
// fails.
//
// The three clocks are started at unrelated offsets and have unrelated periods
// (74.25 is not an integer multiple of 24.75 in phase here), so the FIFO crossings
// are exercised as asynchronous, not as a tidy 2:1 dance.
//
// Run: scripts/sim_rom.sh [pack.bin]
// -----------------------------------------------------------------------------
`timescale 1ns/10ps

module tb_rom;

    localparam integer PACK_BYTES = 2097136;          // one pack: 2 MiB - 16
    localparam integer PACK_WORDS = PACK_BYTES / 4;
    localparam [23:0]  TRAILER    = 24'h1fffe0;       // (1<<21) - 32

    // ---------------------------------------------------------------- clocks
    reg clk_core = 1'b0;
    reg clk_psram = 1'b0;
    reg clk_bridge = 1'b0;

    real T_CORE = 1000.0/24.75;      // 40.404 ns
    real T_PSRAM = 1000.0/92.8125;   // 10.77 ns PSRAM sequence clock (PLL outclk2)
    real T_BRIDGE = 1000.0/74.25;    // 13.468 ns

    always #(T_CORE/2)  clk_core   = ~clk_core;
    always #(T_PSRAM/2) clk_psram  = ~clk_psram;
    always #(T_BRIDGE/2) clk_bridge = ~clk_bridge;

    // start them apart: nothing here should depend on a shared edge
    initial begin
        clk_core = 0; #3.1 clk_psram = 0; #7.7 clk_bridge = 0;
    end

    // ---------------------------------------------------------------- reset
    // mirrors core_top: the bridge comes out first, the design only after the
    // clocks are up and a pack is understood
    reg rst_bridge = 1'b1;
    reg rst_psram  = 1'b1;
    reg rst_core   = 1'b1;
    reg design_reset_n = 1'b0;

    // ---------------------------------------------------------------- dut
    reg  [23:0] mem_addr;
    reg         mem_in_ready;
    wire [7:0]  mem_data;
    wire        mem_data_available;
    wire        mem_busy;

    reg         bridge_wr;
    reg  [31:0] bridge_addr;
    reg  [31:0] bridge_wr_data;
    reg         dataslot_allcomplete;

    wire        rom_ready;
    wire [1:0]  rom_error;
    wire        rom_loading;

    wire [5:0]  cram0_a;
    wire [15:0] cram0_dq;
    wire        cram0_clk, cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n;
    wire        cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n;
    wire        cram0_wait;   // driven by the model
    wire [15:0] rom_selftest_die0;
    wire [15:0] rom_selftest_be;
    wire [15:0] rom_selftest_ceneg;
    wire [15:0] rom_selftest_cre;
    wire [15:0] rom_selftest_pack0;

    // The bitstream censuses the whole 2 MiB (CENSUS_RANGE default); the bench sweeps the
    // first 32 Ki words, which exercises the same accumulate / compare / report / timeout
    // path in a few milliseconds instead of 135. See the census block in aw_rom.
    localparam [21:0] CEN_RANGE = 22'h008000;

    aw_rom #(.CENSUS_RANGE(CEN_RANGE)) dut (
        .clk_core(clk_core), .rst_core(rst_core),
        .mem_in_ready(mem_in_ready), .mem_addr(mem_addr), .vm_running(~rst_core),
        .mem_data(mem_data), .mem_data_available(mem_data_available),
        .mem_busy(mem_busy),
        .clk_psram(clk_psram), .rst_psram(rst_psram),
        .clk_bridge(clk_bridge), .rst_bridge(rst_bridge),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr),
        .bridge_wr_data(bridge_wr_data),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rom_ready(rom_ready), .rom_error(rom_error), .rom_loading(rom_loading),
        .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait),
        .cram0_clk(cram0_clk), .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
        .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .rom_selftest_die0(rom_selftest_die0),
        .rom_selftest_be(rom_selftest_be),
        .rom_selftest_ceneg(rom_selftest_ceneg),
        .rom_selftest_cre(rom_selftest_cre),
        .rom_selftest_pack0(rom_selftest_pack0),
        .rom_census_sum_r(cen_sum_r), .rom_census_sum_w(cen_sum_w),
        .rom_census_qmism(cen_qmism), .rom_census_stat(cen_stat),
        .tbl_wr(tbl_wr), .tbl_widx(tbl_widx), .tbl_wval(tbl_wval),
        .rom_tbl_loaded(tbl_loaded)
    );

    // Page-table load port, driven here because the boot loader that will drive it in hardware
    // does not exist yet (task #18). See the `paging` block below for why the bench has to be
    // able to move the map, not just read it.
    reg        tbl_wr   = 1'b0;
    reg [5:0]  tbl_widx = 6'd0;
    reg [7:0]  tbl_wval = 8'd0;
    wire       tbl_loaded;

    task automatic set_page(input integer view_page, input integer phys_page);
        begin
            @(negedge clk_psram);
            tbl_widx = view_page[5:0];
            tbl_wval = phys_page[7:0];
            tbl_wr   = 1'b1;
            @(negedge clk_psram);
            tbl_wr   = 1'b0;
            @(negedge clk_psram);
        end
    endtask

    // Whole-pack census readouts. The oracle is the model's own array: psram0.mem is what
    // is in the chip, the census reports what the design thinks it committed and what it
    // read back, and the three only have to agree, not agree with each other by
    // construction. +SKIP=<word> withholds one bridge word from the upload - a lost write,
    // which is the failure this whole instrument exists to catch - and the census must say
    // so instead of calling the boot healthy.
    wire [31:0] cen_sum_r, cen_sum_w;
    wire [3:0]  cen_qmism;
    wire [2:0]  cen_stat;              // {timeout, done, gap}
    integer     skip_i = -1;

    aw_psram_model psram0 (
        .clk(clk_psram), .a(cram0_a), .dq(cram0_dq),   // the chip's CLK pin is held low by
                                                      // the controller; this is time, not it
        .adv_n(cram0_adv_n), .cre(cram0_cre),
        .ce0_n(cram0_ce0_n), .ce1_n(cram0_ce1_n),
        .oe_n(cram0_oe_n), .we_n(cram0_we_n),
        .ub_n(cram0_ub_n), .lb_n(cram0_lb_n), .wait_hi(cram0_wait)
    );

    // ---------------------------------------------------------------- reference
    reg [7:0] ref_mem [0:PACK_BYTES-1];
    string    pack_hex;
    integer   errors = 0;
    integer   checks = 0;

    initial begin
        void'($value$plusargs("PACE=%d", pace));
        void'($value$plusargs("SKIP=%d", skip_i));
        tripwire = $test$plusargs("TRIPWIRE");
        $display("tb_rom: bridge pace = %0d idle cycles between writes (%0d bytes/s average)",
                 pace, 4 * 74250000 / (pace + 2));
        if (!$value$plusargs("PACK=%s", pack_hex))
            $fatal(1, "tb_rom: +PACK=<pack.hex> is required");
        $readmemh(pack_hex, ref_mem);
    end

    // ---------------------------------------------------------------- load model
    // How fast the host really pushes is the one number here that needs hardware:
    // this bridge revision has no flow-control signal, and a x16 ZBT part addressed
    // one access per two cycles tops out at about 49 MB/s while a bridge write every
    // cycle would be 297 MB/s. So the load is modelled at a chosen average rate, and
    // the impossible rate is tested separately as +TRIPWIRE to confirm that dropping
    // bytes is reported rather than played back as a corrupt game.
    int     pace = 10;          // idle bridge cycles between writes
    bit     tripwire = 0;

    // d is little-endian (the byte belonging at address a is d[7:0]); the APF wire
    // carries that byte at [31:24] for a core declaring bridge_endian_little = 0, the
    // mapping analogue-pocket-utils' data_loader.sv is tested with. Modelling the wire
    // here is what keeps the design honest: while both sides assumed little-endian the
    // whole pack was stored byte-reversed inside every 32-bit entry and every test
    // passed - hardware found it (PSRAM word 0 = 16'he700 for file bytes 04 00 e7 00).
     task automatic bridge_write32(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk_bridge);
        bridge_wr      <= 1'b1;
        bridge_addr    <= a;
        bridge_wr_data <= {d[7:0], d[15:8], d[23:16], d[31:24]};
        @(negedge clk_bridge);
        bridge_wr      <= 1'b0;
        repeat (pace) @(negedge clk_bridge);
    end
    endtask

     task automatic load_pack;
        integer i;
        begin
            for (i = 0; i < PACK_WORDS; i = i + 1) begin
                if (i == skip_i) continue;   // negative control: this word never arrives
                bridge_write32(32'h10000000 + i*4,
                               {ref_mem[i*4+3], ref_mem[i*4+2], ref_mem[i*4+1], ref_mem[i*4]});
                if ((i & 65535) == 0) begin
                    $display("  ... %0d / %0d words at t=%0t", i, PACK_WORDS, $time);
                    $fflush;
                end
            end
            // dataslot_allcomplete: one cycle, and the core must not need more
            @(negedge clk_bridge); dataslot_allcomplete <= 1'b1;
            @(negedge clk_bridge); dataslot_allcomplete <= 1'b0;
        end
    endtask

    // The worst case the bridge protocol allows: a write on every cycle, no gaps.
    // Nothing downstream of this can keep up, so the point of the test is the
    // reporting, not the data.
     task automatic load_full_rate(input integer words);
        integer i;
        begin
            @(negedge clk_bridge);
            for (i = 0; i < words; i = i + 1) begin
                bridge_wr      <= 1'b1;
                bridge_addr    <= 32'h10000000 + i*4;
                // wire order: byte at address i*4 rides at [31:24] - see bridge_write32
                bridge_wr_data <= {ref_mem[i*4], ref_mem[i*4+1], ref_mem[i*4+2], ref_mem[i*4+3]};
                @(negedge clk_bridge);
                if (rom_error === 2) begin
                    bridge_wr <= 1'b0;
                    $display("  overflow reported after %0d words", i);
                    i = words;
                end
            end
            bridge_wr <= 1'b0;
        end
    endtask

    // ---------------------------------------------------------------- read models
    // The 64-byte preload the VM does before executing: in_ready held, count the
    // bytes that data_available says are there.
     task automatic check_stream(input [23:0] start, input integer n, input string what);
        integer got = 0;
        integer guard = 0;
        reg [7:0] b;
        begin
            @(negedge clk_core);
            mem_addr     <= start;
            mem_in_ready <= 1'b1;
            while (got < n && guard < 200000) begin
                @(negedge clk_core);
                guard = guard + 1;
                if (mem_data_available) begin
                    b = mem_data;
                    if (b !== ref_mem[start + got]) begin
                        errors = errors + 1;
                        if (errors < 20)
                            $display("  MISMATCH %s @%06h: got %02h want %02h",
                                     what, start + got, b, ref_mem[start + got]);
                    end
                    got = got + 1;
                    checks = checks + 1;
                end
            end
            mem_in_ready <= 1'b0;
            if (got != n) begin
                errors = errors + 1;
                $display("  STALL %s @%06h: only %0d of %0d bytes in %0d cycles",
                         what, start, got, n, guard);
            end
        end
    endtask


    task automatic peek_one(input [23:0] a, input string what);
        integer guard = 0;
        reg [7:0] b;
        begin
            @(negedge clk_core);
            mem_addr     <= a;
            mem_in_ready <= 1'b1;
            @(negedge clk_core);
            mem_in_ready <= 1'b0;
            while (mem_busy && guard < 20000) begin @(negedge clk_core); guard = guard + 1; end
            checks = checks + 1;
            b = mem_data;
            if (mem_busy) begin
                errors = errors + 1;
                $display("  STALL %s @%06h: busy never dropped", what, a);
            end else
                $display("  peek %s @%06h = %02h (no expectation; nothing was loaded there)",
                         what, a, b);
        end
    endtask

    // readByte(): in_ready for one cycle, then the caller waits for busy to drop
    // and takes mem.data - so data has to still be that byte when busy falls.
    // Same handshake as check_one, but the expected byte is taken from an explicitly named
    // pack offset. Needed to state the address map as a test rather than as a coincidence:
    // the image is flashed at 2 MB and the SoC asks in flash-absolute addresses, so a read
    // at {bank, offset} has to return the byte at `offset` of the one image loaded. check_one
    // cannot express that - it indexes ref_mem with the address it was handed.
    task automatic check_one_at(input [23:0] a, input [20:0] ea, input string what);
        integer guard = 0;
        begin
            @(negedge clk_core);
            mem_addr     <= a;
            mem_in_ready <= 1'b1;
            @(negedge clk_core);
            mem_in_ready <= 1'b0;
            while (mem_busy && guard < 20000) begin
                @(negedge clk_core); guard = guard + 1;
            end
            checks = checks + 1;
            if (mem_busy) begin
                errors = errors + 1;
                $display("  STALL %s @%06h: busy never dropped", what, a);
            end else if (mem_data !== ref_mem[ea]) begin
                errors = errors + 1;
                $display("  MISMATCH %s @%06h: got %02h want %02h (pack[%06h])",
                         what, a, mem_data, ref_mem[ea], ea);
            end
        end
    endtask

     task automatic check_one(input [23:0] a, input string what);
        integer guard = 0;
        begin
            @(negedge clk_core);
            mem_addr     <= a;
            mem_in_ready <= 1'b1;
            @(negedge clk_core);
            mem_in_ready <= 1'b0;
            while (mem_busy && guard < 20000) begin
                @(negedge clk_core);
                guard = guard + 1;
            end
            checks = checks + 1;
            if (mem_busy) begin
                errors = errors + 1;
                $display("  STALL %s @%06h: busy never dropped", what, a);
            end else if (mem_data !== ref_mem[a]) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("  MISMATCH %s @%06h: got %02h want %02h",
                             what, a, mem_data, ref_mem[a]);
            end
        end
    endtask

    // how long a single acceptance takes, from the VM's point of view: upstream's
    // Quad-SPI reader cost about twenty cycles for one byte, and polygon drawing
    // reads a byte at a time, so this is the number that decides whether the core
    // keeps up
     task automatic measure_one(input [23:0] a, output integer cycles);
        integer guard = 0;
        begin
            @(negedge clk_core);
            mem_addr     <= a;
            mem_in_ready <= 1'b1;
            @(negedge clk_core);
            mem_in_ready <= 1'b0;
            while (mem_busy && guard < 20000) begin
                @(negedge clk_core);
                guard = guard + 1;
            end
            cycles = guard + 2;
        end
    endtask

    // throughput of the preload path, bytes per design cycle
     task automatic measure_stream(input [23:0] start, input integer n, output real rate);
        integer got = 0, cyc = 0;
        begin
            @(negedge clk_core);
            mem_addr     <= start;
            mem_in_ready <= 1'b1;
            while (got < n && cyc < 200000) begin
                @(negedge clk_core);
                cyc = cyc + 1;
                if (mem_data_available) got = got + 1;
            end
            mem_in_ready <= 1'b0;
            rate = (cyc == 0) ? 0.0 : real'(got) / real'(cyc);
        end
    endtask

    // ---------------------------------------------------------------- scenario
    integer i, cycles, got_trailer, wcount;
    real rate;
    reg [127:0] trailer_read;
    initial begin
        mem_in_ready = 0; mem_addr = 0;
        bridge_wr = 0; bridge_addr = 0; bridge_wr_data = 0;
        dataslot_allcomplete = 0;

        // clocks up, then out of reset: bridge first, design whenever
        #200;
        rst_bridge = 0;
        repeat (20) @(posedge clk_psram) rst_psram = 0;
        repeat (20) @(posedge clk_core)  rst_core  = 0;

        // the design would be held here; the ROM is usable regardless
        design_reset_n = 1;

        $display("tb_rom: loading %0d bytes", PACK_BYTES); $fflush;
        if (tripwire) begin
            $display("tb_rom: full-rate load, expecting the overflow tripwire");
            $fflush;
            load_full_rate(65536);
            begin
                integer g; g = 0;
                while (rom_error !== 2 && g < 100000) begin @(posedge clk_psram); g = g + 1; end
            end
            if (rom_error === 2)
                $display("tb_rom: tripwire fired -> PASS");
            else begin
                $display("tb_rom: bytes were dropped and nothing said so (rom_error=%0d) -> FAIL",
                         rom_error);
                errors = errors + 1;
            end
            $fflush;
            if (errors != 0) $stop; else $finish;
        end

        load_pack;
        $display("tb_rom: load written, waiting for rom_ready"); $fflush;

        // wait for the check to pass, but never forever: a core that cannot get
        // there should report that, not sit in the simulator until someone kills it
        wcount = 0;
        while (!rom_ready && wcount < 2000000) begin
            @(posedge clk_core);
            wcount = wcount + 1;
        end
        if (!rom_ready) begin
            errors = errors + 1;
            $display("  FAIL: rom_ready never went high after %0d design cycles "
                     + "(rom_error=%0d rom_loading=%0b)", wcount, rom_error, rom_loading);
        end
        // ERR_TRAILER is expected along the way: the retry timer can fire while the
        // host is still writing, and a half-written trailer is not a pack. It has to
        // clear once the real one lands. Overflow (2) and a held WAIT (3) mean data is
        // gone or nothing is moving, and there is no point reading on after either.
        if (rom_error === 2 || rom_error === 3) begin
            errors = errors + 1;
            $display("  FAIL: fatal rom_error=%0d; further reads are meaningless", rom_error);
            $fflush;
            $stop;
        end
        if (rom_error !== 0) begin
            errors = errors + 1;
            $display("  FAIL: ready but still reporting rom_error=%0d", rom_error);
        end

        $display("tb_rom: rom_ready, rom_error=%0d", rom_error); $fflush;

        // 1. the trailer, exactly the way the VM reads it: sixteen bytes shifted
        //    in at the top, so the first byte read ends up in [7:0] (little-endian)
        trailer_read = 0;
        got_trailer  = 0;
        wcount       = 0;      // the rom_ready wait left this at its limit
        @(negedge clk_core);
        mem_addr     <= TRAILER;
        mem_in_ready <= 1'b1;
        while (got_trailer < 16 && wcount < 100000) begin
            @(negedge clk_core);
            wcount = wcount + 1;
            if (mem_data_available) begin
                trailer_read = {mem_data, trailer_read[127:8]};
                got_trailer  = got_trailer + 1;
            end
        end
        if (got_trailer < 16) begin
            errors = errors + 1;
            $display("  FAIL: trailer read stalled after %0d cycles", wcount);
        end
        mem_in_ready <= 1'b0;
        checks = checks + 1;
        $display("tb_rom: trailer = %032h", trailer_read);
        if (trailer_read[31:0] !== 32'd0) begin
            errors = errors + 1;
            $display("  FAIL: bytecode offset is not 0");
        end

        // 2. the start of the bytecode, and the 64-byte preload at three offsets
        //    including an odd one, since the VM starts anywhere in the segment
        check_stream(24'h000000, 64, "preload@0");
        check_stream(24'h000001, 64, "preload@1 (odd)");
        check_stream(24'h002a00, 64, "preload@2a00");
        check_stream(TRAILER, 16, "trailer stream");

        // ---------------------------------------------------------- paging ------
        // Everything above runs under the identity map, so it proves "no regression" and
        // nothing else: a page table that is declared, commented at length, optimised away and
        // never consulted would pass every one of those checks. This core has been bitten by
        // exactly that - 1042's first attempt declared resume_addr, documented it, exposed it to
        // the bench, and left the rewind using c_addr; the A/B only caught it because the
        // candidate reproduced 1041's 121 shifted writes to the byte. So the map gets moved, and
        // the bytes have to follow it.
        begin : paging
            integer pg4, pg3end, pg5, pg7, i, ea;
            pg4     = 4 * 32768;                 // view page 4, the one gets moved
            pg3end  = pg4 - 1;                   // last byte of page 3, must NOT move
            pg5     = 5 * 32768;
            pg7     = 7 * 32768;

            checks = checks + 1;
            if (tbl_loaded !== 1'b0) begin
                errors = errors + 1;
                $display("  FAIL paging: tbl_loaded=%b before any write; identity is the reset state", tbl_loaded);
            end
            check_one_at(pg4 + 8, pg4 + 8, "page 4, identity");

            set_page(4, 7);                      // view page 4 now reads physical page 7
            checks = checks + 1;
            if (tbl_loaded !== 1'b1) begin
                errors = errors + 1;
                $display("  FAIL paging: table written but tbl_loaded still %b", tbl_loaded);
            end
            check_one_at(pg4 + 8, pg7 + 8, "page 4 remapped onto page 7");
            check_one_at(pg5, pg5, "page 5 undisturbed by the remap");
            check_one_at(pg3end, pg3end, "page 3 tail undisturbed by the remap");

            // The interesting case: a run that crosses into the remapped page mid-stream. The
            // bytes must change source partway through, and this is the only coverage of the
            // producer's one-cycle page-crossing stall. It has to come back byte-exact, not just
            // finish: because the consumer matches a VIEW word tag, a paging bug shows up here as
            // a STALL (busy never drops) or a wrong byte, never as a silent pass.
            for (i = 0; i < 24; i = i + 1) begin
                if (i < 8) ea = pg3end - 7 + i;  // still page 3
                else       ea = pg7 + (i - 8);   // page 4's bytes, coming from physical page 7
                check_one_at(pg4 - 8 + i, ea, "run across the remapped boundary");
            end

            set_page(4, 4);                      // restore, so later checks mean what they say
            check_one_at(pg4 + 8, pg4 + 8, "page 4 restored to identity");
            $display("  paging: page 4 -> 7 -> 4 across 28 reads, 24 of them over the boundary");
        end

        // 3. single-byte reads: even, odd, and at the very last byte of the pack
        for (i = 0; i < 40; i = i + 1)
            check_one(24'h000100 + i, "readByte sweep");
        check_one(24'h000100, "readByte repeat a");
        check_one(24'h000100, "readByte repeat b");
        // The last byte of the *pack*, not of the window: a pack is 2 MiB - 16 bytes, so
        // 0x1FFFF0..0x1FFFFF are outside it and read back as whatever the memory holds.
        check_one(TRAILER - 1, "readByte last pack byte");
        check_one(TRAILER    , "readByte first trailer byte");
        peek_one(24'h1fffff, "past the end of the pack");

        // 3b. Bank aliasing is the specified map, not a fold that happens to work: one image,
        // flashed at 2 MB, and the SoC's own boot read lives at 0x3fffe0 - bank bits are not
        // hypothetical. Pinning this here is what stops a future "widening to 22 bits" or
        // "reject addr[23:21] != 0 as out of range" change from moving every read, or from
        // rejecting the boot read itself, with nothing failing.
        for (i = 1; i < 8; i = i + 1) begin
            check_one_at({i[2:0], 21'h1fffe0}, 21'h1fffe0, "bank alias trailer");
            check_one_at({i[2:0], 21'h000100}, 21'h000100, "bank alias body");
            check_one_at({i[2:0], 21'h100010}, 21'h100010, "bank alias strings");
        end

        // ---- the region at and above 1 MB -------------------------------------------
        // op_drawString reads the pre-rendered string table at (1<<20), and the intro draws
        // text before it draws anything else, yet until now every address this test used was
        // below 0x1FFFFF by way of a window that started at 0. The bug this catches is the
        // one that can only exist here: a 20-bit address tag makes 0x100000 look like 0, so a
        // reader that wants a string byte is handed byte 0 of the pack and nothing below 1 MB
        // can see it.
        check_one(24'h100000, "string ROM: index base");
        check_one(24'h100001, "string ROM: index base + 1");
        check_stream(24'h100000, 64, "string ROM preload");
        check_one(24'h0fffff, "the byte before the string ROM");
        check_one(24'h180000, "string ROM: deep");
        check_one(24'h1fffd0, "string ROM: near the trailer");
        check_stream(24'h1fffd0, 32, "string ROM up to the trailer");

        // 4. a preload immediately followed by a single-byte read at an unrelated
        //    address: the point of the flush, and the case that would silently
        //    return a stale over-fetched byte if the flush were wrong
        check_stream(24'h004000, 64, "preload@4000");
        check_one(24'h012345, "readByte after preload");
        check_stream(24'h012346, 64, "preload after readByte");

        // 5. numbers worth knowing
        measure_one(24'h008000, cycles);
        $display("tb_rom: one byte per acceptance = %0d design cycles", cycles);
        measure_stream(24'h008000, 64, rate);
        $display("tb_rom: preload throughput = %.2f bytes per design cycle", rate);

        // 6. the PSRAM self-test must actually round-trip its pattern: A5A5 written to a
        //    die-1 scratch word and read back through the controller. Build 1030a proved
        //    that this register can sit at its reset value (0000) forever while looking
        //    healthy - nothing else observes it, so it is checked here.
        begin : st_wait
            integer sg = 0;
            // All five probes must land: the four scratch round-trips (normal op, the
            // byte-lane mask, and each remaining control-signal variant - the model now
            // honours the real part's quirks, including UB#/LB# as output enables and a
            // tAA measured pin-to-pin, so a controller that shortcuts any of them fails
            // here instead of on hardware) and the pack word 0 readback, which only
            // matches the file if the UPLOAD actually committed to PSRAM.
            while (((rom_selftest_die0  !== 16'hA5A5) ||
                    (rom_selftest_be    !== 16'hA55A) ||
                    (rom_selftest_ceneg !== 16'hA5A5) ||
                    (rom_selftest_cre   !== 16'hA5A5) ||
                    (rom_selftest_pack0 !== {ref_mem[1], ref_mem[0]})) && sg < 400000) begin
                @(posedge clk_core); sg = sg + 1;
            end
            checks = checks + 5;
            if (rom_selftest_die0 !== 16'hA5A5) begin
                errors = errors + 1;
                $display("  FAIL: self-test normal-op readback = %04h after %0d cycles (want a5a5)",
                         rom_selftest_die0, sg);
            end else
                $display("  ok   self-test normal-op round-trip = a5a5 (after %0d cycles)", sg);
            // Probe B is the byte-lane probe: probe A put A5A5 in the scratch word,
            // probe B then writes 5A5A with ONLY the low byte enabled, so A55A is the
            // one readback that proves the mask masked (high byte survived, low byte
            // changed) - the loader depends on that for every straddling entry, and a
            // whole-word round-trip cannot see either failure.
            if (rom_selftest_be !== 16'hA55A) begin
                errors = errors + 1;
                $display("  FAIL: self-test byte-lane readback = %04h after %0d cycles (want a55a)",
                         rom_selftest_be, sg);
            end else
                $display("  ok   self-test byte-lane/mask round-trip = a55a (after %0d cycles)", sg);
            if (rom_selftest_ceneg !== 16'hA5A5) begin
                errors = errors + 1;
                $display("  FAIL: self-test CE-inverted readback = %04h after %0d cycles (want a5a5)",
                         rom_selftest_ceneg, sg);
            end else
                $display("  ok   self-test CE-inverted round-trip = a5a5 (after %0d cycles)", sg);
            if (rom_selftest_cre !== 16'hA5A5) begin
                errors = errors + 1;
                $display("  FAIL: self-test CRE-high readback = %04h after %0d cycles (want a5a5)",
                         rom_selftest_cre, sg);
            end else
                $display("  ok   self-test CRE-high round-trip = a5a5 (after %0d cycles)", sg);
            if (rom_selftest_pack0 !== {ref_mem[1], ref_mem[0]}) begin
                errors = errors + 1;
                $display("  FAIL: pack word 0 readback = %04h after %0d cycles (want %04h)",
                         rom_selftest_pack0, sg, {ref_mem[1], ref_mem[0]});
            end else
                $display("  ok   pack word 0 readback = %04h matches the file (after %0d cycles)",
                         rom_selftest_pack0, sg);
        end

        // ---- census: does the chip hold the pack? ------------------------------------
        // Wait for the sweep (it runs once, after the upload, with the VM still held), then
        // compare its two numbers against the model's memory over the same range. This is
        // the check the hardware was missing: 1036a and 1037a both reached C0 with the whole
        // 2 MiB "written" while dbg_wr_match was only counting addresses in range.
        begin : cen_chk
            integer i, w, exp_sum, want_gap, lost, exp_q, qfail;
            for (i = 0; i < 3000000 && !cen_stat[1]; i = i + 1) @(posedge clk_core);
            checks = checks + 4;
            $display("  census: stat=%b sum_r=%08h sum_w=%08h qmism=%0h (after %0d cycles)",
                     cen_stat, cen_sum_r, cen_sum_w, cen_qmism, i);
            // Inside the design, because "the report says zero" has at least four different
            // causes (nothing written, nothing read, the sweep stopped early, the copy
            // across the clock domains never ran) and only the registers distinguish them.
            $display("         dut: cw_max=%0d cw_n=%0d cw_sum=%08h | census_last=%0d addr=%0d cr_sum=%08h timed_out=%b",
                     dut.cw_max, dut.cw_n, dut.cw_sum, dut.census_last, dut.census_addr,
                     dut.cr_sum, dut.census_to);
            // Direct, and independent of any summing: a word that still holds the model's
            // power-up pattern is a word the upload never wrote (unless the file has that
            // pattern there). This is the check that found the drain consuming a word on the
            // self-test's write - three words lost every probe round, every round - which no
            // amount of summing would have named, and which 510 checks had been tolerating.
            lost = 0;
            for (i = 0; i < CEN_RANGE; i = i + 1)
                if (psram0.mem[i] === 16'h5A5A &&
                    !(ref_mem[i*2] === 8'h5A && ref_mem[i*2+1] === 8'h5A)) begin
                    if (lost < 6) $display("  FAIL: word %0d never written (file wants %02h%02h)",
                                           i, ref_mem[i*2+1], ref_mem[i*2]);
                    lost = lost + 1;
                end
            checks = checks + 1;
            if (lost != 0 && skip_i < 0) begin
                errors = errors + 1;
                $display("  FAIL: %0d words of the pack never reached the chip", lost);
            end else if (skip_i < 0)
                $display("  ok   every word in the first %0d reached the chip", CEN_RANGE);
            if (!cen_stat[1]) begin
                errors = errors + 1;
                $display("  FAIL: census never finished");
            end
            if (cen_stat[2]) begin
                errors = errors + 1;
                $display("  FAIL: census timed out - the sweep stopped being served");
            end
            // The oracle is the model's own memory over exactly the swept window: what the
            // chip holds, against what the design says it wrote and what it read back.
            exp_sum = 0;
            for (i = 0; i < CEN_RANGE; i = i + 1) exp_sum = exp_sum + psram0.mem[i];
            want_gap = (skip_i >= 0);
            if (cen_stat[0] != want_gap) begin
                errors = errors + 1;
                $display("  FAIL: census gap flag = %0b, wanted %0b (+SKIP=%0d)",
                         cen_stat[0], want_gap, skip_i);
            end
            if (!want_gap && (cen_sum_r !== exp_sum[31:0] || cen_sum_w !== exp_sum[31:0]
                              || cen_qmism !== 4'h0)) begin
                errors = errors + 1;
                $display("  FAIL: census disagrees with the model - read %08h written %08h model %08h qmism %0h",
                         cen_sum_r, cen_sum_w, exp_sum[31:0], cen_qmism);
            end else if (!want_gap)
                $display("  ok   census: %0d words written, read back and equal (%08h)",
                         CEN_RANGE, cen_sum_r);
            // Every quarter must be alive on both sides. This is the check that would have
            // caught the quarter index being bits [20:19] of a 20-bit address: the sums Z
            // reports were right, the mismatch flag was right, and two of the four "which part
            // went bad" buckets were registers tied to zero. A diagnostic that silently cannot
            // fire is worse than none, because its absence gets read as evidence.
            checks = checks + 4; qfail = 0;
            for (i = 0; i < 4; i = i + 1) begin
                if (skip_i < 0 && (dut.cw_q[i] == 32'd0 || dut.cr_q[i] == 32'd0)) begin
                    qfail = qfail + 1;
                    errors = errors + 1;
                    // one literal: Verilator does not accept adjacent-string concatenation
                    $display("  FAIL: quarter %0d never accumulated (written %08h read %08h) - the range or the index is wrong",
                             i, dut.cw_q[i], dut.cr_q[i]);
                end
            end
            // conditional on the loop's own result, because an "ok" printed under two FAILs
            // is the thing that makes a transcript unreadable
            if (skip_i < 0 && qfail == 0)
                $display("  ok   all four quarters accumulated on both sides");
            // ... and a withheld write must light exactly the quarter that holds it, or the
            // mask is decoration: +SKIP=100 is in quarter 0 of a 0x8000-word sweep.
            if (skip_i >= 0 && skip_i < CEN_RANGE) begin
                exp_q = 1 << (skip_i / (CEN_RANGE / 4));
                checks = checks + 1;
                if (cen_qmism !== exp_q[3:0]) begin
                    errors = errors + 1;
                    $display("  FAIL: withheld word %0d is quarter %0d, census said mask %0h (want %0d)",
                             skip_i, skip_i / (CEN_RANGE / 4), cen_qmism, exp_q);
                end else
                    $display("  ok   quarter mask %0h names the withheld word %0d",
                             cen_qmism, skip_i);
            end
            if (want_gap && (cen_sum_r === cen_sum_w)) begin
                errors = errors + 1;
                $display("  FAIL: a withheld word and the census still says the sums match");
            end else if (want_gap)
                $display("  ok   census flags the withheld word %0d (read %08h vs written %08h)",
                         skip_i, cen_sum_r, cen_sum_w);
        end

        $display("");
        $display("tb_rom: %0d checks, %0d errors -> %s",
                 checks, errors, (errors == 0) ? "PASS" : "FAIL");
        $fflush;
        if (errors != 0) $stop; else $finish;
    end

endmodule
