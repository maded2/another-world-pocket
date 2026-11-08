// Does aw_audio_idx copy the image's index into its local RAM and resolve every resource id correctly?
//
// Two properties, and the first is new: the index is now LOADED at boot rather than walked per lookup, so the
// loader is as much of the contract as the resolver. The oracle for both is build/audio-idx/expect.txt plus
// idx.hex, dumped from the IMAGE by scripts/audio_idx_dump.py - i.e. the file, not this RTL's arithmetic.
//
// The responder is DELAYED (3 cycles), because the field path is a PSRAM round trip through a clock-domain
// handshake and a bench that answers in one cycle would certify a loader that cannot work on hardware.
`timescale 1ns/1ps
module tb_audio_idx;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;

    localparam [23:0] IDXOFF = 24'h1000;

    reg  [7:0] img [0:4095];

    // ---- delayed byte responder ----
    reg         ldr_req;
    reg  [23:0] ldr_addr;
    reg         ldr_valid = 0;
    reg  [7:0]  ldr_data  = 0;
    reg  [2:0]  rcnt = 0;
    reg  [23:0] cap_addr = 0;
    reg         rbusy = 0;
    reg         req_prev = 0;
    // req is a LEVEL that must fall between transactions (4-phase): a responder that re-arms on `req` high
    // rather than on its rising edge captures the same address twice, which is exactly what this bench
    // reported before the edge was added.
    wire        req_rise = ldr_req && !req_prev;
    always @(posedge clk) begin
        ldr_valid <= 1'b0;
        req_prev  <= ldr_req;
        if (rst) begin
            rbusy <= 1'b0; rcnt <= 3'd0;
        end else if (!rbusy) begin
            if (req_rise) begin
                cap_addr <= ldr_addr;
                rcnt     <= 3'd3;
                rbusy    <= 1'b1;
            end
        end else begin
            if (rcnt != 3'd0) begin
                rcnt <= rcnt - 3'd1;
            end else begin
                ldr_data  <= img[cap_addr - IDXOFF];
                ldr_valid <= 1'b1;
                rbusy     <= 1'b0;
            end
        end
    end

    reg         load_start = 0;
    wire        load_busy, load_done;
    reg         start = 0;
    reg  [15:0] res_id = 0;
    wire        busy, found;
    wire [7:0]  r_type;
    wire [31:0] r_blob_off;
    wire [15:0] r_pcm_off, r_pcm_len, r_loop_start, r_loop_len;

    aw_audio_idx dut(.clk(clk), .rst(rst),
                     .load_start(load_start), .load_busy(load_busy), .load_done(load_done),
                     .ldr_addr(ldr_addr), .ldr_req(ldr_req), .ldr_valid(ldr_valid), .ldr_data(ldr_data),
                     .start(start), .res_id(res_id),
                     .busy(busy), .found(found), .r_type(r_type), .r_blob_off(r_blob_off),
                     .r_pcm_off(r_pcm_off), .r_pcm_len(r_pcm_len),
                     .r_loop_start(r_loop_start), .r_loop_len(r_loop_len));

    integer fd, n, i, t, errors = 0, checked = 0;
    integer e_res [0:255], e_type [0:255], e_off [0:255], e_po [0:255], e_pl [0:255];
    integer e_ls [0:255], e_ll [0:255];

    task automatic lookup(input [15:0] id);
        begin
            @(negedge clk); start <= 1; res_id <= id;
            @(negedge clk); start <= 0;
            t = 0;
            while (busy && t < 20000) begin @(negedge clk); t = t + 1; end
            if (t >= 20000) begin $display("tb_audio_idx: TIMEOUT on id %0d", id); $finish; end
            @(negedge clk);
        end
    endtask

    initial begin
        $readmemh({`SCN_PATH, "/idx.hex"}, img);
        fd = $fopen({`SCN_PATH, "/expect.txt"}, "r");
        if (fd == 0) begin $display("tb_audio_idx: no expect.txt"); $finish; end
        n = 0;
        while (!$feof(fd)) begin
            i = $fscanf(fd, "%d %d %d %d %d %d %d\n",
                        e_res[n], e_type[n], e_off[n], e_po[n], e_pl[n], e_ls[n], e_ll[n]);
            if (i == 7) n = n + 1;
        end
        $fclose(fd);

        repeat (4) @(posedge clk);
        rst <= 0;
        repeat (2) @(posedge clk);

        // ---- load ----
        @(negedge clk); load_start <= 1;
        @(negedge clk); load_start <= 0;
        t = 0;
        while (!load_done && t < 200000) begin @(negedge clk); t = t + 1; end
        checked = checked + 1;
        if (!load_done) begin
            errors = errors + 1; $display("  FAIL loader never finished");
        end else begin
            $display("  loader: %0d bytes in %0d clk (count=%0d)", 4 + img[1]*16, t, img[1]);
        end

        // the RAM must hold exactly the image's index bytes - the loader is not allowed to drop or shift one
        checked = checked + 1;
        for (i = 0; i < 2048; i = i + 1) begin
            if (i < 4 + img[1]*16) begin
                if (dut.mem[i] !== img[i]) begin
                    errors = errors + 1;
                    if (errors < 6)
                        $display("  FAIL loader byte %0d: mem=%02h img=%02h", i, dut.mem[i], img[i]);
                end
            end
        end

        // ---- lookups ----
        for (i = 0; i < n; i = i + 1) begin
            lookup(e_res[i][15:0]);
            checked = checked + 1;
            if (!found) begin
                errors = errors + 1;
                $display("  FAIL id %0d not found", e_res[i]);
            end else if (r_type !== e_type[i][7:0] || r_blob_off !== e_off[i] ||
                         r_pcm_off !== e_po[i] || r_pcm_len !== e_pl[i] ||
                         r_loop_start !== e_ls[i] || r_loop_len !== e_ll[i]) begin
                errors = errors + 1;
                $display("  FAIL id %0d: got t=%0d off=%0d po=%0d pl=%0d ls=%0d ll=%0d, want t=%0d off=%0d po=%0d pl=%0d ls=%0d ll=%0d",
                         e_res[i], r_type, r_blob_off, r_pcm_off, r_pcm_len, r_loop_start, r_loop_len,
                         e_type[i], e_off[i], e_po[i], e_pl[i], e_ls[i], e_ll[i]);
            end
        end
        // And an id that is not in the index must report not-found rather than stale fields.
        lookup(16'd9999);
        checked = checked + 1;
        if (found) begin errors = errors + 1; $display("  FAIL absent id 9999 reported found"); end

        $display("tb_audio_idx: %0d lookups, %0d errors -> %s", checked, errors,
                 (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $stop; else $finish;
    end
endmodule
