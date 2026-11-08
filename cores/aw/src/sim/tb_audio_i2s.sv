// Decode the I2S pins back into samples and check them against what was fed in.
//
// A bench that only counted MCLK/LRCK edges would have passed the template's silence shifter, which is exactly
// what this replaces. So this one behaves like a receiver: it waits for the LRCK transition into the LEFT
// channel, takes the 16 bits that follow it, and checks the stream against the ramp that was pushed into the
// FIFO. A dropped, duplicated, shifted or sign-mangled sample all show up.
//
// The two 48 kHz timebases (the mixer's clk_core tick and the MCLK-derived frame clock) are independent, so the
// FIFO will occasionally report an underrun. That is expected and is accounted for: a repeated sample is only
// legal when the underrun counter moved. Anything else - a step backwards, a step bigger than one, or a repeat
// with no underrun behind it - is a failure.
`timescale 1ns/1ps
module tb_audio_i2s;

    reg clk_74a = 0, clk_core = 0;
    always #6.735 clk_74a = ~clk_74a;     // 74.25 MHz
    always #20.2  clk_core = ~clk_core;   // 24.75 MHz

    reg        rst_core = 1;
    reg signed [15:0] sample = 0;
    reg        sample_valid = 0;

    wire audio_mclk, audio_sclk, audio_lrck, audio_dac;
    wire [15:0] underruns, overruns;

    aw_audio_i2s dut(
        .clk_74a(clk_74a), .clk_core(clk_core), .rst_core(rst_core),
        .sample(sample), .sample_valid(sample_valid),
        .audio_mclk(audio_mclk), .audio_sclk(audio_sclk), .audio_lrck(audio_lrck), .audio_dac(audio_dac),
        .underruns(underruns), .overruns(overruns));

    // ---- 48 kHz tick from clk_core, the same fractional accumulator aw_audio_tick uses ----
    reg [24:0] acc = 0;
    reg tick_c = 0;
    always @(posedge clk_core) begin
        if (acc + 48000 >= 24750000) begin
            acc    <= acc + 48000 - 24750000;
            tick_c <= 1'b1;
        end else begin
            acc    <= acc + 48000;
            tick_c <= 1'b0;
        end
    end

    // ---- receiver: LRCK falling edge = start of the left channel, next 16 bits are the sample ----
    reg sclk_d_lrck = 1'b0;
    reg [15:0] sh = 0;
    reg [4:0]  bc = 0;
    reg        active = 0;
    integer    frames = 0;
    integer    val [0:4095];
    integer    snap_under [0:4095];       // underruns at the time each sample was decoded
    integer    errors = 0;
    integer    mclk_edges = 0, lrck_rises = 0, sclk_rises = 0;
    integer    wraps = 0, pops = 0, writes = 0;

    always @(posedge audio_sclk) begin
        sclk_rises = sclk_rises + 1;
        if (audio_lrck == 1'b0 && sclk_d_lrck == 1'b1) begin
            // start of the left channel
            bc     <= 5'd0;
            sh     <= 16'd0;
            active <= 1'b1;
        end else if (active) begin
            if (bc == 5'd15) begin
                val[frames]        = $signed({sh[14:0], audio_dac});
                snap_under[frames] = underruns;
                frames             = frames + 1;
                active             <= 1'b0;
            end
            sh <= {sh[14:0], audio_dac};
            bc <= bc + 5'd1;
        end
        sclk_d_lrck <= audio_lrck;
    end

    always @(posedge audio_mclk) mclk_edges = mclk_edges + 1;
    always @(posedge audio_lrck) lrck_rises = lrck_rises + 1;
    always @(posedge audio_mclk) if (dut.c == 8'd255) wraps = wraps + 1;
    always @(posedge audio_mclk) if (dut.fifo_rd) pops = pops + 1;
    always @(posedge clk_core) if (sample_valid) writes = writes + 1;

    integer i, sent = 0, under_at_last_write = 0;
    initial begin
        repeat (20) @(posedge clk_core);
        rst_core <= 0;
        repeat (10) @(posedge clk_core);

        for (i = 0; i < 400; i = i + 1) begin
            @(posedge clk_core);
            while (!tick_c) @(posedge clk_core);
            @(negedge clk_core);
            sample       <= i[15:0];
            sample_valid <= 1'b1;
            @(negedge clk_core);
            sample_valid <= 1'b0;
            sent = sent + 1;
            under_at_last_write = underruns;
        end
        repeat (20000) @(posedge clk_core);   // drain

        // ---- MCLK / SCLK / LRCK rates over a fixed window ----
        // 100000 clk_74a cycles = 1.3468 ms: 12.288 MHz gives 16549 MCLK periods, SCLK 4137 rises,
        // LRCK 64 rising edges (474 per full second).
        mclk_edges = 0; lrck_rises = 0; sclk_rises = 0;
        repeat (100000) @(posedge clk_74a);
        if (mclk_edges < 16500 || mclk_edges > 16600) begin
            errors = errors + 1;
            $display("  FAIL MCLK: %0d periods in 1.3468 ms (want ~16549 = 12.288 MHz)", mclk_edges);
        end
        if (sclk_rises < 4120 || sclk_rises > 4160) begin
            errors = errors + 1;
            $display("  FAIL SCLK: %0d rises (want ~4137 = 3.072 MHz)", sclk_rises);
        end
        if (lrck_rises < 63 || lrck_rises > 66) begin
            errors = errors + 1;
            $display("  FAIL LRCK: %0d rises (want ~64 = 48 kHz)", lrck_rises);
        end

        // ---- sample stream ----
        begin : check_stream
            integer k, base, steps_bad, repeats, last, skipped, first_val, last_val;
            base = -1;
            // find where the ramp starts: the first decoded 0
            for (k = 0; k < frames && base < 0; k = k + 1)
                if (val[k] == 0) base = k;
            steps_bad = 0; repeats = 0; last = 0; first_val = 0; last_val = 0;
            if (base < 0) begin
                errors = errors + 1;
                $display("  FAIL no ramp start in %0d decoded frames", frames);
            end else begin
                last = 0;
                for (k = base + 1; k < frames; k = k + 1) begin
                    if (val[k] == last) begin
                        // legitimate only if the FIFO was empty at this frame. A repeat of 0 right at the
                        // start is the frame before the first sample arrived (tx is 0 until then).
                        if (last != 0 && snap_under[k] == (k > 0 ? snap_under[k-1] : 0))
                            repeats = repeats + 1;
                    end else if (val[k] == last + 1) begin
                        last = val[k];
                    end else begin
                        steps_bad = steps_bad + 1;
                        if (steps_bad < 6)
                            $display("  FAIL frame %0d: %0d after %0d (want +1)", k, val[k], last);
                        last = val[k];
                    end
                end
                last_val = val[frames - 1];
                skipped = base;
                $display("  stream: %0d frames, ramp from frame %0d, last value %0d (fed %0d), %0d illegal steps, %0d unexplained repeats, underruns while feeding %0d, total %0d, overruns %0d",
                         frames, skipped, last_val, sent - 1, steps_bad, repeats, under_at_last_write, underruns, overruns);
                if (steps_bad != 0) errors = errors + 1;
                if (repeats != 0) errors = errors + 1;
                if (last_val < sent - 8) begin
                    errors = errors + 1;
                    $display("  FAIL stream stopped at %0d of %0d samples", last_val, sent - 1);
                end
            end
        end
        // Underruns after the source stops are expected (the frame clock keeps running); what matters is
        // that the FIFO never ran dry while samples were still being produced.
        if (under_at_last_write > 40) begin
            errors = errors + 1;
            $display("  FAIL %0d underruns while samples were still being fed (want only the initial fill)",
                     under_at_last_write);
        end
        if (overruns != 0) begin
            errors = errors + 1;
            $display("  FAIL %0d overruns (want 0)", overruns);
        end

        $display("  frames(wraps)=%0d pops=%0d writes=%0d", wraps, pops, writes);
        $display("tb_audio_i2s: %0d errors -> %s", errors, (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $stop; else $finish;
    end
endmodule
