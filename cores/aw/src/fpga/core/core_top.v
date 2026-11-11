//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top
// Die 0 in full, and THIS default is the one the bitstream gets. It used to say 2 MiB with the
// comment "whole pack", which was true until the image became a paged pool - and because this
// top-level parameter overrides aw_rom's own default, widening the census inside aw_rom changed
// nothing in hardware at all. A default duplicated at two levels of a hierarchy is two defaults;
// if you change the inner one, change this one, or the audit will say "census clean" about 2 MiB
// while the pool runs to 0x2F0000. Benches shrink it, they do not widen it.
#(parameter [21:0] CENSUS_RANGE = 22'h20_0000)
(

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

// cart is otherwise unused; directions are 0:IN, 1:OUT.
// bank0 goes out on the debug console (debug key UART + LED) - see that section
// below for the assign; it must not be driven here as well.
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
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
// the pixels, its quadrature twin for the scaler, 92.8125 MHz for the PSRAM sequence.
// See aw_pll.v for the ratios and for why this clock and not upstream's 25 MHz.
//
// Reset is staged on purpose, and the two halves come out in a specific order that
// hardware proved (2026-10-17): the LOAD path (bridge acceptance, FIFO, PSRAM drain,
// trailer check) must be up as soon as the PLL locks, because the OS streams the pack
// with `loadf` while still holding the core in reset - Reset Exit comes after the
// transfer. The GAME only leaves reset once rom_ready says a pack is there and its
// trailer made sense AND the host has released us. aw_reset_gen owns this ordering;
// starting the interpreter on an empty PSRAM would not only show garbage: it would
// run the VM off whatever the chip happened to contain, with the read path it uses
// for everything else untested.
//
// rom_ready / rom_error come from aw_rom in the design clock and are only read
// here, in that same clock.

wire clk_core, clk_core90, clk_psram, pll_locked;
wire rom_ready;
wire [1:0]  rom_error;
wire [127:0] rom_chk_data;    // debug: last trailer readback, shown on the red screen
wire [31:0]  rom_dbg_wr_match; // debug: host writes that passed the window filter
wire [31:0]  rom_dbg_wr_all;   // debug: every bridge write seen
wire [15:0]  rom_dbg_status;   // debug: {overflow, allc_seen, last_match[23:10]}
wire [31:0]  rom_dbg_rd_bytes; // debug: ROM bytes streamed to the VM (clk_core)
wire [31:0]  rom_census_sum_r, rom_census_sum_w;  // whole-pack census (see aw_rom)
wire [3:0]   rom_census_qmism;
wire [2:0]   rom_census_stat;  // {timeout, done, gap}
// debug: PSRAM self-test matrix (see aw_rom) - a5a5 in D/B/N/R names the control
// assumption that was wrong; P must read 0004 (part1) once reads work at all
wire [15:0]  rom_selftest_die0;
wire [15:0]  rom_selftest_be;
wire [15:0]  rom_selftest_ceneg;
wire [15:0]  rom_selftest_cre;
wire [15:0]  rom_selftest_pack0;

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

// The host's reset and the PLL lock pin, in the order hardware proved. See
// aw_reset_gen.v for why reset_n must NOT touch the load path.
//
// rst_bridge drives bridge-domain logic, so it is derived from the SYNCHRONISED copy
// of the lock pin (pll_locked_s), not the raw async output of the PLL: the raw pin
// crossing clk_74a unsynchronised was exactly the single-bit CDC this design's own
// rules forbid (the same signal already goes through s_pll_locked for status_boot_done,
// and the host only starts writing after seeing that, so releasing the load path on
// the same cycle is both safe and consistent).
wire rst_bridge, rst_core, rst_psram, design_run;
aw_reset_gen u_rstgen (
    .clk_core   ( clk_core   ),
    .clk_psram  ( clk_psram  ),
    .pll_locked ( pll_locked_s ),
    .reset_n    ( reset_n    ),
    .rom_ready  ( rom_ready  ),
    .rst_bridge ( rst_bridge ),
    .rst_core   ( rst_core   ),
    .rst_psram  ( rst_psram  ),
    .design_run ( design_run )
);

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
// The SoC's own reset: the framework's Reset Exit releases it, and a chapter change pulses it.
//
// Why the SoC's reset and not the VM's own algorithm reset: aw_pocket.si binds `vm <!vm_restart>`,
// which resets the VM's registers but does NOT restart its sequential program. Measured - with only
// that binding driven, a mid-game switch moved the page table and the VM kept consuming the OLD
// chapter's bytecode: bytes_to_vm kept climbing, and the new part's trailer never appeared in the next
// 512 bytes the VM read. Resetting the whole SoC re-runs it the way boot does, which is a path this
// port has exercised millions of times. The cost is that the framebuffers clear, so a chapter change
// shows a brief blank frame - the honest price of "start the next chapter" and not "splice it in".
// `~idx_load_done` holds the game off until the audio index has been copied out of the image. The copy is
// ~1700 byte reads through the ONE PSRAM port, and the VM's bytecode stream contends for that port; measured
// in tb_top with the VM running, the copy crawled (160 bytes in a second) because the audio fetch only wins
// when the sequencer is idle. Holding the SoC in reset for a couple of milliseconds of boot is a smaller
// price than an audio subsystem that may not be ready when the script asks for a sound - and it costs no
// boot time at all in the common case, because the copy runs while the port is otherwise quiet.
wire design_reset = ~design_run | rom_vm_restart | ~audio_base_ok;

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
           ERR_DIR     = 2'd3;    // the image's directory was refused (it used to be the
                                   // unreachable ERR_WAIT; see aw_rom's comment on the reuse)

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

// The red screen is also a debugger. Cell pitch is 16 px with a 14 px mark, 16
// columns x 12 rows = 256 x 192 in the 320 x 200 active area. Reading it off a
// photo (a lit cell = a set bit):
//
//   rows 0-7  the sixteen bytes the last trailer check read back, one column per
//             byte, top bit = MSB: columns left to right are chk_data[7:0] ...
//             chk_data[127:120], so the first four columns are offset 0 (must be
//             all dark), the next four offset 1, and so on. A constant pattern
//             (every column identical) means the chip never answered; a pattern
//             that changes between the ~84 ms retries means marginal timing;
//             plausible-but-wrong values mean address corruption.
//   rows 8-9  rom_dbg_wr_match, top row = [31:16], MSB left. A complete 2 MiB pack
//             is 524284 words = 0x7FFEC, so a good load shows 0007 / FFEC.
//   row 10    rom_dbg_wr_all[31:16]: host command traffic plus any writes that did
//             NOT match the window filter. If rows 8-9 are zero but this is not,
//             the bridge is alive and the address filter is wrong.
//   row 11    {overflow, allc_seen, last_match_addr[23:10]}: cell 0 lit = the FIFO
//             overflowed (bytes dropped), cell 1 lit = the host sent "all complete",
//             cells 2-15 are where the last accepted write landed (a good load ends
//             at 0x1FFEF0, which is all lit).
wire [9:0] dbg_ax = idle_x - VID_H_BPORCH;
wire [8:0] dbg_ay = idle_y - VID_V_BPORCH;
wire       dbg_in_grid = (dbg_ax >= 10'd32) && (dbg_ax < 10'd288)
                      && (dbg_ay >= 9'd4)   && (dbg_ay <  9'd196);
wire [8:0] dbg_gx = dbg_ax - 10'd32;
wire [8:0] dbg_gy = dbg_ay - 9'd4;
wire [3:0] dbg_col = dbg_gx[7:4];
wire [3:0] dbg_row = dbg_gy[7:4];
wire       dbg_in_cell = (dbg_gx[3:0] < 4'd14) && (dbg_gy[3:0] < 4'd14);

wire [7:0] dbg_byte = rom_chk_data[{dbg_col, 3'b000} +: 8];
wire [3:0] dbg_bit  = 4'd7 - dbg_row;

reg        dbg_set;
always @(*) begin
    if (dbg_row < 4'd8)           dbg_set = dbg_byte[dbg_bit];
    else if (dbg_row == 4'd8)     dbg_set = rom_dbg_wr_match[31 - dbg_col];
    else if (dbg_row == 4'd9)      dbg_set = rom_dbg_wr_match[15 - dbg_col];
    else if (dbg_row == 4'd10)     dbg_set = rom_dbg_wr_all[31 - dbg_col];
    else begin
        if (dbg_col == 4'd0)       dbg_set = rom_dbg_status[15];
        else if (dbg_col == 4'd1)  dbg_set = rom_dbg_status[14];
        else                       dbg_set = rom_dbg_status[dbg_col - 4'd2];
    end
end

always @(posedge clk_core) begin

    idle_de  <= 1'b0;
    idle_hs  <= 1'b0;
    idle_vs  <= 1'b0;
    idle_rgb <= 24'h0;

    idle_blink <= idle_blink + 25'd1;

    if (idle_active) begin
        idle_de <= 1'b1;
        case (rom_error)
            ERR_TRAILER: begin
                // red, and the trailer bytes as a bit grid - see dbg_* above
                if (dbg_in_grid)
                    idle_rgb <= dbg_set ? 24'hffffff : (dbg_in_cell ? 24'h501010 : 24'h180000);
                else
                    idle_rgb <= 24'h280000;
            end
            ERR_OVERFLOW: idle_rgb <= 24'hc010c0;   // purple: bridge outran the chip
            ERR_DIR:      idle_rgb <= 24'hc08010;   // amber:  the pool's directory was refused, so
                                                     // the VM was never started - wrong pages would
                                                     // look like a game, this looks like a fault
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

// The mux switch must be protocol-clean in two ways, and both matter:
//
// 1. No stretched sync pulse. Both rasters run free on clk_core (the generated
//    netlist does not reset the timing registers - see the note above M_main), with
//    a fixed but unpredictable phase offset set by how long the pack load took.
//    Switching exactly when rom_ready rises can glue the idle stream's hs/vs to the
//    game stream's into a two-cycle pulse - R1 says pulses are exactly one cycle
//    wide. Guarded with one-cycle-delay copies of the idle pulses (geometry-free).
//
// 2. No partial-DE line. The line containing the switch cycle carries the idle
//    stream's remainder of its current line plus the game stream's beginning.
//    i_x counts cycles since the idle hs pulse; this raster's idle de window sits at
//    i_x [214, 533], and the switch cycle itself shows the game stream. The idle
//    remainder is therefore exactly 0 or a full 320 only when the switch lands at
//    i_x <= 214 (window not started) or i_x >= 534 (window already spent). The game
//    side of that line is suppressed (de and rgb forced to 0) until the next game hs,
//    so the transition line carries exactly what the idle remainder had: one blank
//    line in the first game frame instead of a mixed pixel count (R5: lines carry 0
//    or exactly 320). i_safe holds for ~504 consecutive cycles every line, and the
//    pulse guard can block at most two of them, so the switch always resolves within
//    one line.
reg [9:0] i_x;
always @(posedge clk_core) begin
    if (idle_hs) i_x <= 10'd0; else i_x <= i_x + 10'd1;
end
reg idle_hs_d, idle_vs_d;
always @(posedge clk_core) begin
    idle_hs_d <= idle_hs;
    idle_vs_d <= idle_vs;
end

wire i_safe     = (i_x < 10'd215) || (i_x > 10'd533);   // idle de window [214, 533]
wire pulse_safe = !(game_hs && idle_hs_d) && !(game_vs && idle_vs_d);

reg  video_sel_r;
wire switch_now = rom_ready && !video_sel_r && i_safe && pulse_safe;
wire video_sel  = video_sel_r | switch_now;
// Explicit reset to 0: without one, Quartus folds this latch to a VCC constant
// (it picks the self-consistent power-up value Q=1, which makes switch_now dead),
// and then optimises the ENTIRE idle screen out of the bitstream - on hardware that
// is a black M_main-in-reset raster with valid sync, no idle block, no error screens.
always @(posedge clk_core) begin
    if (rst_core)        video_sel_r <= 1'b0;
    else if (switch_now) video_sel_r <= 1'b1;
end

// Suppress the game side of the transition line (de + rgb), mid-line switches only:
// if the switch lands on a game hs cycle, that line ends right there and nothing is lost.
reg suppress_de;
always @(posedge clk_core) begin
    if (switch_now && !game_hs) suppress_de <= 1'b1;
    else if (game_hs)           suppress_de <= 1'b0;
end
wire suppress = suppress_de | (switch_now && !game_hs);

assign video_rgb = video_sel ? (suppress ? 24'h0 : {game_r, game_g, game_b}) : idle_rgb;
assign video_de  = video_sel ? (game_de & ~suppress) : idle_de;
assign video_hs  = video_sel ? game_hs : idle_hs;
assign video_vs  = video_sel ? game_vs : idle_vs;

M_main u_soc (
    .in_mem_data          ( rom_data           ),
    .in_mem_data_available( rom_data_available ),
    .in_mem_busy          ( rom_busy           ),
    .in_jstick            ( jstick             ),
    // Restart the VM from its first statement - which re-reads the trailer at 0x1FFFE0 and so starts
    // whatever part the page table names. This is the whole "continuous play" mechanism: aw_rom pulses
    // it when the player picks a different part from the OSD while the game is running, and because
    // all eight tables are already resident the switch costs one pulse and no upload. The comment in
    // aw_rom's part-select block used to say this was impossible because the pin was tied to 0; that
    // was true of OUR top, not of the VM - aw_pocket.si now drives it.
    .in_vm_restart        ( rom_vm_restart     ),

    .out_mem_in_ready     ( mem_in_ready       ),
    .out_mem_addr         ( mem_addr           ),

    .out_video_r          ( game_r             ),
    .out_video_g          ( game_g             ),
    .out_video_b          ( game_b             ),
    .out_video_de         ( game_de            ),
    .out_video_hs         ( game_hs            ),
    .out_video_vs         ( game_vs            ),
    .out_part_req         ( vm_part_req        ),   // the game's own chapter request (vm.si)
    // The op_playSound / op_playMusic arguments. These nine outputs existed and were harvest-verified
    // (docs/another-world/audio-plan.md) while nothing in this file consumed them, which is the "verified
    // nobody is allowed to find out about" pattern: they are now wired to the mixer below.
    .out_snd_seq          ( snd_seq            ),
    .out_snd_res          ( snd_res            ),
    .out_snd_freq         ( snd_freq           ),
    .out_snd_vol          ( snd_vol            ),
    .out_snd_ch           ( snd_ch             ),
    .out_mus_seq          ( mus_seq            ),
    .out_mus_num          ( mus_num            ),
    .out_mus_delay        ( mus_delay          ),
    .out_mus_pos          ( mus_pos            ),
    .out_leds             (                    ),   // no LEDs on the Pocket
    .out_vblank           (                    ),

    .in_run               ( 1'b1               ),
    .out_done             (                    ),
    .reset                ( design_reset       ),   // ACTIVE HIGH
    .out_clock            (                    ),
    .clock                ( clk_core           )
);

// Directory / paging state. These were left unconnected the moment they were added, which is how a
// core can spend a week verifying things nobody is allowed to find out about.
wire        rom_dir_valid, rom_dir_bad, rom_dir_busy, rom_part_late, rom_pool_ok, rom_vm_restart;
wire [15:0] vm_part_req;
wire [2:0]  rom_part_sel;
wire [6:0]  rom_dir_err;

aw_rom #(.CENSUS_RANGE(CENSUS_RANGE)) u_rom (
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

    // Page-table load port. Tied off until task #18 installs the directory loader; testbenches
    // drive it so paging is exercised before the boot FSM exists. See aw_rom's page table.
    .tbl_wr               ( 1'b0                 ),
    .tbl_widx             ( 6'd0                 ),
    .tbl_wval             ( 8'd0                 ),
    .rom_tbl_loaded       (                      ),

    .rom_ready            ( rom_ready            ),
    .rom_error            ( rom_error            ),
    .rom_loading          (                      ),
    .rom_chk_data         ( rom_chk_data         ),
    .rom_dbg_wr_match     ( rom_dbg_wr_match     ),
    .rom_dbg_wr_all       ( rom_dbg_wr_all       ),
    .rom_dbg_status       ( rom_dbg_status       ),
    .rom_dbg_rd_bytes     ( rom_dbg_rd_bytes     ),
    .rom_census_sum_r     ( rom_census_sum_r     ),
    .rom_census_sum_w     ( rom_census_sum_w     ),
    .rom_census_qmism     ( rom_census_qmism     ),
    .rom_census_stat      ( rom_census_stat      ),
    .rom_selftest_die0    ( rom_selftest_die0    ),
    .rom_selftest_be      ( rom_selftest_be      ),
    .rom_selftest_ceneg   ( rom_selftest_ceneg   ),
    .rom_selftest_cre     ( rom_selftest_cre     ),
    .rom_selftest_pack0   ( rom_selftest_pack0   ),
    .rom_dir_valid        ( rom_dir_valid        ),
    .rom_dir_bad          ( rom_dir_bad          ),
    .rom_dir_busy         ( rom_dir_busy         ),
    .rom_dir_err          ( rom_dir_err          ),
    .rom_part             ( rom_part_sel         ),
    .rom_part_late        ( rom_part_late        ),
    .rom_pool_ok          ( rom_pool_ok          ),
    .aud_req              ( aud_req              ),
    .aud_addr             ( aud_addr             ),
    .aud_data             ( aud_data             ),
    .aud_valid            ( aud_valid            ),
    .rom_vm_restart       ( rom_vm_restart       ),
    .vm_part_req          ( vm_part_req          ),

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
// debug console (115200 8N1)
//
// Short log lines: core up, pack loaded, game running, ROM errors, and menu
// navigation. Everything runs in the clk_core domain; osnotify_inmenu is the
// one signal that crosses from the bridge handler (clk_74a) and gets the usual
// 3FF, whose rise/fall outputs are the events.
//
// The line goes out two ways:
//   - cart_tran_bank0[6]: UART TX of the Analogue devkit debug key (cart pin 3),
//     with bank0[5] as its activity LED (pin 4). Wiring per agg23/
//     analogue-pocket-utils, wiki "Devkit - Debug Key" / ip/debug_key.v. The
//     key needs cart power: core.json cartridge_adapter must be 0.
//   - dbg_tx: the FPGA breakout pin, same signal, for a soldered/external UART.
//

wire design_run_rise, rom_ready_rise;
reg design_run_d, rom_ready_d;
always @(posedge clk_core) begin
    design_run_d <= design_run;
    rom_ready_d  <= rom_ready;
end
assign design_run_rise = design_run & ~design_run_d;
assign rom_ready_rise  = rom_ready  & ~rom_ready_d;

wire inmenu_s, inmenu_rise, inmenu_fall;
synch_3 u_inmenu_sync (
    .i     ( osnotify_inmenu ),
    .o     ( inmenu_s        ),
    .clk   ( clk_core        ),
    .rise  ( inmenu_rise     ),
    .fall  ( inmenu_fall     )
);

// ---- video / VM liveness counters -------------------------------------------------
// 1036a reported C0 (pack validated, trailer correct, rom_ready high, so design_run
// high and the VM released) and the panel stayed black. Every layer under the render
// path now answers on hardware, so the console has to name which side of the SoC's
// video output is quiet: frames, de per frame, non-black pixels per frame, ROM bytes
// the VM has consumed, and the mux/reset state.
//
// All of this is already in clk_core - the generated SoC runs on clk_core and so does
// the idle raster - so no synchroniser is needed, and nothing here leaves the clock
// (dbg_console is clk_core as well).
reg [23:0] vid_frames;              // game-path vsync pulses since rst_core released
reg [19:0] vid_de, vid_lit;         // counting the frame in progress
reg [19:0] vid_de_last, vid_lit_last;
reg        vid_saw_hs, vid_saw_vs;
always @(posedge clk_core) begin
    if (rst_core) begin
        vid_frames     <= 24'd0;
        vid_de         <= 20'd0;
        vid_lit        <= 20'd0;
        vid_de_last    <= 20'd0;
        vid_lit_last   <= 20'd0;
        vid_saw_hs     <= 1'b0;
        vid_saw_vs     <= 1'b0;
    end else begin
        if (game_hs) vid_saw_hs <= 1'b1;
        if (game_vs) begin
            // vs is a one-cycle pulse inside blanking, so snapshotting here rather
            // than counting this cycle too costs nothing
            vid_saw_vs   <= 1'b1;
            vid_frames   <= vid_frames + 24'd1;
            vid_de_last  <= vid_de;
            vid_lit_last <= vid_lit;
            vid_de       <= 20'd0;
            vid_lit      <= 20'd0;
        end else if (game_de) begin
            vid_de <= vid_de + 20'd1;
            if (game_r | game_g | game_b) vid_lit <= vid_lit + 20'd1;
        end
    end
end
// {saw_hs, saw_vs, inmenu, design_run, video_sel, suppress, 0, rom_ready}
wire [7:0] vid_status = {1'b0, vid_saw_hs, vid_saw_vs, inmenu_s, design_run,
                         video_sel, suppress, rom_ready};

wire [7:0] cons_data;
wire       cons_valid, cons_ready;

// The console banner is how a capture identifies WHICH bitstream is in the FPGA, and it derives the number
// from this parameter. It was left at dbg_console's default, so every build since 1046 announced "AW 1046a
// up" - the same lie the file's own comment records for 1040-1042, and it cost a hardware round trip: a
// capture could not be told apart from the one it was meant to test. BUMP THIS WITH EVERY INSTALL.
localparam [15:0] AW_BUILD_ID = 16'd1064;

dbg_console #(.BUILD_ID(AW_BUILD_ID)) u_cons (
    .clk        ( clk_core          ),
    .rst_n      ( ~rst_core         ),
    .ev_boot    ( design_run_rise   ),
    .ev_rom_ok  ( rom_ready_rise    ),
    .rom_error  ( rom_error         ),
    .ev_inmenu  ( inmenu_rise       ),
    .ev_outmenu ( inmenu_fall       ),
    .rom_chk_data( rom_chk_data     ),
    .rom_dbg_wr_match( rom_dbg_wr_match ),
    .rom_dbg_wr_all  ( rom_dbg_wr_all   ),
    .rom_dbg_status  ( rom_dbg_status   ),
    .rom_selftest_die0( rom_selftest_die0  ),
    .rom_selftest_be( rom_selftest_be      ),
    .rom_selftest_ceneg( rom_selftest_ceneg ),
    .rom_selftest_cre( rom_selftest_cre    ),
    .rom_selftest_pack0( rom_selftest_pack0 ),
    .vid_frames    ( vid_frames         ),
    .vid_de_per_frame( vid_de_last      ),
    .vid_lit_per_frame( vid_lit_last    ),
    .rom_rd_bytes  ( rom_dbg_rd_bytes   ),
    .cen_sum_r     ( rom_census_sum_r   ),
    .cen_sum_w     ( rom_census_sum_w   ),
    .cen_qmism     ( rom_census_qmism   ),
    .cen_stat      ( rom_census_stat    ),
    .vid_status    ( vid_status         ),
    .dir_valid     ( rom_dir_valid      ),
    .dir_bad       ( rom_dir_bad        ),
    .pool_ok       ( rom_pool_ok        ),
    .part_late     ( rom_part_late      ),
    .rom_part      ( rom_part_sel       ),
    .dir_err       ( rom_dir_err        ),
    // The music's own telemetry. These inputs existed on dbg_console from AW 1055 but were never connected
    // here, and Verilog ties an unconnected input to 0 - so every capture printed M0 0000 0000 C00 S00 D00 and
    // three hardware sessions were spent chasing a cue that the console was not actually reporting on.
    .mus_running   ( mus_running        ),
    .mus_rows      ( mus_rows           ),
    .mus_plays     ( mus_plays          ),
    .mus_last_inc  ( mus_last_inc       ),
    .mus_last_base ( mus_last_base      ),
    .mus_cues      ( mus_cues           ),
    .mus_state     ( mus_state          ),
    .mus_inc1_cnt  ( mus_inc1_cnt       ),
    .snd_cues      ( snd_cues           ),
    .idx_tag       ( idx_tag            ),
    .idx_count     ( idx_count          ),
    .tx_data    ( cons_data         ),
    .tx_valid   ( cons_valid        ),
    .tx_ready   ( cons_ready        )
);

wire uart_line, uart_busy;

dbg_uart_tx #(
    .CLK_FREQ ( 24_750_000 ),
    .BAUD     ( 115_200    )
) u_dbg_uart (
    .clk      ( clk_core   ),
    .rst_n    ( ~rst_core  ),
    .tx_data  ( cons_data  ),
    .tx_valid ( cons_valid ),
    .tx_ready ( cons_ready ),
    .busy     ( uart_busy  ),
    .dbg_tx   ( uart_line  )
);

assign dbg_tx = uart_line;

// debug key: [7] and [4] stay high as before, [6] = UART TX, [5] = LED.
// bank3[0] (button) and pin31 (UART RX) remain inputs if ever needed.
assign cart_tran_bank0 = {1'b1, uart_line, uart_busy, 1'b1};

//
// AUDIO.
//
// The VM's op_playSound arguments (above) resolve through the image's audio index and drive a four-channel
// mixer in clk_core; the mixed sample crosses into the MCLK domain through a small dual-clock FIFO and is
// shifted out as I2S. The chain, and why each piece lives where it does, is in
// docs/another-world/audio-plan.md - the short version:
//
//   * the MIXER is in clk_core, next to the VM, so the command path (which carries the repeated-identical-
//     request hazard that `snd_seq` exists for) needs no clock crossing at all;
//   * only BYTES cross to clk_psram, one at a time, through aw_audio_rd's 4-phase handshake into aw_rom's
//     audio port;
//   * the INDEX is copied out of the image once at boot (aw_audio_idx), so a lookup costs no PSRAM traffic
//     and cannot starve the mixer;
//   * the MIXER's 48 kHz tick comes from aw_audio_tick (fractional accumulator: 24.75 MHz / 48 kHz = 515.625
//     is not an integer, and a wrong tick is a wrong sample rate).
//
// Everything audio waits for `idx_load_done`: the mixer would otherwise fetch from the same byte port the
// loader is using, and the boot copy takes ~1.7 ms of a boot that is already seconds long.
//
wire [7:0]  snd_seq, snd_freq, snd_vol, snd_ch;
wire [15:0] snd_res;
wire [7:0]  mus_seq, mus_pos;
wire [15:0] mus_num, mus_delay;

wire        audio_tick;
wire        idx_load_start, idx_load_busy, idx_load_done;
wire [23:0] idx_ldr_addr;
wire        idx_ldr_req, idx_ldr_valid;
wire [7:0]  idx_ldr_data;

wire        idx_start, idx_busy, idx_found;
wire [15:0] idx_res;
wire [7:0]  idx_type;
wire [31:0] idx_blob;
wire [15:0] idx_poff, idx_plen, idx_ls, idx_ll;

wire        aud_cmd_valid;
wire        aud_cmd_stop;
wire [1:0]  aud_cmd_ch;
wire [5:0]  aud_cmd_freq;
wire [7:0]  aud_cmd_vol;
wire [23:0] aud_cmd_len, aud_cmd_lp, aud_cmd_ll, aud_cmd_base;

wire signed [7:0] mix_sample;
wire        mix_valid;
wire [31:0] mix_drop_ticks;

wire [23:0] mix_rd_addr;
wire        mix_rd_req, mix_rd_valid;
wire [7:0]  mix_rd_data;

wire [15:0] aud_underruns, aud_overruns;
wire        aud_sclk_unused;

// ---- 48 kHz tick in clk_core ----
aw_audio_tick u_audio_tick (
    .clk  ( clk_core   ),
    .rst  ( rst_core   ),
    .tick ( audio_tick )
);

// ---- one play request per CHANGE of snd_seq ----
// The VM increments snd_seq once per op_playSound (including vol == 0, which is a stop). Comparing against a
// delayed copy means a repeated identical request is still seen, which a level-based trigger would miss.
reg [7:0] snd_seq_d;
always @(posedge clk_core) begin
    if (rst_core) snd_seq_d <= 8'd0;
    else          snd_seq_d <= snd_seq;
end
wire snd_play = (snd_seq != snd_seq_d);

// ---- index: copied out of the image once, at the first moment the pack is known to be complete ----
reg idx_load_armed;
always @(posedge clk_core) begin
    if (rst_core)            idx_load_armed <= 1'b0;
    else if (rom_ready)      idx_load_armed <= 1'b1;
end
assign idx_load_start = idx_load_armed & ~idx_load_done & ~idx_load_busy;

aw_audio_idx u_audio_idx (
    .clk        ( clk_core       ),
    .rst        ( rst_core       ),
    .load_start ( idx_load_start ),
    .load_busy  ( idx_load_busy  ),
    .load_done  ( idx_load_done  ),
    .ldr_addr   ( idx_ldr_addr   ),
    .ldr_req    ( idx_ldr_req    ),
    .ldr_valid  ( idx_ldr_valid  ),
    .ldr_data   ( idx_ldr_data   ),
    .start      ( idx_start      ),
    .res_id     ( idx_res        ),
    .busy       ( idx_busy       ),
    .found      ( idx_found      ),
    .r_type     ( idx_type       ),
    .r_blob_off ( idx_blob       ),
    .r_pcm_off  ( idx_poff       ),
    .r_pcm_len  ( idx_plen       ),
    .r_loop_start ( idx_ls       ),
    .r_loop_len   ( idx_ll       ),
    // the tag and count as COPIED, for the console's K field. These were declared and printed since AW 1062
    // but never driven here - the same unconnected-input fault as the music fields, one level down, and just
    // as invisible: the bench drives dbg_console's idx_tag/idx_count directly, so nothing failed.
    .dbg_tag    ( idx_tag        ),
    .dbg_count  ( idx_count      ),
    // the tracker resolves its instrument records through this port rather than the single-request resolver
    .scan_addr  ( idx_scan_addr  ),
    .scan_q     ( idx_scan_q     )
);

// ---- music: op_playMusic, and the same "a request is a CHANGE of the sequence counter" rule ----
reg [7:0] mus_seq_d;
always @(posedge clk_core) begin
    if (rst_core) mus_seq_d <= 8'd0;
    else          mus_seq_d <= mus_seq;
end
// A cue is a CHANGE of mus_seq (this is what played on AW 1052). The increment test that was meant to tell a
// cue from a SoC reset silencing the counter is kept as a MEASUREMENT, not as the trigger: with it as the
// trigger nothing ever played, and the two counters below say whether the counter is incrementing by one at
// all. C counts every change, D counts the changes that were exactly +1.
wire [7:0] mus_delta = mus_seq - mus_seq_d;
wire mus_play = (mus_seq != mus_seq_d);
wire mus_inc1 = (mus_delta == 8'd1);

wire        mus_cmd_valid, mus_cmd_stop, mus_cmd_touch, mus_cmd_use_inc;
wire [8:0]  mus_cmd_inc;
wire [1:0]  mus_cmd_ch;
wire [7:0]  mus_cmd_vol;
wire [23:0] mus_cmd_len, mus_cmd_lp, mus_cmd_ll, mus_cmd_base;
// no mus_cmd_freq: the tracker plays notes through cmd_inc/cmd_use_inc (arbitrary Hz), and the old
// cmd_freq output was never assigned - a dead port the lint guard now reports.
wire        mus_rd_req, mus_rd_valid;
wire [23:0] mus_rd_addr;
wire [7:0]  mus_rd_data;
wire        mus_marker_valid;
wire [15:0] mus_marker_value;
wire [1:0]  mus_marker_ch;
wire        mus_running;
wire        mus_row_valid;
wire [4:0]  mus_state;
reg  [7:0]  mus_cues, mus_inc1_cnt;
always @(posedge clk_core) begin
    if (rst_core) begin
        mus_cues     <= 8'd0;
        mus_inc1_cnt <= 8'd0;
    end else begin
        if (mus_play)  mus_cues     <= mus_cues + 8'd1;
        if (mus_inc1)  mus_inc1_cnt <= mus_inc1_cnt + 8'd1;
    end
end
// Counters for the console line: what the tracker is actually doing on hardware. The music is the one part
// of this feature whose failure is not visible in the picture, so it has to report on itself.
reg  [15:0] mus_rows, mus_plays;
reg  [8:0]  mus_last_inc;
reg  [23:0] mus_last_base;
always @(posedge clk_core) begin
    if (rst_core) begin
        mus_rows <= 16'd0; mus_plays <= 16'd0;
        mus_last_inc <= 9'd0; mus_last_base <= 24'd0;
    end else begin
        if (mus_row_valid) mus_rows <= mus_rows + 16'd1;
        if (mus_cmd_valid && mus_cmd_touch && !mus_cmd_stop) begin
            mus_plays     <= mus_plays + 16'd1;
            mus_last_inc  <= mus_cmd_inc;
            mus_last_base <= mus_cmd_base;
        end
    end
end
wire [7:0]  idx_tag, idx_count;
// How many op_playSound requests the VM has issued. Beside the music's cue counter this separates "the VM
// never reaches any audio opcode" from "it reaches sounds but not music", which look identical by ear.
reg  [7:0]  snd_cues;
always @(posedge clk_core) begin
    if (rst_core)      snd_cues <= 8'd0;
    else if (snd_play) snd_cues <= snd_cues + 8'd1;
end
wire [11:0] idx_scan_addr;
wire [7:0]  idx_scan_q;

aw_music u_music (
    .clk          ( clk_core      ),
    .rst          ( rst_core      ),
    .audio_base   ( audio_base_r  ),
    .play         ( mus_play & audio_base_ok ),
    .num          ( mus_num       ),
    .delay        ( mus_delay     ),
    .pos          ( mus_pos       ),
    .scan_addr    ( idx_scan_addr ),
    .scan_q       ( idx_scan_q    ),
    .rd_addr      ( mus_rd_addr   ),
    .rd_req       ( mus_rd_req    ),
    .rd_valid     ( mus_rd_valid  ),
    .rd_data      ( mus_rd_data   ),
    .cmd_valid    ( mus_cmd_valid ),
    .cmd_stop     ( mus_cmd_stop  ),
    .cmd_touch    ( mus_cmd_touch ),
    .cmd_use_inc  ( mus_cmd_use_inc ),
    .cmd_inc      ( mus_cmd_inc   ),
    .cmd_ch       ( mus_cmd_ch    ),
    .cmd_vol      ( mus_cmd_vol   ),
    .cmd_len      ( mus_cmd_len   ),
    .cmd_lp       ( mus_cmd_lp    ),
    .cmd_ll       ( mus_cmd_ll    ),
    .cmd_base     ( mus_cmd_base  ),
    .row_valid    ( mus_row_valid    ),
    .state_o      ( mus_state        ),
    .marker_valid ( mus_marker_valid ),
    .marker_value ( mus_marker_value ),
    .marker_ch    ( mus_marker_ch    ),
    .running      ( mus_running   )
);

// ---- the mixer has ONE command input, and two producers ----
// The effects path wins a collision; the music command is HELD until taken, because the tracker issues one
// per note and a dropped one is a missing note rather than a delayed one.
reg        pnd_valid, pnd_stop, pnd_touch, pnd_use_inc;
reg [8:0]  pnd_inc;
reg [1:0]  pnd_ch;
reg [7:0]  pnd_vol;
reg [23:0] pnd_len, pnd_lp, pnd_ll, pnd_base;

wire take_pnd = pnd_valid && !aud_cmd_valid;
wire mix_cmd_valid = aud_cmd_valid | take_pnd;

always @(posedge clk_core) begin
    if (rst_core) pnd_valid <= 1'b0;
    else begin
        if (take_pnd) pnd_valid <= 1'b0;
        if (mus_cmd_valid) begin
            pnd_valid   <= 1'b1;
            pnd_stop    <= mus_cmd_stop;
            pnd_touch   <= mus_cmd_touch;
            pnd_use_inc <= mus_cmd_use_inc;
            pnd_inc     <= mus_cmd_inc;
            pnd_ch      <= mus_cmd_ch;
            pnd_vol     <= mus_cmd_vol;
            pnd_len     <= mus_cmd_len;
            pnd_lp      <= mus_cmd_lp;
            pnd_ll      <= mus_cmd_ll;
            pnd_base    <= mus_cmd_base;
        end
    end
end

// ---- play request -> mixer command ----
// AUDIO_BASE is frames_base + pool_bytes for the shipping image. scripts/audio_addr_check.py proves the
// formula against build/aw-all-audio.bin (0x2F0000, 0 mismatches, checked on every audio build); it moves
// whenever the layout does, so it is one constant here and a check there rather than a remembered number.
aw_audio_ch u_audio_ch (
    .clk        ( clk_core       ),
    .rst        ( rst_core       ),
    .audio_base ( audio_base_r   ),   // derived from the image header at boot; see the header reader below
    .play       ( snd_play & audio_base_ok ),
    .res        ( snd_res        ),
    .freq       ( snd_freq[5:0]  ),
    .vol        ( snd_vol        ),
    .ch         ( snd_ch[1:0]    ),
    .idx_start  ( idx_start      ),
    .idx_res    ( idx_res        ),
    .idx_busy   ( idx_busy       ),
    .idx_found  ( idx_found      ),
    .idx_type   ( idx_type       ),
    .idx_blob   ( idx_blob       ),
    .idx_poff   ( idx_poff       ),
    .idx_plen   ( idx_plen       ),
    .idx_ls     ( idx_ls         ),
    .idx_ll     ( idx_ll         ),
    .cmd_valid  ( aud_cmd_valid  ),
    .cmd_stop   ( aud_cmd_stop   ),
    .cmd_ch     ( aud_cmd_ch     ),
    .cmd_freq   ( aud_cmd_freq   ),
    .cmd_vol    ( aud_cmd_vol    ),
    .cmd_len    ( aud_cmd_len    ),
    .cmd_lp     ( aud_cmd_lp     ),
    .cmd_ll     ( aud_cmd_ll     ),
    .cmd_base   ( aud_cmd_base   )
);

// ---- four-channel mixer, ticked at 48 kHz, sampling PSRAM through the shim ----
aw_mixer u_mixer (
    .clk        ( clk_core       ),
    .rst        ( rst_core       ),
    .tick       ( audio_tick & audio_base_ok ),
    .out_sample ( mix_sample     ),
    .out_valid  ( mix_valid      ),
    .drop_ticks ( mix_drop_ticks ),
    .cmd_valid  ( mix_cmd_valid  ),
    .cmd_stop   ( aud_cmd_valid ? aud_cmd_stop : pnd_stop ),
    .cmd_touch  ( aud_cmd_valid ? 1'b1          : pnd_touch ),
    .cmd_use_inc( aud_cmd_valid ? 1'b0          : pnd_use_inc ),
    .cmd_inc    ( aud_cmd_valid ? 9'd0          : pnd_inc ),
    .cmd_ch     ( aud_cmd_valid ? aud_cmd_ch     : pnd_ch ),
    .cmd_freq   ( aud_cmd_valid ? aud_cmd_freq   : 6'd0 ),
    .cmd_vol    ( aud_cmd_valid ? aud_cmd_vol    : pnd_vol ),
    .cmd_len    ( aud_cmd_valid ? aud_cmd_len    : pnd_len ),
    .cmd_loop_pos ( aud_cmd_valid ? aud_cmd_lp   : pnd_lp ),
    .cmd_loop_len ( aud_cmd_valid ? aud_cmd_ll   : pnd_ll ),
    .cmd_data_base( aud_cmd_valid ? aud_cmd_base : pnd_base ),
    .rd_addr    ( mix_rd_addr    ),
    .rd_req     ( mix_rd_req     ),
    .rd_valid   ( mix_rd_valid   ),
    .rd_data    ( mix_rd_data    )
);

// ---- ONE byte port, three callers, in a fixed order: index loader -> header read -> mixer ----
// They never overlap, so this is a sequence rather than an arbiter: the loader runs to completion at boot,
// then eight header bytes are read, and only then is the mixer's tick enabled. The owner is a REGISTER
// rather than a function of "busy", because the last byte's response arrives one cycle after `busy` drops -
// attributing that byte to the next caller would swallow it.
wire        aud_rd_req;
wire [23:0] aud_rd_addr;
wire [7:0]  aud_rd_data;
wire        aud_rd_valid;

reg [1:0]  aud_owner;                  // 0 = mixer, 1 = index loader, 2 = header reader, 3 = music
wire       shim_idle;
wire       hdr_req;
wire [23:0] hdr_addr;
reg  [7:0] hdr_data;
reg [2:0]  hb_st;
reg [4:0]  hb_i;
reg [23:0] hb_fb, hb_pb;   // 24 bits is the whole PSRAM window; the header's top byte of each u32 is
                            // dead by construction, and keeping it would leave registers with no fanout
reg [23:0] audio_base_r;
reg        audio_base_ok;

// AUDIO_BASE IS READ FROM THE IMAGE, NOT REMEMBERED. The builder appends the audio blob directly after the
// game pool and records both offsets in the header it already writes: frames_base at bytes 16..19 and
// pool_bytes at 20..23, little-endian, so audio_base = frames_base + pool_bytes (the formula
// scripts/audio_addr_check.py proves by reading the image at those addresses). Baking the number into the
// bitstream makes a bitstream and an image a pair, and a mismatch is indistinguishable from silence - which
// is what a hardware round trip cost: the 2-part probe image has its audio at 0x118000, not 0x2F0000.
always @(posedge clk_core) begin
    if (rst_core) begin
        hb_st <= 3'd0; hb_i <= 5'd0; hb_fb <= 24'd0; hb_pb <= 24'd0;
        audio_base_r <= 24'd0; audio_base_ok <= 1'b0;
    end else begin
        if (aud_rd_valid && (aud_owner == 2'd2)) hdr_data <= aud_rd_data;
        case (hb_st)
        3'd0: if (idx_load_done) begin
                  hb_i  <= 5'd0;
                  hb_st <= 3'd1;
              end
        3'd1: hb_st <= 3'd2;
        3'd2: if (aud_rd_valid) begin
                  // bytes 16..19 are frames_base, 20..23 are pool_bytes, little-endian; byte 3 of each is
                  // always zero for an image the PSRAM can hold, so it is read and ignored.
                  if (hb_i < 5'd4) begin
                      if (hb_i[1:0] != 2'd3) hb_fb[{hb_i[1:0], 3'b000} +: 8] <= aud_rd_data;
                  end else begin
                      if (hb_i[1:0] != 2'd3) hb_pb[{hb_i[1:0], 3'b000} +: 8] <= aud_rd_data;
                  end
                  hb_st <= 3'd3;
              end
        3'd3: if (hb_i == 5'd7) begin
                  audio_base_r  <= hb_fb + hb_pb;
                  audio_base_ok <= 1'b1;
                  hb_st         <= 3'd4;
              end else begin
                  hb_i  <= hb_i + 5'd1;
                  hb_st <= 3'd1;
              end
        default: ;
        endcase
    end
end

assign hdr_addr = 24'd16 + {19'd0, hb_i};
assign hdr_req  = (hb_st == 3'd1);

// After boot two producers share the port: the mixer wants 8 bytes per 48 kHz tick and the tracker 16 bytes
// per music row (one row per 133 ms). The grant alternates at BYTE granularity, so a row fetch can delay
// the mixer by one byte time rather than by a whole 16-byte burst - ~400 cycles of the 516-cycle tick, which
// would drop a tick every row. The grant only changes when the shim is between transactions, because its
// 4-phase handshake needs the previous caller's request to be low first.
always @(posedge clk_core) begin
    if (rst_core)                                aud_owner <= 2'd2;
    else if (idx_load_start)                     aud_owner <= 2'd1;
    else if (idx_load_done && aud_owner == 2'd1) aud_owner <= 2'd2;
    else if (audio_base_ok && aud_owner == 2'd2) aud_owner <= 2'd0;
    else if (audio_base_ok && shim_idle) begin
        // THE MIXER WINS, THE TRACKER TAKES THE GAPS.
        //
        // Round-robin was wrong: the mixer needs its eight bytes inside a 516-cycle tick, and sharing every
        // other slot doubled that, so ticks stopped completing and the core went SILENT - effects included.
        // The tracker needs 16 bytes per 133 ms, i.e. one byte every ~800 us, and the mixer's tick leaves
        // most of the port idle, so priority costs the music nothing.
        if (mix_rd_req)      aud_owner <= 2'd0;
        else if (mus_rd_req) aud_owner <= 2'd3;
    end
end

assign aud_rd_req     = (aud_owner == 2'd1) ? idx_ldr_req  :
                        (aud_owner == 2'd2) ? hdr_req      :
                        (aud_owner == 2'd3) ? mus_rd_req   : mix_rd_req;
assign aud_rd_addr    = (aud_owner == 2'd1) ? idx_ldr_addr :
                        (aud_owner == 2'd2) ? hdr_addr     :
                        (aud_owner == 2'd3) ? mus_rd_addr  : mix_rd_addr;
assign idx_ldr_valid  = aud_rd_valid & (aud_owner == 2'd1);
assign idx_ldr_data   = aud_rd_data;
assign mus_rd_valid   = aud_rd_valid & (aud_owner == 2'd3);
assign mus_rd_data    = aud_rd_data;
assign mix_rd_valid   = aud_rd_valid & (aud_owner == 2'd0);
assign mix_rd_data    = aud_rd_data;

wire        aud_req;
wire [23:0] aud_addr;
wire [7:0]  aud_data;
wire        aud_valid;

aw_audio_rd u_audio_rd (
    .clk_c    ( clk_core  ),
    .rst_c    ( rst_core  ),
    .req      ( aud_rd_req  ),
    .addr     ( aud_rd_addr ),
    .data     ( aud_rd_data ),
    .valid    ( aud_rd_valid ),
    .idle     ( shim_idle    ),
    .clk_p    ( clk_psram ),
    .rst_p    ( rst_psram ),
    .aud_req  ( aud_req   ),
    .aud_addr ( aud_addr  ),
    .aud_data ( aud_data  ),
    .aud_valid( aud_valid )
);

// ---- I2S out: real samples, exactly 48 kHz, MCLK 12.288 MHz ----
// The mixer's sample is 8-bit signed; it is sign-extended and scaled by 256 in aw_audio_i2s so full scale is
// full scale. The FIFO inside handles the two independent 48 kHz timebases.
wire [15:0] aud_sample16 = {{8{mix_sample[7]}}, mix_sample} << 8;

aw_audio_i2s u_audio_i2s (
    .clk_74a      ( clk_74a       ),
    .clk_core     ( clk_core      ),
    .rst_core     ( rst_core      ),
    .sample       ( aud_sample16  ),
    .sample_valid ( mix_valid     ),
    .audio_mclk   ( audio_mclk    ),
    .audio_sclk   ( aud_sclk_unused ),
    .audio_lrck   ( audio_lrck    ),
    .audio_dac    ( audio_dac     ),
    .underruns    ( aud_underruns ),
    .overruns     ( aud_overruns  )
);

///////////////////////////////////////////////


endmodule
