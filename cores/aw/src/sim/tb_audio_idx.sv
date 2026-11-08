// Does aw_audio_idx resolve every resource id in the image to the right metadata?
//
// The oracle is build/audio-idx/expect.txt, dumped from the IMAGE by scripts/audio_idx_dump.py - i.e. the
// file, not this RTL's own arithmetic. A lookup that returned plausible-but-wrong offsets would pass a
// self-consistent check and fail this one.
`timescale 1ns/1ps
module tb_audio_idx;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;

    reg  [7:0] idx [0:4095];
    reg  [7:0] rd_data_r;
    wire [23:0] rd_addr;
    always @(posedge clk) rd_data_r <= idx[rd_addr - 24'h1000];

    reg         start = 0;
    reg  [15:0] res_id = 0;
    wire        busy, found;
    wire [7:0]  r_type;
    wire [31:0] r_blob_off;
    wire [15:0] r_pcm_off, r_pcm_len, r_loop_start, r_loop_len;

    aw_audio_idx dut(.clk(clk), .rst(rst), .start(start), .res_id(res_id),
                     .busy(busy), .found(found), .r_type(r_type), .r_blob_off(r_blob_off),
                     .r_pcm_off(r_pcm_off), .r_pcm_len(r_pcm_len),
                     .r_loop_start(r_loop_start), .r_loop_len(r_loop_len),
                     .rd_addr(rd_addr), .rd_data(rd_data_r));

    integer fd, n, i, t, errors = 0, checked = 0;
    integer e_res [0:255], e_type [0:255], e_off [0:255], e_po [0:255], e_pl [0:255];
    integer e_ls [0:255], e_ll [0:255];
    reg [7:0] cnt;

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
        $readmemh({`SCN_PATH, "/idx.hex"}, idx);
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

        for (i = 0; i < n; i = i + 1) begin
            lookup(e_res[i][15:0]);
            checked = checked + 1;
            if (i == 0)
                $display("  probe: st=%0d count=%0d k=%0d rec0=%02h rec1=%02h found=%b want=%0d idx_cnt=%02h idx_rec0=%02h%02h",
                         dut.st, dut.count, dut.k, dut.rec[0], dut.rec[1], found, e_res[i],
                         idx[1], idx[1], idx[0]);
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
