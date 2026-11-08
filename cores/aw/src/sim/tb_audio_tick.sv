// Does the fractional accumulator actually produce 48 000 ticks per second?
//
// Counting over exactly one second is the only check that matters: a divider by 515 would pass a short
// window and be 0.12 % fast forever, and APF requires exactly 48 kHz.
`timescale 1ns/1ps
module tb_audio_tick;
    reg clk = 0, rst = 1;
    always #20.202 clk = ~clk;              // ~24.75 MHz

    wire tick;
    aw_audio_tick dut(.clk(clk), .rst(rst), .tick(tick));

    integer n = 0, i;
    integer first_interval = 0, last_interval = 0, cur = 0;
    reg seen = 0;

    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;
        // one second = CLK_HZ cycles; count the ticks inside it
        for (i = 0; i < 24_750_000; i = i + 1) begin
            @(posedge clk);
            cur = cur + 1;
            if (tick) begin
                n = n + 1;
                if (!seen) begin first_interval = cur; seen = 1; end
                last_interval = cur;
                cur = 0;
            end
        end
        $display("tb_audio_tick: %0d ticks in 24,750,000 cycles (want 48000), first interval %0d, last %0d",
                 n, first_interval, last_interval);
        if (n != 48000) begin
            $display("tb_audio_tick: FAIL - rate is %0.3f Hz, not 48000", n / 1.0);
            $stop;
        end
        // 515.625 means intervals of 515 and 516 only; anything else is a broken accumulator.
        if (first_interval < 515 || first_interval > 516 || last_interval < 515 || last_interval > 516) begin
            $display("tb_audio_tick: FAIL - interval %0d/%0d is not 515 or 516", first_interval, last_interval);
            $stop;
        end
        $display("tb_audio_tick: PASS - exactly 48000 ticks, intervals of 515/516");
        $finish;
    end
endmodule
