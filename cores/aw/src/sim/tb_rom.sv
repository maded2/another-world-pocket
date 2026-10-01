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
    real T_PSRAM = 1000.0/49.5;      // 20.202 ns
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

    aw_rom dut (
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
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n)
    );

    aw_psram_model psram0 (
        .clk(cram0_clk), .a(cram0_a), .dq(cram0_dq),
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

     task automatic bridge_write32(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk_bridge);
        bridge_wr      <= 1'b1;
        bridge_addr    <= a;
        bridge_wr_data <= d;
        @(negedge clk_bridge);
        bridge_wr      <= 1'b0;
        repeat (pace) @(negedge clk_bridge);
    end
    endtask

     task automatic load_pack;
        integer i;
        begin
            for (i = 0; i < PACK_WORDS; i = i + 1) begin
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
                bridge_wr_data <= {ref_mem[i*4+3], ref_mem[i*4+2], ref_mem[i*4+1], ref_mem[i*4]};
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

        $display("");
        $display("tb_rom: %0d checks, %0d errors -> %s",
                 checks, errors, (errors == 0) ? "PASS" : "FAIL");
        $fflush;
        if (errors != 0) $stop; else $finish;
    end

endmodule
