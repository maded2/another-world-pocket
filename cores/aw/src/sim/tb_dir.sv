// -----------------------------------------------------------------------------
// Testbench for the paged-image directory: can one upload carry all eight parts,
// and does the core read the part it is told to read?
//
// This is task #18's acceptance test, and it is a separate bench for one reason:
// the part-select path is only open until the VM has taken its first byte (after
// that a switch cannot work at all, because the VM's reset pin is tied to constant
// 0 inside the generated netlist), and tb_rom has already read hundreds of bytes by
// the time anything else happens in it. So this scenario needs a simulation of its
// own rather than another block at the end of a bench that had already streamed.
//
// What it proves, in order:
//   1. a directory with the AWP1 magic installs, and the page map moves - a page
//      table that is declared and never consulted passes every other test in this
//      repo, and 1042 proved that "declared" is not "wired";
//   2. the part number comes from the address written, and a re-sweep follows it;
//   3. a part write after the first accepted byte is REFUSED and says so, rather
//      than swapping the bytes under a running game;
//   4. a plain 2 MiB pack (no magic) restores identity rather than keeping whatever
//      table the previous install left behind - the failure mode that looks exactly
//      like a corrupt upload.
//
// It writes a directory and reads a real pack, but never 3 MiB: what is under test is
// the RTL's reading of the format, not the format's size. scripts/build_combined_image.py
// is what proves the real image's tables reassemble all eight parts byte for byte.
//
// Run: scripts/sim_dir.sh [pack.bin]
// -----------------------------------------------------------------------------
`timescale 1ns/10ps

module tb_dir;

    localparam integer PACK_BYTES = 2097136;          // one pack: 2 MiB - 16
    localparam integer PACK_WORDS = PACK_BYTES / 4;
    localparam integer PG         = 32768;            // one view page, bytes

    real T_CORE = 1000.0/24.75;
    real T_PSRAM = 1000.0/92.8125;
    real T_BRIDGE = 1000.0/74.25;
    reg clk_core = 0, clk_psram = 0, clk_bridge = 0;
    always #(T_CORE/2)   clk_core   = ~clk_core;
    always #(T_PSRAM/2)  clk_psram  = ~clk_psram;
    always #(T_BRIDGE/2) clk_bridge = ~clk_bridge;
    initial begin clk_core = 0; #3.1 clk_psram = 0; #7.7 clk_bridge = 0; end

    reg rst_bridge = 1'b1, rst_psram = 1'b1, rst_core = 1'b1;

    reg  [23:0] mem_addr;
    reg         mem_in_ready;
    wire [7:0]  mem_data;
    wire        mem_data_available, mem_busy;
    reg         bridge_wr;
    reg  [31:0] bridge_addr, bridge_wr_data;
    reg         dataslot_allcomplete;
    wire        rom_ready;
    wire [1:0]  rom_error;
    wire        rom_loading;
    wire [5:0]  cram0_a;
    wire [15:0] cram0_dq;
    wire        cram0_clk, cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n;
    wire        cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n, cram0_wait;
    wire [15:0] st_die0, st_be, st_ceneg, st_cre, st_pack0;
    wire [31:0] cen_sum_r, cen_sum_w;
    wire [3:0]  cen_qmism;
    wire [2:0]  cen_stat;
    wire        tbl_loaded;
    wire        dir_valid, dir_bad, dir_busy, part_late, pool_ok_w;
    wire [2:0]  dir_part;
    wire [7:0]  dir_err;

    aw_rom #(.CENSUS_RANGE(22'h8000)) dut (
        .clk_core(clk_core), .rst_core(rst_core),
        .mem_in_ready(mem_in_ready), .mem_addr(mem_addr), .vm_running(~rst_core),
        .mem_data(mem_data), .mem_data_available(mem_data_available), .mem_busy(mem_busy),
        .clk_psram(clk_psram), .rst_psram(rst_psram),
        .clk_bridge(clk_bridge), .rst_bridge(rst_bridge),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rom_ready(rom_ready), .rom_error(rom_error), .rom_loading(rom_loading),
        .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait),
        .cram0_clk(cram0_clk), .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
        .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .rom_selftest_die0(st_die0), .rom_selftest_be(st_be),
        .rom_selftest_ceneg(st_ceneg), .rom_selftest_cre(st_cre),
        .rom_selftest_pack0(st_pack0),
        .tbl_wr(1'b0), .tbl_widx(6'd0), .tbl_wval(8'd0), .rom_tbl_loaded(tbl_loaded),
        .rom_dir_valid(dir_valid), .rom_dir_bad(dir_bad), .rom_part(dir_part),
        .rom_dir_err(dir_err), .rom_dir_busy(dir_busy), .rom_part_late(part_late),
        .rom_pool_ok(pool_ok_w)
    );

    aw_psram_model psram0 (
        .clk(clk_psram), .a(cram0_a), .dq(cram0_dq),
        .adv_n(cram0_adv_n), .cre(cram0_cre),
        .ce0_n(cram0_ce0_n), .ce1_n(cram0_ce1_n),
        .oe_n(cram0_oe_n), .we_n(cram0_we_n),
        .ub_n(cram0_ub_n), .lb_n(cram0_lb_n), .wait_hi(cram0_wait)
    );

    reg [7:0] ref_mem [0:PACK_BYTES-1];
    string    pack_hex;
    integer   errors = 0, checks = 0;
    int       pace = 10;
    // +PART=N selects a part BEFORE the VM accepts its first byte, which is the only window in
    // which a select can be honoured. Two runs therefore: the default one exercises the installed
    // part 0 and the late refusal, +PART=1 exercises a real select. One run cannot do both, and a
    // test that reads bytes first and then expects a select to work is testing the wrong thing -
    // which is exactly what the first version of this bench did, and passed the wrong verdict.
    int       want_part = 0;
    // +NOMAGIC installs a pool and then removes the magic again, to prove a plain pack presented
    // over an installed pool falls back to identity rather than keeping the pool's mapping. Needs
    // its own run for the same reason +PART does: both happen before the first byte.
    int       nomagic   = 0;
    // +HIGH maps view pages onto physical pages ABOVE the old 2 MiB upload limit, including page 127,
    // the last page of die 0, and checks them twice over: against the chip model's own memory (the
    // write landed) and through the VM's byte stream (the map and the read path agree).
    int       highmap   = 0;
    // +POOLSUM: does the core notice a pool that does not add up? The image declares a word sum over
    // the pool, the census measures the chip, and pool_ok is the two agreeing. Tested BOTH ways
    // because a comparator that only ever sees the good case is not a comparator: one byte of the
    // pool is then changed in the chip and pool_ok must go to 0.
    //
    // The window is this bench's CENSUS_RANGE (32 Ki words), not the bitstream's 4 MiB, for the
    // reason tb_rom gives for the same choice: both sides of the comparison are gated by the same
    // parameter, so the numbers mean the same thing - the mechanism is identical, and 1.5 million
    // back-to-back reads would be measuring the test harness's patience.
    int       poolrun   = 0;
    // +BADENT: an entry out of range must refuse the WHOLE table, name the entry, and leave identity.
    // This path existed and had never been driven by a test - every directory the bench wrote was
    // valid, so the refusal that protects against a corrupt or stale table was pure assertion.
    int       badent    = 0;
    // +LATESEL: the part write lands AFTER the upload-complete sweep has already installed part 0.
    // This is the ordering I cannot measure from here - KB-035 says persisted interact values are
    // written "at boot immediately before Reset Exit", which reads like after the dataslot upload -
    // and without a select-arms-a-sweep path the launch installs part 0 and reports success. tb_soc
    // hit exactly this with +PART=1, so it gets its own run rather than staying a footnote.
    //
    // The run passes, and the pass is narrower than it looks: here rst_core is released long before
    // the select, while at launch the core is held in reset through the whole upload, and a select
    // arriving in that window is lost - the arm toggle flips, the core-domain synchroniser is pinned
    // at 0 by the same reset, and no sweep is ever armed (tb_soc trace: arm_t=1, parm_cs=000, no
    // arm_pending edge, dir_valid stuck on the part the boot sweep installed). The fix that does not
    // depend on an edge surviving reset is to read ALL parts' tables at upload and choose the part at
    // read time - 8*64 table words is nothing in M10Ks, and then a select is a level, not an event.
    int       latesel   = 0;

    initial begin
        void'($value$plusargs("PACE=%d", pace));
        void'($value$plusargs("PART=%d", want_part));
        nomagic = $test$plusargs("NOMAGIC");
        highmap = $test$plusargs("HIGH");
        poolrun = $test$plusargs("POOLSUM");
        badent  = $test$plusargs("BADENT");
        latesel = $test$plusargs("LATESEL");
        if (!$value$plusargs("PACK=%s", pack_hex))
            $fatal(1, "tb_dir: +PACK=<pack.hex> is required");
        $readmemh(pack_hex, ref_mem);
    end

    task automatic bridge_write32(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk_bridge);
            bridge_wr <= 1'b1; bridge_addr <= a;
            bridge_wr_data <= {d[7:0], d[15:8], d[23:16], d[31:24]};
            @(negedge clk_bridge);
            bridge_wr <= 1'b0;
            repeat (pace) @(negedge clk_bridge);
        end
    endtask

    // One 32-bit bridge write carries two PSRAM words, the byte for the lowest address in
    // bridge_wr_data[31:24] - the mapping the loader documents and tb_rom's model reproduces.
    task automatic put_words(input integer wi, input [15:0] w0, input [15:0] w1);
        bridge_write32(32'h10000000 + wi*2, {w1, w0});
    endtask

    // A directory by hand: magic, then eight 72-word part records at image word 16 + N*72.
    // Page 3 is the moving page - part 0 reads it from physical page 5, part 1 from page 6,
    // the rest keep it. Entry 0 can never be 0: page 0 IS the directory, and an entry pointing
    // there is the corrupted-table case the layout is designed to make harmless.
    task automatic write_dir;
        int n, k;
        bit [15:0] e0, e1;
        begin
            put_words(0, 16'h5741, 16'h3150);              // "AW", "P1"
            for (n = 0; n < 8; n = n + 1) begin
                for (k = 0; k < 64; k = k + 2) begin
                    e0 = (k == 0) ? 16'd1 : k[15:0];      // entry 0 is never 0: page 0 is the dir
                    e1 = (k + 1 == 3) ? ((n == 0) ? 16'd5 : ((n == 1) ? 16'd6 : 16'd3))
                                      : (k + 1);          // entry 3 is always the odd half
                    put_words(16 + n*72 + k, e0, e1);
                end
            end
        end
    endtask

    // ---- +HIGH: the region above the old 2 MiB limit -----------------------------------------
    // The upload window went 2 MiB -> 4 MiB in 16fe39d, and nothing in the repo had ever written a
    // bridge word at or above 0x10200000 since: tb_rom loads a 2 MiB pack, and the paged tests here
    // move pages inside that 2 MiB. So the widening was compiled and never exercised, which is the
    // same class of gap as "declared but not wired" - and the whole eight-parts-in-one-load premise
    // depends on bytes landing ABOVE that boundary (the pool ends at byte 0x2F0000).
    //
    // The VM's view is 2 MiB, so the only way to read physical page 64 or beyond is THROUGH the page
    // table - which makes this one test cover both the widened window and the map's upper range. Pages
    // 40..61 go to 64..85 and page 62 goes to 127, the last page of die 0: first word past the old
    // limit, and last word the window can name. Entry 63 stays identity because the boot check reads
    // the trailer through the map and has to pass.
    // One entry, one rule. Written as a function rather than "the odd half is the even half plus one"
    // because that shortcut put page 128 in entry 63 - die 1, out of range - and the design refused
    // the whole table, which was the RIGHT answer and a broken test. Entry 63 has to stay identity for
    // a second reason too: the boot check reads the trailer through the map.
    function automatic [15:0] hi_ent(input int k);
        begin
            if      (k == 0)           hi_ent = 16'd1;      // entry 0 is never the directory page
            else if (k >= 40 && k <= 61) hi_ent = 16'(64 + (k - 40));
            else if (k == 62)          hi_ent = 16'd127;    // last page of die 0
            else                       hi_ent = k[15:0];
        end
    endfunction

    task automatic write_dir_high;
        int n, k;
        begin
            put_words(0, 16'h5741, 16'h3150);
            for (n = 0; n < 8; n = n + 1)
                for (k = 0; k < 64; k = k + 2)
                    put_words(16 + n*72 + k, hi_ent(k), hi_ent(k + 1));
        end
    endtask

    // Two words per page, unique per page, written at the FIRST word of the physical page - which is
    // a byte address of page*32768, so page 64 is byte 0x200000: the first byte the old window would
    // have silently dropped at wr_en, with no flow control and no out-of-window error to say so.
    function automatic [15:0] hi_w0(input int pg); hi_w0 = 16'hD000 | pg[7:0]; endfunction
    function automatic [15:0] hi_w1(input int pg); hi_w1 = 16'hD800 | pg[7:0]; endfunction

    task automatic write_hi_data;
        int i, pg;
        begin
            for (i = 0; i < 22; i = i + 1) begin
                pg = 64 + i;
                put_words(pg*16384, hi_w0(pg), hi_w1(pg));
            end
            put_words(127*16384, hi_w0(127), hi_w1(127));
        end
    endtask

    // Two oracles, deliberately independent. The model's own array says the WRITE landed where the
    // address said; the VM's byte stream says the READ path and the table agree with it. Either one
    // alone can pass on an accident: the array alone would miss a broken map, and the byte stream
    // alone could be reading a copy the loader made somewhere else.
    task automatic check_hi(input int vpage, input int ppage);
        integer k;
        reg [7:0] got;
        reg [15:0] want0, want1;
        begin
            want0 = hi_w0(ppage); want1 = hi_w1(ppage);
            checks = checks + 4;
            if (psram0.mem[ppage*16384]   !== want0 ||
                psram0.mem[ppage*16384+1] !== want1) begin
                errors = errors + 4;
                $display("  FAIL model: physical page %0d does not hold what was written (mem=%04h,%04h want %04h,%04h) - the write above the old 2 MiB window was dropped or mis-routed",
                         ppage, psram0.mem[ppage*16384], psram0.mem[ppage*16384+1], want0, want1);
            end
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge clk_core);
                mem_addr     <= vpage*32768 + k;
                mem_in_ready <= 1'b1;
                @(negedge clk_core);
                mem_in_ready <= 1'b0;
                begin : wait_byte
                    int guard = 0;
                    while (mem_busy && guard < 20000) begin @(negedge clk_core); guard = guard + 1; end
                    if (mem_busy) begin
                        errors = errors + 1;
                        $display("  STALL high read @%06h (view page %0d -> physical %0d): busy never dropped",
                                 vpage*32768 + k, vpage, ppage);
                    end else begin
                        got = mem_data;
                        if (got !== ((k == 0 || k == 1) ? want0[k*8 +: 8] : want1[(k-2)*8 +: 8])) begin
                            errors = errors + 1;
                            $display("  MISMATCH high byte @%06h (view %0d -> phys %0d, byte %0d): got %02h want %02h",
                                     vpage*32768 + k, vpage, ppage, k, got,
                                     (k == 0 || k == 1) ? want0[k*8 +: 8] : want1[(k-2)*8 +: 8]);
                        end
                    end
                end
            end
        end
    endtask

    task automatic load_pack;
        integer i;
        begin
            for (i = 0; i < PACK_WORDS; i = i + 1)
                bridge_write32(32'h10000000 + i*4,
                               {ref_mem[i*4+3], ref_mem[i*4+2], ref_mem[i*4+1], ref_mem[i*4]});
            @(negedge clk_bridge); dataslot_allcomplete <= 1'b1;
            @(negedge clk_bridge); dataslot_allcomplete <= 1'b0;
        end
    endtask

    // Re-arm the sweep the way an upload does, and wait for the DESIGN to settle rather than for
    // one signal. Pulsing dataslot_allcomplete arms the directory sweep AND the census, and the
    // census owns the chip for its whole sweep - during which the producer is gated off and every
    // read in this bench would report a hang that belongs to the testbench. rom_ready is the only
    // signal that means "sweep done, census done, trailer checked under the installed table", so
    // the wait is: watch it fall (a sweep is in flight, rom_ready drops while the map changes) and
    // then rise again.
    // Re-arm when the correct outcome is that the core stays down: wait for rom_ready to fall, then
    // give it 20000 core cycles (~0.8 ms, far longer than a sweep and a trailer check) to rise, and
    // require that it did not. rearm()'s "wait for the rise" would sit on its timeout here and then
    // report on whatever state it happened to land in.
    task automatic rearm_down(input string why);
        int g = 0;
        begin
            repeat (6) @(negedge clk_bridge);
            dataslot_allcomplete <= 1'b1;
            repeat (8) @(negedge clk_bridge);
            dataslot_allcomplete <= 1'b0;
            @(negedge clk_core);
            while (rom_ready && g < 200000) begin @(negedge clk_core); g++; end
            repeat (20000) @(negedge clk_core);
            checks = checks + 1;
            if (rom_ready !== 1'b0) begin
                errors = errors + 1;
                $display("  FAIL: rom_ready ROSE with a refused directory - the VM would run on the wrong pages");
            end
            checks = checks + 1;
            if (rom_error !== 2'd3) begin
                errors = errors + 1;
                $display("  FAIL: rom_error=%0d with a refused directory, wanted 3 (bad directory)", rom_error);
            end
            repeat (80) @(negedge clk_psram);
            $display("  re-arm down (%s): dir_valid=%b bad=%b err=%02h rom_ready=%b rom_error=%0d after %0d",
                     why, dir_valid, dir_bad, dir_err, rom_ready, rom_error, g);
        end
    endtask

    // Let whatever the last event armed run to completion: rom_ready drops for the sweep, the trailer
    // check re-runs under the new table, and rom_ready rises again. Deliberately does NOT pulse
    // dataslot_allcomplete - the point is to wait on an arm that came from somewhere else, and
    // pulsing it here would hide a select that arms nothing at all.
    task automatic settle(input string why);
        int g = 0;
        begin
            @(negedge clk_core);
            repeat (400) @(negedge clk_core);       // a select is a level: no sweep, no rom_ready dip
            repeat (120) @(negedge clk_psram);      // status crosses clocks; let it land
            $display("  settle (%s): dir_valid=%b bad=%b part=%0d err=%02h after %0d",
                     why, dir_valid, dir_bad, dir_part, dir_err, g);
        end
    endtask

    task automatic rearm(input string why);
        int g = 0;
        begin
            // Held for eight bridge cycles, not two. ac_s is a three-FF chain clocked by the 24.75
            // MHz design clock, so a two-cycle 74.25 MHz pulse is 27 ns - shorter than one design
            // cycle - and the edge can be missed entirely: the re-arm then does nothing at all, and
            // the bench waits for a rom_ready that never falls. The framework holds this level far
            // longer than that, but a bench that pulses it has to pulse it at the RECEIVER's rate,
            // and "the test passed" that came from the boot-time pack_written path was not testing
            // the re-arm it thought it was.
            repeat (6) @(negedge clk_bridge);
            dataslot_allcomplete <= 1'b1;
            repeat (8) @(negedge clk_bridge);
            dataslot_allcomplete <= 1'b0;
            @(negedge clk_core);
            while (rom_ready && g < 200000) begin @(negedge clk_core); g++; end   // fall
            while (!rom_ready && g < 4000000) begin @(negedge clk_core); g++; end // rise
            repeat (80) @(negedge clk_psram);      // status crosses clocks; let it land
            $display("  re-arm (%s): dir_valid=%b bad=%b part=%0d err=%02h busy=%b after %0d",
                     why, dir_valid, dir_bad, dir_part, dir_err, dir_busy, g);
            $display("        part path: fifo_empty=%b p_state=%0d held=%b val=%0d streamed=%b late=%b",
                     dut.part_empty, dut.p_state, dut.part_held, dut.part_val,
                     dut.streamed_q, part_late);
        end
    endtask

    task automatic check_at(input [23:0] a, input [20:0] ea, input string what);
        int guard = 0;
        begin
            @(negedge clk_core);
            mem_addr <= a; mem_in_ready <= 1'b1;
            @(negedge clk_core);
            mem_in_ready <= 1'b0;
            while (mem_busy && guard < 20000) begin @(negedge clk_core); guard++; end
            checks++;
            if (mem_busy) begin
                errors++;
                $display("  STALL %s @%06h: busy never dropped", what, a);
                $display("        st_s=%0d st_seq=%0d st_wcnt=%0d census_active=%b dir_active=%b",
                         dut.st_s, dut.st_seq, dut.st_wcnt, dut.census_active, dut.dir_active);
                $display("        c_state=%0d want_word=%0h p_addr=%0h page_ready=%b rdat=%0h ridx=%0h",
                         dut.c_state, dut.want_word, dut.p_addr, dut.page_ready,
                         dut.tbl_rdat, dut.tbl_rdat_idx);
            end else if (mem_data !== ref_mem[ea]) begin
                errors++;
                $display("  MISMATCH %s @%06h: got %02h want %02h (pack[%06h])",
                         what, a, mem_data, ref_mem[ea], ea);
            end
        end
    endtask

    task automatic expect_status(input int want_valid, input int want_bad,
                                 input int want_part, input string what);
        begin
            checks++;
            if (dir_valid !== want_valid[0] || dir_bad !== want_bad[0] || dir_part !== want_part) begin
                errors++;
                $display("  FAIL %s: dir_valid=%b bad=%b part=%0d err=%02h, wanted valid=%0d bad=%0d part=%0d",
                         what, dir_valid, dir_bad, dir_part, dir_err, want_valid, want_bad, want_part);
            end
        end
    endtask

    int phys3;

    initial begin
        repeat (20) @(posedge clk_bridge); rst_bridge = 0;
        repeat (20) @(posedge clk_psram);  rst_psram  = 0;
        repeat (20) @(posedge clk_core);   rst_core   = 0;

        // The pack first, with NO directory anywhere in it: the boot that is checked below is the
        // plain-pack boot, which is what every build up to 1042a did and must keep doing.
        //
        // The pack first, then the directory - and that is a bench convenience, not the image
        // layout. A real image has the directory in page 0 and frames from page 1, so they cannot
        // collide; here the 2 MiB pack is loaded at offset 0 and therefore covers page 0 as well, so
        // writing the directory first would only have it overwritten (the first run of this bench
        // did exactly that, and reported "no magic" for a directory that was in the file). Writing
        // it after, then re-arming, is also the stronger test: it proves a sweep RE-reads the
        // directory and moves a table that was already installed, which is what a part switch at
        // boot has to do. View page 0 is never read here, so the two uses of page 0 do not fight.
        load_pack;

        begin
            int g = 0;
            while (!rom_ready && g < 4000000) begin @(negedge clk_core); g++; end
            checks++;
            if (!rom_ready) begin
                errors++;
                $display("  FAIL: rom_ready never rose (error=%b) - the sweep and the boot check",
                         rom_error);
                $display("        must order themselves so the trailer is read UNDER the table.");
                $display("        dir: valid=%b bad=%b part=%0d err=%02h busy=%b selftest D=%04h P=%04h",
                         dir_valid, dir_bad, dir_part, dir_err, dir_busy,
                         st_die0, st_pack0);
            end
        end
        // The order below is not stylistic. The directory is frozen once the VM takes its first
        // byte - after that a switch is refused and a re-read can only install the same table, so a
        // sweep would steal the chip from a streaming VM for nothing (it did, and tb_soc lost the
        // anchor of one legitimate 64-byte fill over it). So everything that needs a sweep happens
        // before the first read, and the reads come as one block at the end.
        expect_status(0, 0, 0, "boot from a plain pack: identity map, and not an error");
        checks++;
        if (dir_err !== 8'h40) begin
            errors++;
            $display("  FAIL: a pack with no directory reported err=%02h, wanted reason 1 (no magic)", dir_err);
        end

        if (nomagic) begin
            // The case the earlier bug makes worth its own run: install a pool, then present a plain
            // pack over it. The table must go back to identity - keeping the pool mapping would read
            // another part's bytes and look exactly like a corrupt upload.
            write_dir;
            rearm("pool installed, then taken away");
            expect_status(1, 0, 0, "pool installed on request");
            put_words(0, {8'h00, ref_mem[0]}, {8'h00, ref_mem[2]});
            rearm("magic removed while a table is installed");
            expect_status(0, 0, 0, "plain pack over an installed pool: identity restored");
            checks++;
            if (dir_err !== 8'h40) begin
                errors++;
                $display("  FAIL: reported err=%02h after removing the magic, wanted reason 1",
                         dir_err);
            end
        end else if (highmap) begin
            write_hi_data;                 // above 0x10200000: the bytes the old window dropped
            write_dir_high;                // view 40..62 -> physical 64..85, and 62 -> 127
            rearm("high pages mapped");
            expect_status(1, 0, 0, "map onto pages above the old limit installed");
        end else if (badent) begin
            // Entry 2 of part 0 set to 0. Page 0 is the directory, so 0 is not a page any view may
            // point at; the sweep must stop, walk the table back, name the entry, and - because
            // identity over a pool means the VM executes the directory as frame 0 and the panel shows
            // animated garbage, the same symptom as the restart bug this port spent two days on -
            // the core must NOT start the VM.
            write_dir;
            put_words(16 + 2, 16'd0, 16'd3);
            rearm_down("directory with entry 2 out of range");
            expect_status(0, 1, 0, "out-of-range entry: nothing installed, reported as bad");
            checks++;
            // reason 2 in bits[7:6], the entry index below: 0x80 | 2. Parenthesised, because `!==`
            // binds tighter than `|` - the unparenthesised version of this line compared dir_err to
            // 0x80 and then ORed 2 into the BOOLEAN result, so it failed on a correct core.
            if (dir_err !== (8'h80 | 8'd2)) begin
                errors++;
                $display("  FAIL err=%02h after a bad entry 2 - wanted reason 2 with entry index 2", dir_err);
            end
            // Recovery: a good directory installed after the bad one must boot. Fault reporting that
            // cannot be cleared is a brick with a nicer message, and "install a good image and
            // relaunch" is the only remedy a user has.
            write_dir;
            rearm("valid directory installed after a refused one");
            expect_status(1, 0, 0, "recovered: the good table is installed and the core booted");
            checks++;
            if (rom_error !== 2'd0) begin
                errors++;
                $display("  FAIL rom_error=%0d after recovery - a cleared fault must stop reporting", rom_error);
            end
        end else if (poolrun) begin
            bit [31:0] psum, pxor;
            int w;
            // The sum the core will measure: pages 1.. only (page 0 is the directory, and its own
            // bytes are not part of what the directory declares), over the words the sweep reaches.
            // PSRAM word w is ref_mem bytes 2w (low) and 2w+1 (high), little-endian.
            psum = 32'd0; pxor = 32'd0;
            for (w = 16384; w < 32768; w = w + 1) begin
                psum = psum + {ref_mem[w*2+1], ref_mem[w*2]};
                pxor = pxor ^ {ref_mem[w*2+1], ref_mem[w*2]};
            end
            write_dir;
            put_words(12, psum[15:0], psum[31:16]);      // image words 12,13 = declared sum
            put_words(14, pxor[15:0], pxor[31:16]);      // and 14,15 = declared xor
            rearm("directory with a declared pool sum");
            expect_status(1, 0, 0, "pool installed with sums");
            $display("        poolsum: cr=%08h declared=%08h census_done=%b active=%b installed=%b cw_max=%0h last=%0h",
                     dut.cr_pool_sum, {dut.hdr_hi, dut.hdr_lo}, dut.census_done, dut.census_active,
                     dut.dir_installed, dut.cw_max, dut.census_last);
            checks = checks + 1;
            if (pool_ok_w !== 1'b1) begin
                errors = errors + 1;
                $display("  FAIL pool_ok=%b with a correct declared sum - the census, the page-0 skip, or the comparison is wrong", pool_ok_w);
            end
            // The negative control. The DECLARED sum is changed, not the pool: the census measures the
            // chip once per power-up (a second sweep would steal the chip from a streaming VM), so the
            // chip cannot be re-measured on demand here - and a sum check cannot tell which side moved
            // anyway. Moving the other side is the same event to the comparator, and it is a real field
            // condition: an image whose declared sum disagrees with the bytes in the chip. Without this
            // control, pool_ok=1 would mean either "matched" or "never compared" - the exact ambiguity
            // this port has been bitten by over and over.
            put_words(12, psum[15:0] ^ 16'h0001, psum[31:16]);   // declared sum, off by one
            rearm("declared pool sum now disagrees with the chip");
            checks = checks + 1;
            if (pool_ok_w !== 1'b0) begin
                errors = errors + 1;
                $display("  FAIL pool_ok=%b after corrupting the declared sum - the check is not comparing anything", pool_ok_w);
            end
            expect_status(1, 0, 0, "a disagreeing pool still installs (the table is valid; the SUM is what failed)");
            // And the second comparator on its own terms: sum restored to the true value, xor left one
            // bit off. If pool_ok came back 1 here, the xor would be decoration - which matters because
            // a checksum alone is satisfied by two words trading places, and a page table trading pages
            // is exactly the failure this feature can produce.
            put_words(12, psum[15:0], psum[31:16]);
            put_words(14, pxor[15:0] ^ 16'h0001, pxor[31:16]);
            rearm("declared sum correct, declared xor one bit off");
            checks = checks + 1;
            if (pool_ok_w !== 1'b0) begin
                errors = errors + 1;
                $display("  FAIL pool_ok=%b with a wrong declared xor - the second comparator is decoration", pool_ok_w);
            end
        end else begin
            write_dir;
            rearm("directory written after the pack");
            expect_status(1, 0, 0, "pool directory installed");
        end

        // Part select, and it has to happen HERE: the gate closes at the VM's first accepted byte,
        // because a switch after that could not reset the game (its reset pin is tied to constant 0
        // inside the generated netlist) and would swap the bytes under a running one. The ADDRESS
        // picks the part - 0x00F0_0004 is part 1 - and nothing about the data written matters.
        if (want_part > 0 && latesel) begin
            // The awkward order: the boot sweep has installed part 0, and now the select arrives.
            // Nothing else is going to arm a sweep, so if the select does not, the table stays part
            // 0 and the reads below would pass only by reading the wrong part's bytes - which is
            // precisely the failure the phys3 check is here to make impossible.
            bridge_write32(32'h00F0_0000 + want_part*4, 32'h0000_0001);
            settle("part write AFTER the boot sweep installed part 0");
            expect_status(1, 0, want_part,
                          "a select landing after the boot sweep still installs its own part");
        end else if (want_part > 0) begin
            bridge_write32(32'h00F0_0000 + want_part*4, 32'h0000_0001);
            rearm("part write before the first byte");
            expect_status(1, 0, want_part, "part selected from an address write");
        end

        // Now the reads - the first bytes of the session. Page 3 is the page the directory sent
        // somewhere else (part 0 reads it from physical page 5, part 1 from page 6), so a byte read
        // there comes from where the table says. A table that is declared, commented at length,
        // optimised away and never consulted fails here instead of passing, which is the whole reason
        // this bench exists: 1042 proved "declared" is not "wired".
        phys3 = (want_part == 1) ? 6 : 5;
        // +BADENT is NOT in this list on purpose. It ends with a good directory installed after the
        // refused one, so by the time the reads run the map is the pool's and page 3 reads from
        // physical page 5 like run 1 - the recovery is real, not just a status bit.
        if (nomagic || highmap) phys3 = 3;             // identity: page 3 is its own (the +HIGH map
                                                       // moves pages 40..62, not page 3)
        check_at(3*PG + 8,      phys3*PG + 8,      "view page 3 reads the page the table names");
        check_at(3*PG + PG - 1, phys3*PG + PG - 1, "and to the last byte of that page");
        check_at(4*PG,          4*PG,              "the next page is unaffected");
        check_at(2*PG + 100,    2*PG + 100,        "the previous page is unaffected");
        check_at(9*PG + 4,      9*PG + 4,          "a page every part shares");

        if (highmap) begin
            // Every mapped page above the old boundary, both oracles. Page 64 is the first byte the
            // old window would have dropped without telling anyone; page 127 is the last the widened
            // window can name (bit 21 of the word address is die select, so page 128 would be die 1).
            for (int i = 0; i < 22; i = i + 1) check_hi(40 + i, 64 + i);
            check_hi(62, 127);
            // And the selectivity control: a page the map did not move still reads the pack. Without
            // this, a global offset in the address arithmetic would pass every check above.
            check_at(10*PG + 8, 10*PG + 8, "page 10 unmapped: still reads the pack");
            check_at(30*PG + 8, 30*PG + 8, "page 30 unmapped: still reads the pack");
            check_at(63*PG + 16, 63*PG + 16, "page 63 (the trailer page) stayed identity");
        end

        // Late refusal. Bytes are flowing, so a part change must be reported and NOT obeyed, and no
        // sweep is expected either - the directory is frozen. rearm() is not used here because it
        // waits for rom_ready to fall, and nothing is going to fall any more: that is the point.
        begin
            int k;
            bridge_write32(32'h00F0_0000 + ((want_part == 0) ? 4 : 0), 32'h0000_0000);
            @(negedge clk_bridge); dataslot_allcomplete <= 1'b1;
            repeat (8) @(negedge clk_bridge);
            dataslot_allcomplete <= 1'b0;
            for (k = 0; k < 20000 && !part_late; k = k + 1) @(negedge clk_core);
            checks++;
            if (!part_late) begin
                errors++;
                $display("  FAIL: a part write after the first accepted byte was not reported late");
            end
            repeat (200) @(negedge clk_core);
            // +BADENT ends with a REFUSED install, so the map under test here is identity and the
            // table is flagged bad; the point of the check (a late write changes nothing) still holds.
            expect_status(nomagic ? 0 : 1, 0, want_part,
                          "a late write changes neither the part nor the map");
            check_at(3*PG + 8, phys3*PG + 8, "still the same part's page 3 after a refused switch");
        end

        $display("tb_dir: %0d checks, %0d errors -> %s", checks, errors,
                 (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $stop; else $finish;
    end

    // The load alone is 524,288 bridge writes at (2 + PACE) bridge cycles = ~85 ms of simulated
    // time, so a timeout shorter than that measures the testbench, not the design. tb_rom uses a
    // comparable budget; 300 ms leaves room for the census and four re-arms.
    initial begin
        #300_000_000;
        $display("tb_dir: TIMEOUT");
        $stop;
    end
endmodule
