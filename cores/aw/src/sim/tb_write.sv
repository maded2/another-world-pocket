// -----------------------------------------------------------------------------
// Small, fast test of one thing: does a byte written over the bridge end up in the
// memory, and does the read path give it back?
//
// tb_rom does this properly with a real 2 MB pack, which takes a couple of minutes
// before it says anything at all. When the write path is broken that is the wrong
// shape of test: this one loads 256 bytes and answers in seconds, and it prints the
// chip's own first accesses, which is the difference between "the address is wrong"
// and "the write never happened" - a distinction nothing downstream can make, because
// a controller that writes nothing still reads back whatever it wants if its read
// path is independent.
//
// 0x100 is deliberately left unwritten: it must read back as the model's fill value.
// A test that only checks written bytes cannot tell an empty memory from a correct one.
// -----------------------------------------------------------------------------
`timescale 1ns/10ps

module tb_write;

    localparam integer NBYTES = 256;

    reg clk_core = 0, clk_psram = 0, clk_bridge = 0;
    real T_CORE = 1000.0/24.75, T_PSRAM = 1000.0/92.8125, T_BRIDGE = 1000.0/74.25;
    always #(T_CORE/2)   clk_core   = ~clk_core;
    always #(T_PSRAM/2)  clk_psram  = ~clk_psram;
    always #(T_BRIDGE/2) clk_bridge = ~clk_bridge;
    initial begin clk_core = 0; #3.1 clk_psram = 0; #7.7 clk_bridge = 0; end

    reg rst_bridge = 1, rst_psram = 1, rst_core = 1;

    reg  [23:0] mem_addr = 0;
    reg         mem_in_ready = 0;
    wire [7:0]  mem_data;
    wire        mem_data_available, mem_busy;
    reg         bridge_wr = 0;
    reg  [31:0] bridge_addr = 0, bridge_wr_data = 0;
    reg         dataslot_allcomplete = 0;
    wire        rom_ready;
    wire [1:0]  rom_error;
    wire        rom_loading;
    wire [5:0]  cram0_a;
    wire [15:0] cram0_dq;
    wire        cram0_clk, cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n;
    wire        cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n, cram0_wait;

    aw_rom u_rom (
        .clk_core(clk_core), .rst_core(rst_core),
        .mem_addr(mem_addr), .mem_in_ready(mem_in_ready), .mem_data(mem_data),
        .vm_running(~rst_core),
        .mem_data_available(mem_data_available), .mem_busy(mem_busy),
        .clk_psram(clk_psram), .rst_psram(rst_psram),
        .clk_bridge(clk_bridge), .rst_bridge(rst_bridge),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rom_ready(rom_ready), .rom_error(rom_error), .rom_loading(rom_loading),
        .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait),
        .cram0_clk(cram0_clk), .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n), .cram0_oe_n(cram0_oe_n),
        .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n)
    );

    aw_psram_model u_mem (
        .clk(clk_psram), .a(cram0_a), .dq(cram0_dq),   // the chip's CLK pin is held low by
                                                       // the controller; this is time, not it
        .adv_n(cram0_adv_n), .cre(cram0_cre),
        .ce0_n(cram0_ce0_n), .ce1_n(cram0_ce1_n),
        .oe_n(cram0_oe_n), .we_n(cram0_we_n),
        .ub_n(cram0_ub_n), .lb_n(cram0_lb_n), .wait_hi(cram0_wait)
    );

    // what was written, so the comparison is against intent and not against the model
    reg [7:0] want [0:NBYTES-1];

    task wr32(input [31:0] a, input [31:0] d);
    begin
        @(negedge clk_bridge); bridge_wr <= 1; bridge_addr <= a; bridge_wr_data <= d;
        @(negedge clk_bridge); bridge_wr <= 0;
        repeat (6) @(negedge clk_bridge);
    end
    endtask

    // readByte(), as vm.si does it: pulse in_ready, then wait for busy with it low
    task rd1(input [23:0] a, output [7:0] d);
        integer g;
    begin
        @(negedge clk_core); mem_addr <= a; mem_in_ready <= 1;
        @(negedge clk_core); mem_in_ready <= 0;
        g = 0;
        while (mem_busy && g < 5000) begin @(negedge clk_core); g = g + 1; end
        if (mem_busy) begin
            $display("  read @%0h STALLED (busy never fell)", a);
            d = 8'hxx;
        end else begin
            @(negedge clk_core);      // let mem_data settle past the available cycle
            d = mem_data;
        end
    end
    endtask

    // The 64-byte preload, held in_ready: the pattern that a single-byte test does not
    // cover, and the one the VM spends nearly all of its ROM time in.
    task rd_stream(input [23:0] a, input integer n, output reg [7:0] d [0:63]);
        integer got, g;
    begin
        got = 0; g = 0;
        @(negedge clk_core); mem_addr <= a; mem_in_ready <= 1;
        while (got < n && g < 20000) begin
            @(negedge clk_core); g = g + 1;
            if (mem_data_available) begin d[got] = mem_data; got = got + 1; end
        end
        mem_in_ready <= 0;
        if (got < n) $display("  stream @%0h: only %0d of %0d bytes in %0d cycles", a, got, n, g);
    end
    endtask

    reg [7:0] sbuf [0:63];
    integer i, errors = 0, j;
    reg [7:0] got;

    initial begin
        for (i = 0; i < NBYTES; i = i + 1) want[i] = i[7:0] ^ 8'hA5;

        $display("tb_write: releasing reset");
        #200; rst_bridge = 0;
        repeat (20) @(posedge clk_psram); rst_psram = 0;
        repeat (20) @(posedge clk_core);  rst_core = 0;

        $display("tb_write: writing %0d bytes", NBYTES);
        for (i = 0; i < NBYTES/4; i = i + 1)
            wr32(32'h10000000 + i*4,
                 {want[i*4+3], want[i*4+2], want[i*4+1], want[i*4]});

        // A valid trailer at its real address, written sparsely (entries carry their
        // own address, so the design must cope with gaps). Without this the internal
        // check never runs in this test - and the interaction between that check and
        // the first acceptance afterwards is precisely what tb_rom's full-pack run was
        // failing while every path on either side of it passed.
        wr32(32'h101FFFE0, 32'h00000000);
        wr32(32'h101FFFE4, 32'h000024E5);   // 9445
        wr32(32'h101FFFE8, 32'h000010E1);   // 4321
        wr32(32'h101FFFEC, 32'h00002CE5);   // 11493

        @(negedge clk_bridge); dataslot_allcomplete <= 1;
        @(negedge clk_bridge); dataslot_allcomplete <= 0;

        // wait for the design to notice: quiet (10 ms) or retry (84 ms), then a check
        begin
            integer g; g = 0;
            while (!rom_ready && g < 3000000) begin @(posedge clk_core); g = g + 1; end
            $display("tb_write: rom_ready=%b rom_error=%0d after %0d design cycles",
                     rom_ready, rom_error, g);
        end

        $display("tb_write: reading back (expect the fill value 5a at 0x100..)");
        for (i = 0; i < NBYTES + 16; i = i + 1) begin
            rd1(i[23:0], got);
            if (got !== ((i < NBYTES) ? want[i] : 8'h5a)) begin
                errors = errors + 1;
                if (errors < 12)
                    $display("  MISMATCH @%03h got %02h want %02h",
                             i, got, ((i < NBYTES) ? want[i] : 8'h5a));
            end
        end

        // ---- held-stream read, the preload pattern
        $display("tb_write: held 64-byte stream at 0, then at 40h, then again at 0");
        rd_stream(24'h0, 64, sbuf);
        for (j = 0; j < 64; j = j + 1)
            if (sbuf[j] !== want[j]) begin
                errors = errors + 1;
                if (errors < 8) $display("  STREAM MISMATCH @%02h got %02h want %02h", j, sbuf[j], want[j]);
            end
        rd_stream(24'h40, 64, sbuf);
        for (j = 0; j < 64; j = j + 1)
            if (sbuf[j] !== want[64 + j]) begin
                errors = errors + 1;
                if (errors < 16) $display("  STREAM2 MISMATCH @%02h got %02h want %02h",
                                          64+j, sbuf[j], want[64+j]);
            end
        rd_stream(24'h0, 16, sbuf);
        for (j = 0; j < 16; j = j + 1)
            if (sbuf[j] !== want[j]) begin
                errors = errors + 1;
                if (errors < 24) $display("  STREAM3 MISMATCH @%02h got %02h want %02h", j, sbuf[j], want[j]);
            end

        // Odd starts. The VM begins a segment fill at whatever byte the bytecode says,
        // so the first byte usually comes from the upper half of a word and everything
        // after it is offset by half a word. Every test above started on even 4 bytes,
        // which is how an entire class of half-word mistakes stayed hidden.
        $display("tb_write: odd-start streams");
        rd_stream(24'h1, 64, sbuf);
        for (j = 0; j < 64; j = j + 1)
            if (sbuf[j] !== want[1 + j]) begin
                errors = errors + 1;
                if (errors < 32) $display("  ODD1 MISMATCH @%02h got %02h want %02h",
                                          1+j, sbuf[j], want[1+j]);
            end
        rd_stream(24'h3, 33, sbuf);
        for (j = 0; j < 33; j = j + 1)
            if (sbuf[j] !== want[3 + j]) begin
                errors = errors + 1;
                if (errors < 40) $display("  ODD3 MISMATCH @%02h got %02h want %02h",
                                          3+j, sbuf[j], want[3+j]);
            end
        // and a stream that walks off the end of what was written: the tail must read
        // back as the model's fill, not as anything this design made up
        rd_stream(24'hf8, 16, sbuf);
        for (j = 0; j < 16; j = j + 1)
            if (sbuf[j] !== (j < 8 ? want[248 + j] : 8'h5a)) begin
                errors = errors + 1;
                if (errors < 48) $display("  EDGE MISMATCH @%02h got %02h want %02h",
                                          248+j, sbuf[j], j < 8 ? want[248+j] : 8'h5a);
            end

        // ---- cram0_wait held high must not stop a single access --------------------
        // On the fitted part this pin idles high and is not a handshake - its known-good
        // neighbours never read it - yet two hardware runs painted amber because the
        // controller treated it as one (2026-10-10 counting idle time, 2026-10-11 counting
        // access cycles). The requirement that must stay tested: with the pin held high for
        // the whole section, a write must land and a read must come back. A controller that
        // stalls on WAIT fails here as a hang (rd_stream times out) or a lost write
        // (mismatch), not as a silent pass.
        $display("tb_write: holding cram0_wait high; writes and reads must still complete");
        u_mem.force_wait = 1'b1;
        wr32(32'h10000200, {8'h7d, 8'h3c, 8'h9b, 8'h5a});   // a word outside the main pattern
        rd_stream(24'h200, 4, sbuf);
        if (sbuf[0] !== 8'h5a || sbuf[1] !== 8'h9b || sbuf[2] !== 8'h3c || sbuf[3] !== 8'h7d) begin
            errors = errors + 1;
            $display("  with WAIT held: read back %02h%02h%02h%02h want 5a9b3c7d - access did not complete",
                     sbuf[3], sbuf[2], sbuf[1], sbuf[0]);
        end else begin
            $display("  write landed and read back with WAIT held high, as it must");
        end
        u_mem.force_wait = 1'b0;
        repeat (30) @(posedge clk_core);

        $display("tb_write: rom_error=%0d rom_ready=%b, %0d errors -> %s",
                 rom_error, rom_ready, errors, (errors == 0) ? "PASS" : "FAIL");
        $fflush;
        $finish;
    end

endmodule
