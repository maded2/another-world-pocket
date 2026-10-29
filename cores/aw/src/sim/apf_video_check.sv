// apf_video_check - self-checking monitor for the openFPGA video bus hard rules.
//
// The Pocket's scaler is far more particular about the sync protocol than any frame
// capture can see: a stream that renders fine in simulation can still violate the
// APF contract (Analogue's own docs + agg23/analogue-pocket-utils wiki, "Video"):
//
//   R1  vs and hs are exactly one cycle wide.
//   R2  hs never coincides with vs; the first hs after a vs comes >= 3 cycles later.
//       (vs mid-hsync is worse than a violation: on current firmware it hard-crashes
//        the scaler until the Pocket is fully restarted.)
//   R3  rgb is all zero while de is low. This core uses neither frame feature bits
//       nor endline words, so there is no exception; the values around the first/last
//       DE pixel configure the scaler and garbage there has "unexpected results".
//   R4  skip never asserts (this core pushes one pixel per clock and ties it to 0).
//   R5  each line carries either zero de cycles or exactly H_ACTIVE; a frame carries
//       exactly H_ACTIVE*V_ACTIVE of them. Extra de pixels are the classic "pixels
//       overrun the screen and the columns get messed up".
//
// Pure observation: one instance per video stream, no outputs the design can see.
// Violations print as they happen (rate-limited) and the running total is on `errors`,
// which the testbench folds into its verdict - a monitor that only prints can be read
// as green by a wrapper that checks exit status alone.

`timescale 1ns/1ps
`default_nettype none

module apf_video_check #(
    parameter H_ACTIVE    = 320,
    parameter V_ACTIVE    = 200,
    // total lines per frame (active + blanking); the frame total is only valid on
    // the last line - checking it at every hs would fail on all but that one
    parameter V_TOTAL     = 500,
    parameter MAX_REPORTS = 8
) (
    input  wire        clk,      // the pixel clock; everything is sampled on its posedge
    input  wire [23:0] rgb,
    input  wire        de,
    input  wire        skip,
    input  wire        vs,
    input  wire        hs,
    output reg  [31:0] errors,
    // frames whose line count is not V_TOTAL-1. A mid-frame raster swap (the mux
    // switch at boot) produces exactly one; everything else must be zero.
    output reg  [7:0]  phase_jumps
);

    localparam integer DE_PER_FRAME = H_ACTIVE * V_ACTIVE;

    // ---- R1: pulse widths ---------------------------------------------------------
    reg [7:0] vs_run, hs_run;

    // ---- R2: vs -> first-hs spacing ------------------------------------------------
    // cyc_since_vs reads 0 on the cycle after a vs and counts up each cycle until the
    // first hs of the frame; an hs seen while it reads N is N+1 cycles after the vs.
    reg [9:0]  cyc_since_vs;
    reg        in_frame;      // armed after the first vs (boot frame may be partial)
    reg        hs_after_vs;   // the first hs of this frame has come

    // ---- R5: de accounting ----------------------------------------------------------
    reg [15:0] line_de;       // de cycles on the line ending at the next hs
    reg [23:0] frame_de;      // de cycles since the last vs
    reg [9:0]  line_no;       // lines since the last vs (0-based)

    integer reports = 0;

    // string input: this toolchain cannot lower a $sformatf result to a vector input
    task fail(input string what);
        begin
            errors  = errors + 1;
            if (reports < MAX_REPORTS) begin
                $display("apf_video_check: FAIL %0t %s", $time, what);
                reports = reports + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        // R1 - a second consecutive cycle of the same pulse is already a violation
        if (vs && vs_run != 8'd0) fail("R1: vs wider than one cycle");
        if (hs && hs_run != 8'd0) fail("R1: hs wider than one cycle");
        vs_run <= vs ? vs_run + 8'd1 : 8'd0;
        hs_run <= hs ? hs_run + 8'd1 : 8'd0;

        // R3 - the value with de low is what the scaler latches around active areas
        if (!de && rgb != 24'h0)
            fail($sformatf("R3: rgb=%06h while de low", rgb));

        // R4
        if (skip) fail("R4: skip asserted (this core never uses it)");

        // R5 - a line ends when the next hs comes; the per-line count is checked there.
        // The frame total is evaluated at the NEXT vs, where the whole frame's shape
        // (line count) is known: a raster swap mid-frame leaves an abnormal line count
        // and that frame is classified as a phase jump, not an error.
        if (hs && !vs) begin
            if (in_frame) begin
                if (line_de != 0 && line_de != H_ACTIVE[15:0])
                    fail($sformatf("R5: line %0d carried %0d de cycles (want 0 or %0d)",
                                   line_no, line_de, H_ACTIVE));
            end
            line_de <= 0;
        end else if (de) begin
            line_de  <= line_de + 16'd1;
            frame_de <= frame_de + 24'd1;
        end

        // R2 - from the vs edge, the first hs must be >= 3 cycles away
        if (vs) begin
            if (hs) fail("R2: hs coincides with vs");
            if (in_frame) begin
                // classify the frame that just ended; line_no has counted every hs of
                // it, so a normal frame reads exactly V_TOTAL here
                if (line_no == V_TOTAL[9:0]) begin
                    if (frame_de != DE_PER_FRAME[23:0])
                        fail($sformatf("R5: frame carried %0d de cycles (want %0d)",
                                       frame_de, DE_PER_FRAME));
                end else begin
                    phase_jumps <= phase_jumps + 8'd1;
                    $display("apf_video_check: note %0t phase-jump frame (%0d lines, %0d de cycles)",
                             $time, line_no, frame_de);
                end
            end
            in_frame      <= 1'b1;
            cyc_since_vs  <= 10'd0;
            hs_after_vs   <= 1'b0;
            frame_de      <= 0;
            line_no       <= 10'd0;
        end else if (in_frame && hs) begin
            line_no <= line_no + 10'd1;
            // safety net: a stream with no vs at all would wrap the counter; the
            // transition frame tops out at ~998 lines, so 1022 is unambiguously broken
            if (line_no == 10'd1022) begin
                fail("R5: no vs for 1023 lines - stream broken");
                in_frame <= 1'b0;
                line_no  <= 10'd0;
                frame_de <= 24'd0;
            end
        end else if (in_frame && !hs_after_vs) begin
            if (hs) begin
                // this hs is cyc_since_vs+1 cycles after the vs
                if (cyc_since_vs + 10'd1 < 10'd3)
                    fail($sformatf("R2: first hs %0d cycles after vs (want >= 3)",
                                   cyc_since_vs + 10'd1));
                hs_after_vs <= 1'b1;
            end
            cyc_since_vs <= cyc_since_vs + 10'd1;
        end
    end

endmodule

`default_nettype wire
