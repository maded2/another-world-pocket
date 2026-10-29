// apf_altsyncram_model.v - behavioural stand-in for the altsyncram inside mf_datatable,
// for simulation only. Verilator cannot elaborate the megafunction; Quartus uses the
// real one.
//
// It implements exactly the configuration mf_datatable instantiates (see that file):
// bidirectional dual port, 256 x 32, registered outputs on BOTH ports
// (outdata_reg_a=CLOCK0, outdata_reg_b=CLOCK1), and port B's address AND data also
// registered (address_reg_b / indata_reg_b / wrcontrol_wraddress_reg_b = CLOCK1).
// In core_bridge_cmd both ports run on the same clock (clk_74a), so the model is a
// plain two-clock dual-port RAM with those registration stages; port B writes land
// one cycle after the request, exactly as the fitted logic does.

`timescale 1ns/1ps
`default_nettype none

module altsyncram #(
    // Every parameter mf_datatable.v defparams, accepted and ignored - the same
    // reason the PLL model carries its full parameter list.
    parameter address_reg_b                 = "CLOCK1",
    parameter clock_enable_input_a          = "BYPASS",
    parameter clock_enable_input_b          = "BYPASS",
    parameter clock_enable_output_a         = "BYPASS",
    parameter clock_enable_output_b         = "BYPASS",
    parameter indata_reg_b                  = "CLOCK1",
    parameter init_file                     = "./apf/build_id.mif",
    parameter intended_device_family        = "Cyclone V",
    parameter lpm_type                      = "altsyncram",
    parameter numwords_a                    = 256,
    parameter numwords_b                    = 256,
    parameter operation_mode                = "BIDIR_DUAL_PORT",
    parameter outdata_aclr_a                = "NONE",
    parameter outdata_aclr_b                = "NONE",
    parameter outdata_reg_a                 = "CLOCK0",
    parameter outdata_reg_b                 = "CLOCK1",
    parameter power_up_uninitialized        = "FALSE",
    parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    parameter read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    parameter widthad_a                     = 8,
    parameter widthad_b                     = 8,
    parameter width_a                       = 32,
    parameter width_b                       = 32,
    parameter width_byteena_a               = 1,
    parameter width_byteena_b               = 1,
    parameter wrcontrol_wraddress_reg_b     = "CLOCK1"
) (
    input  wire [7:0]  address_a,
    input  wire [7:0]  address_b,
    input  wire        clock0,
    input  wire        clock1,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    input  wire        wren_a,
    input  wire        wren_b,
    output reg  [31:0] q_a,
    output reg  [31:0] q_b,
    // connected-but-constant in mf_datatable; declared so the instance elaborates
    input  wire        aclr0,
    input  wire        aclr1,
    input  wire        addressstall_a,
    input  wire        addressstall_b,
    input  wire        byteena_a,
    input  wire        byteena_b,
    input  wire        clocken0,
    input  wire        clocken1,
    input  wire        clocken2,
    input  wire        clocken3,
    output wire [2:0]  eccstatus,
    input  wire        rden_a,
    input  wire        rden_b
);

    localparam DEPTH = 256;

    reg [31:0] mem [0:DEPTH-1];

    // port B registration stages (address_reg_b / indata_reg_b = CLOCK1)
    reg [7:0]  addr_b_r;
    reg [31:0] data_b_r;

    initial begin
        integer i;
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'h0;
    end

    // port A: registered readout (outdata_reg_a=CLOCK0); rden is tied high upstream.
    // read_during_write_mode = NEW_DATA_NO_NBE_READ: a simultaneous read shows the new word
    always @(posedge clock0) begin
        if (aclr0)               q_a <= 32'h0;
        else if (wren_a)         q_a <= data_a;
        else                     q_a <= mem[address_a];
        if (wren_a)              mem[address_a] <= data_a;
    end

    // port B: address and data registered on CLOCK1, write uses the REGISTERED pair
    // (wrcontrol_wraddress_reg_b=CLOCK1), readout registered one cycle after that
    always @(posedge clock1) begin
        addr_b_r <= address_b;
        data_b_r <= data_b;
        if (aclr1)          q_b <= 32'h0;
        else if (wren_b)    q_b <= data_b_r;   // NEW_DATA_NO_NBE_READ
        else                q_b <= mem[addr_b_r];
        if (wren_b)         mem[addr_b_r] <= data_b_r;
    end

    assign eccstatus = 3'b0;

endmodule

`default_nettype wire
