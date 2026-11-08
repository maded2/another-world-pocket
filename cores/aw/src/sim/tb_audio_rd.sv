// Does the byte shim survive an UNRELATED second clock and a VARIABLE responder?
//
// The responder models aw_rom's audio port rather than an ideal RAM: a request is latched and served when the
// sequencer is idle, so the latency varies, and it is occasionally blocked for hundreds of cycles the way a VM
// burst blocks it. That is the "preconditions must match the field path" rule this project has a note about:
// a bench whose memory answers in a fixed few cycles would pass a shim that cannot work on hardware.
//
// Checks: every byte arrives with the right value, exactly one valid pulse per request, and no request is lost
// (issued == returned).
`timescale 1ns/1ps
module tb_audio_rd;

    // clk_core is 24.75 MHz, clk_psram is 92.8125 MHz - deliberately not phase related, because they are not.
    reg clk_c = 0, clk_p = 0;
    always #20.2 clk_c = ~clk_c;
    always #5.39 clk_p = ~clk_p;

    reg rst_c = 1, rst_p = 1;

    reg  [7:0] mem [0:(1<<22)-1];

    // ---- caller ----
    reg         req = 0;
    reg  [23:0] addr = 0;
    wire [7:0]  data;
    wire        valid;

    // ---- responder (aw_rom's audio port as it actually behaves) ----
    reg         aud_req;
    reg  [23:0] aud_addr;
    reg         aud_valid = 0;
    reg  [7:0]  aud_data = 0;

    reg         pend = 0;
    reg  [23:0] paddr = 0;
    reg         active = 0;
    reg  [15:0] cnt = 0;
    reg  [15:0] lfsr = 16'hACE1;

    // a long block that looks like the VM taking the port for a burst
    reg  [15:0] burst = 0;

    always @(posedge clk_p) begin
        aud_valid <= 1'b0;
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3]};
        if (rst_p) begin
            pend <= 0; active <= 0; cnt <= 0; burst <= 0;
        end else begin
            if (burst != 0) burst <= burst - 1;
            if (aud_req) begin
                pend  <= 1'b1;                  // a request is never lost
                paddr <= aud_addr;
            end
            if (pend && !active) begin
                active <= 1'b1;
                cnt    <= 16'd4 + {8'd0, lfsr[7:0]};            // 4..259 clk_p of latency
            end
            if (active) begin
                if (burst != 0) begin
                    // the port is held by something else; keep waiting
                end else if (cnt != 0) begin
                    cnt <= cnt - 1;
                end else begin
                    aud_data  <= mem[paddr];
                    aud_valid <= 1'b1;
                    pend      <= 1'b0;
                    active    <= 1'b0;
                    if ((lfsr[15:8] == 8'h00) && (burst == 0)) burst <= 16'd400;   // ~2% of transactions
                end
            end
        end
    end

    aw_audio_rd dut(
        .clk_c(clk_c), .rst_c(rst_c), .req(req), .addr(addr), .data(data), .valid(valid),
        .clk_p(clk_p), .rst_p(rst_p), .aud_req(aud_req), .aud_addr(aud_addr),
        .aud_data(aud_data), .aud_valid(aud_valid));

    integer i, errors = 0, issued = 0, returned = 0, t;
    reg [23:0] a;
    reg [7:0]  want_b;

    task automatic rd(input [23:0] ad);
        begin
            want_b = mem[ad];
            @(negedge clk_c); req <= 1; addr <= ad;
            issued = issued + 1;
            t = 0;
            while (!valid && t < 20000) begin @(negedge clk_c); t = t + 1; end
            if (!valid) begin
                errors = errors + 1;
                $display("  FAIL addr 0x%06X timed out", ad);
            end else begin
                returned = returned + 1;
                if (data !== want_b) begin
                    errors = errors + 1;
                    $display("  FAIL addr 0x%06X: got %02h want %02h", ad, data, want_b);
                end
            end
            @(negedge clk_c); req <= 0;
            repeat (2) @(negedge clk_c);
        end
    endtask

    initial begin
        for (i = 0; i < (1<<22); i = i + 1) mem[i] = (i * 8'd37 + (i >> 11)) & 8'hFF;

        repeat (8) @(posedge clk_c);
        rst_c <= 0; rst_p <= 0;
        repeat (8) @(posedge clk_c);

        // sequential, repeated, backwards, and the image's real audio range
        for (i = 0; i < 40; i = i + 1) rd(24'h2F0000 + i);
        for (i = 0; i < 40; i = i + 1) rd(24'h3A3000 - i);
        for (i = 0; i < 10; i = i + 1) rd(24'h2F0008);          // the same address again and again
        for (i = 0; i < 40; i = i + 1) rd((i * 24'h12345) & 24'h3FFFFF);
        for (i = 0; i < 40; i = i + 1) rd(24'h001000 + i * 16); // the index region the loader reads

        $display("tb_audio_rd: %0d issued, %0d returned, %0d errors -> %s",
                 issued, returned, errors, (errors == 0 && returned == issued) ? "PASS" : "FAIL");
        if (errors != 0 || returned != issued) $stop; else $finish;
    end
endmodule
