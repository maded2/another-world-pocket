//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// cram0 is the program ROM: the host bridge writes the pack into it and the VM
// reads its program back out; the pins are driven by aw_rom below.


assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

assign dram_a = 'h0;
assign dram_ba = 'h0;
assign dram_dq = {16{1'bZ}};
assign dram_dqm = 'h0;
assign dram_clk = 'h0;
assign dram_cke = 'h0;
assign dram_ras_n = 'h1;
assign dram_cas_n = 'h1;
assign dram_we_n = 'h1;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// add your own devices here
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h10xxxxxx: begin
        // example
        // bridge_rd_data <= example_device_data;
        bridge_rd_data <= 0;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    // driven from the clocking block below, where the PLL signal they follow is
    // declared. Note they say "the clocks are up", not "the game is running": the
    // host waits for these before it sends the pack, and the core cannot have a
    // pack until the host has sent one.
    wire            status_boot_done;
    wire            status_setup_done;   // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    reg             target_dataslot_read;       
    reg             target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id;
    reg     [31:0]  target_dataslot_slotoffset;
    reg     [31:0]  target_dataslot_bridgeaddr;
    reg     [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Clocking and reset.
//
// clk_74a is the only clock a core is given. From it: 24.75 MHz for the design and
// the pixels, its quadrature twin for the scaler, 49.5 MHz for the cellular PSRAM.
// See aw_pll.v for the ratios and for why this clock and not upstream's 25 MHz.
//
// Reset is staged on purpose. The bridge and the PSRAM come out first - the pack
// has to be loadable while the game is held still - and the design itself only
// leaves reset once rom_ready says a pack is there and its trailer made sense.
// Starting the interpreter on an empty PSRAM would not only show garbage: it would
// run the VM off whatever the chip happened to contain, with the read path it uses
// for everything else untested.
//
// rom_ready / rom_error come from aw_rom in the design clock and are only read
// here, in that same clock.

wire clk_core, clk_core90, clk_psram, pll_locked;
wire rom_ready;
wire [1:0] rom_error;

aw_pll u_pll (
    .reset_n    ( 1'b1     ),   // no dynamic reconfiguration in this core
    .refclk     ( clk_74a  ),
    .clk_core   ( clk_core ),
    .clk_core90 ( clk_core90 ),
    .clk_psram  ( clk_psram ),
    .locked     ( pll_locked )
);

// the bridge is told "clocks up" through a synchroniser, as the template did; that
// is what gates the host sending us the pack
wire pll_locked_s;
synch_3 s_pll_locked (pll_locked, pll_locked_s, clk_74a);
assign status_boot_done  = pll_locked_s;
assign status_setup_done = pll_locked_s;

// bridge-domain reset: the host's, or the PLL not being up yet
wire rst_bridge = ~reset_n | ~pll_locked;

// synchronous, stretched releases into each design clock, so nothing comes out of
// reset on the same edge the PLL lock pin happens to tick
reg [3:0] cnt_core, cnt_psram;
reg       rst_core, rst_psram;

always @(posedge clk_core) begin
    cnt_core <= rst_bridge ? 4'd0 : ((cnt_core == 4'd15) ? cnt_core : cnt_core + 4'd1);
    rst_core <= rst_bridge || (cnt_core != 4'd15);
end

always @(posedge clk_psram) begin
    cnt_psram <= rst_bridge ? 4'd0 : ((cnt_psram == 4'd15) ? cnt_psram : cnt_psram + 4'd1);
    rst_psram <= rst_bridge || (cnt_psram != 4'd15);
end

// the game: clocks up, host happy, and a pack it can read
//
// M_main.reset is ACTIVE HIGH. The generated code says `q <= (reset) ? 0 : d`, and
// clean_reset() stretches this into the rasterizer and the blitter. Getting this backwards
// cost the whole intro: with an active-low-looking signal here, the two drawing engines sat
// in reset from the moment rom_ready went up while the VM kept running - upstream ties the
// VM's own reset to constant 0 (vm_reset(0)), because upstream's ROM is SPI flash and is
// readable from the first clock after configuration. A VM that runs with the blitter frozen
// stops asking for bytes at the first `while (rasterizer_busy | blitter_busy) { }` (vm.si:267)
// and the screen is black with a byte-accurate ROM, which is not where anyone looks first.
//
// The VM still cannot be reset here even though it is nominally in reset: its reset pin is
// wired to 0 inside the generated netlist. It is held off instead by aw_rom's vm_running
// gate, which declines its requests until the pack is loaded - without that, the ROM streams
// to a VM that has nothing to do with the data and the pack load reports ERR_OVERFLOW.
wire design_run   = ~rst_core && rom_ready;
wire design_reset = ~design_run;

////////////////////////////////////////////////////////////////////////////////////////
//
// The game.
//
// u_soc is the Silice design - VM, framebuffers, rasterizer, blitter and display -
// translated from src/si/aw_pocket.si by scripts/pocket_translate.sh into
// aw_pocket_build.v. u_rom is its program memory: the pack the host bridge drops
// into cellular PSRAM, offered to the VM with the same byte-stream handshake
// upstream's Quad-SPI reader used, so nothing in the VM knows the difference.
//
// Signalling to the scaler is the template's own convention: pixel clock out on
// video_rgb_clock with its 90 degree twin, hs and vs one-clock pulses in the back
// porch, de high over the active pixels, all of them registered. 825 x 500 at
// 24.75 MHz is exactly 60 Hz with 320 x 200 active - see the display section of
// src/si/aw_pocket.si for why those numbers rather than upstream's VGA pad.
//
// video_skip stays 0: it asks the scaler to drop every other pixel, which is for
// cores that pixel-double inside the FPGA. This one pushes one pixel per clock.
//

assign video_rgb_clock    = clk_core;
assign video_rgb_clock_90 = clk_core90;
assign video_skip         = 1'b0;

// ---- controls ----------------------------------------------------------------
// Upstream's jstick packing, which is what vm.si reads bit by bit:
//   [0] right  [1] left  [2] up  [3] down  [4] fire  [5] unused
// The Pocket hands the pad over asynchronously to the design clock, so it goes
// through the usual 3FF array before being repacked. Both face buttons are fire:
// Another World has one action verb. The analog stick is ignored on purpose, this
// is a d-pad game and half-pressed diagonals would only make the hero wander.

// The mapping lives in core/aw_keys.v with the bit numbers from Analogue's own bus-communication
// docs, and it has a testbench of its own (src/sim/tb_keys.sv via scripts/sim_keys.sh). Both the
// bit numbers here and the packing below were wrong, and nothing in the tree could see it:
// tb_soc drives the SoC's jstick port directly, so the one untested link in the input chain was
// precisely the link that decides whether a button does anything. See core/aw_keys.v for the
// old values and what they actually meant.
// Driven by aw_keys, consumed by the SoC's in_jstick below. vm.si order:
// [0] right [1] left [2] up [3] down [4] fire [5] unused.
wire [5:0] jstick;

aw_keys u_keys (
    .clk        (clk_core),
    .cont1_key  (cont1_key),
    .jstick     (jstick)
);

// ---- the screen to show until a pack is loaded -------------------------------
// The scaler needs something to lock to from the first moment, so this runs the
// same 825 x 500 timing as the game and is simply swapped out when rom_ready goes
// up. What it shows is deliberately blunt: there are three distinct reasons a core
// can sit here and they should not all look the same.

localparam VID_H_TOTAL   = 825,
           VID_V_TOTAL   = 500,
           VID_H_ACTIVE  = 320,
           VID_V_ACTIVE  = 200,
           VID_H_BPORCH  = 218,
           VID_V_BPORCH  = 150;

// aw_rom's rom_error codes (its localparams, repeated here rather than exported)
localparam ERR_TRAILER  = 2'd1,   // the offsets are there but are not a pack
           ERR_OVERFLOW = 2'd2,   // the bridge wrote faster than the chip took it
           ERR_WAIT    = 2'd3;    // the chip has not accepted anything: see aw_psram

reg  [9:0]  idle_x, idle_y;
reg  [24:0] idle_blink;
reg  [23:0] idle_rgb;
reg         idle_de, idle_hs, idle_vs;

wire idle_active = (idle_x >= VID_H_BPORCH) && (idle_x <  VID_H_BPORCH + VID_H_ACTIVE)
                && (idle_y >= VID_V_BPORCH) && (idle_y <  VID_V_BPORCH + VID_V_ACTIVE);

// a slow pulse in the middle of the screen means waiting; anything else is an error
wire blinking = idle_blink[24];
wire in_block = (idle_x >= (VID_H_BPORCH + VID_H_ACTIVE/2 - 20))
             && (idle_x <  (VID_H_BPORCH + VID_H_ACTIVE/2 + 20))
             && (idle_y >= (VID_V_BPORCH + VID_V_ACTIVE/2 - 20))
             && (idle_y <  (VID_V_BPORCH + VID_V_ACTIVE/2 + 20));

always @(posedge clk_core) begin

    idle_de  <= 1'b0;
    idle_hs  <= 1'b0;
    idle_vs  <= 1'b0;
    idle_rgb <= 24'h0;

    idle_blink <= idle_blink + 25'd1;

    if (idle_active) begin
        idle_de <= 1'b1;
        case (rom_error)
            ERR_TRAILER:  idle_rgb <= 24'hc01010;   // red:    not a pack
            ERR_OVERFLOW: idle_rgb <= 24'hc010c0;   // purple: bridge outran the chip
            ERR_WAIT:     idle_rgb <= 24'hc08010;   // amber:  WAIT held, nothing moves
            default:
                if (blinking && in_block) idle_rgb <= 24'hffffff;
        endcase
    end

    idle_x <= idle_x + 10'd1;
    if (idle_x == VID_H_TOTAL - 1) begin
        idle_x <= 10'd0;
        idle_y <= idle_y + 10'd1;
        if (idle_y == VID_V_TOTAL - 1) idle_y <= 10'd0;
    end
    if (idle_x == 3) idle_hs <= 1'b1;
    if (idle_x == 10'd0 && idle_y == 10'd0) idle_vs <= 1'b1;
end

// ---- the design --------------------------------------------------------------
wire [7:0]  game_r, game_g, game_b;
wire        game_de, game_hs, game_vs;

wire        mem_in_ready;
wire [23:0] mem_addr;
wire [7:0]  rom_data;
wire        rom_data_available, rom_busy;

assign video_rgb = rom_ready ? {game_r, game_g, game_b} : idle_rgb;
assign video_de  = rom_ready ? game_de : idle_de;
assign video_hs  = rom_ready ? game_hs : idle_hs;
assign video_vs  = rom_ready ? game_vs : idle_vs;

M_main u_soc (
    .in_mem_data          ( rom_data           ),
    .in_mem_data_available( rom_data_available ),
    .in_mem_busy          ( rom_busy           ),
    .in_jstick            ( jstick             ),

    .out_mem_in_ready     ( mem_in_ready       ),
    .out_mem_addr         ( mem_addr           ),

    .out_video_r          ( game_r             ),
    .out_video_g          ( game_g             ),
    .out_video_b          ( game_b             ),
    .out_video_de         ( game_de            ),
    .out_video_hs         ( game_hs            ),
    .out_video_vs         ( game_vs            ),
    .out_leds             (                    ),   // no LEDs on the Pocket
    .out_vblank           (                    ),

    .in_run               ( 1'b1               ),
    .out_done             (                    ),
    .reset                ( design_reset       ),   // ACTIVE HIGH
    .out_clock            (                    ),
    .clock                ( clk_core           )
);

aw_rom u_rom (
    .clk_core             ( clk_core             ),
    .rst_core             ( rst_core             ),
    .mem_in_ready         ( mem_in_ready         ),
    .vm_running           ( design_run           ),   // the VM's request is meaningless
                                                       // until the pack is loaded
    .mem_addr             ( mem_addr             ),
    .mem_data             ( rom_data             ),
    .mem_data_available   ( rom_data_available   ),
    .mem_busy             ( rom_busy             ),

    .clk_psram            ( clk_psram            ),
    .rst_psram            ( rst_psram            ),

    .clk_bridge           ( clk_74a              ),
    .rst_bridge           ( rst_bridge           ),
    .bridge_wr            ( bridge_wr            ),
    .bridge_addr          ( bridge_addr          ),
    .bridge_wr_data       ( bridge_wr_data       ),
    .dataslot_allcomplete ( dataslot_allcomplete ),

    .rom_ready            ( rom_ready            ),
    .rom_error            ( rom_error            ),
    .rom_loading          (                      ),

    .cram0_a              ( cram0_a              ),
    .cram0_dq             ( cram0_dq             ),
    .cram0_wait           ( cram0_wait           ),
    .cram0_clk            ( cram0_clk            ),
    .cram0_adv_n          ( cram0_adv_n          ),
    .cram0_cre            ( cram0_cre            ),
    .cram0_ce0_n          ( cram0_ce0_n          ),
    .cram0_ce1_n          ( cram0_ce1_n          ),
    .cram0_oe_n           ( cram0_oe_n           ),
    .cram0_we_n           ( cram0_we_n           ),
    .cram0_ub_n           ( cram0_ub_n           ),
    .cram0_lb_n           ( cram0_lb_n           )
);

//
// audio i2s silence generator
// see other examples for actual audio generation
//

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum;
    reg                 audgen_mclk;
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
    reg         audgen_lrck_1;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S 
// 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
//
    reg     [4:0]   audgen_lrck_cnt;    
    reg             audgen_lrck;
    reg             audgen_dac;
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;
        
    end 
end


///////////////////////////////////////////////


endmodule
