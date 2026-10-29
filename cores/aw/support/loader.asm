// pocket: Chip32 VM loader for the Another World core.
//
// The Analogue OS stages the selected data-slot file in host memory when the
// core boots ("File: Load ... Slot: load done" in the debug log), but the
// bytes only reach the FPGA when this program streams them with `loadf`.
// Without a chip32_vm loader the pack never moves: the bridge sees command
// traffic only, PSRAM stays empty, and the trailer check reads back power-on
// garbage - the static red-screen grid (measured 2026-10-15: wr_match=0,
// allc_seen=1, total bridge writes < 65536 during a "successful" 2 MiB load).
//
// Derived from the agg23 loaders (openfpga-SNES support/loader.asm,
// openfpga-pcengine support/chip32.asm): same slot numbering and host_init
// handshake. The SNES cartridge work (SMC header detection, ROM size
// calculation) is not applicable - a .bin part IS the pack image.

architecture chip32.vm
output "loader.bin", create

constant pack_dataslot = 0

// Host init command: loader done, OS may start the core ("Run")
constant host_init = 0x4002

macro align(size) {
  while (pc() % {size}) {
    db 0
  }
}

// Error vector (0x0)
jp error_handler

// Init vector (0x2)
start:
    // One bitstream, nothing to select - but say so explicitly like the
    // reference loaders do.
    ld r0,#0
    core r0

    // Stream the whole pack into the FPGA at the slot address (0x10000000,
    // data.json). The host paces it at roughly one word per 75 bridge cycles
    // (~4 MB/s); aw_rom drains bridge writes into PSRAM as they arrive and
    // its trailer check releases the VM once the last bytes have landed.
    ld r1,#pack_dataslot
    loadf r1
    jp nz,print_error_and_exit

    // Start core
    ld r0,#host_init
    host r0,r0

exit 0

print_error_and_exit:
    ld r14,#load_err_msg
    printf r14
    exit 1

error_handler:
    ld r14,#fatal_err_msg
    printf r14
    exit 1

load_err_msg:
db "Pack load failed",0
align(2)
fatal_err_msg:
db "Fatal loader error",0
