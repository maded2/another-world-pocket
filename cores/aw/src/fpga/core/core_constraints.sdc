#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# Everything the PLL makes is asynchronous to the bridge and to the two clocks the
# Pocket hands us: the design crosses them only through the gray-pointer FIFOs in
# aw_rom, so there is nothing for the timing analyzer to check between the groups
# and every path it invented would be a false one.
#
# clk_core and clk_psram come from the same PLL and are related by exactly a
# factor of two, but they are grouped apart too: the crossing between them is a
# FIFO with synchronized pointers, which is deliberately not a synchronous path.
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|u_pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|u_pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|u_pll|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk }

# ---------------------------------------------------------------------------
# cellular PSRAM (cram0), the pack's home and the VM's program memory
#
# A generated-clock name has to be spelled the way the tool names it, which is the
# PLL output counter, not the RTL wire: asking for [get_clocks clk_psram] matches
# nothing and every constraint below is silently dropped (Quartus says so in a
# 332049 warning, and says nothing else). Check for those warnings after any
# rename of the PLL instance or its outputs.
set clk_psram_pin [get_clocks {ic|u_pll|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

# The numbers here are not the ones a first reading of the datasheet suggests, and the
# reason is worth having down because a wrong version of them cost a rebuild.
#
# A ZBT part captures what the FPGA drives on the edge *after* the one that launched it:
# the controller puts the address and ADV# out on edge T and the part takes them on edge
# T+1; write data driven during the data phase is taken a cycle later still. So the real
# launch-to-capture budget is a full period plus whatever the forwarded clock arrives late
# by, and the FPGA's own clock-to-pin delay is a small part of it.
#
# set_output_delay against the same clock that launches the data models capture on the
# *same* edge, so it is one whole period pessimistic. That is kept, deliberately: it is
# the difference between a constraint that reports a design which really cannot work and
# one that quietly permits the fitter to fling these paths across the die. The first build
# with real constraints on these pins showed why that matters - a register driving
# cram0_ub_n directly, zero logic levels, 10.1 ns of interconnect and 3.5 ns of output
# buffer: 17.1 ns from the clock edge to the pin, on a 20.2 ns period. That still has
# ~6 ns to spare against the part on the real interface, and would have been reported as
# fine by an unconstrained build. It is now the critical path, so the fitter has to keep
# the psram logic near the cram0 pins.
#
# -max 3.0 is the part's setup time plus a guess at the Pocket's trace and clock-skew
# budget (trace lengths are not published); the margin against the true capture edge is
# the whole second cycle.
#
# There is deliberately no -min here, and that is a lesson worth its own line: a
# *negative* set_output_delay -min is a demand that the data path be at least that long,
# because the tool models capture on the same edge that launched the data. What that asks
# the fitter for, politely, is a long route - which is how a register driving cram0_dq
# directly, zero logic levels, came to be routed through a single interconnect segment
# modelled at 47.2 ns on a 20.2 ns period, in a die small enough that the same register is
# three columns from the pin. Hold on this interface is not an in-FPGA question at all:
# every value is held for a full cycle and the part samples it a cycle later, so what is
# left is clock-to-data skew on traces nobody publishes. Say nothing, rather than say
# something that the fitter will obey in the wrong direction.
set_output_delay -clock $clk_psram_pin -max  3.0 -add_delay [get_ports {cram0_a[*] cram0_adv_n cram0_ce0_n cram0_ce1_n cram0_oe_n cram0_we_n cram0_ub_n cram0_lb_n}]
set_output_delay -clock $clk_psram_pin -max  3.0 -add_delay [get_ports {cram0_dq[*]}]
set_input_delay  -clock $clk_psram_pin -max 12.0 [get_ports {cram0_dq[*]}]
set_input_delay  -clock $clk_psram_pin -min  0.0 [get_ports {cram0_dq[*]}]
set_input_delay  -clock $clk_psram_pin -max 12.0 [get_ports cram0_wait]

# clk_psram is forwarded to the chip as-is; the external part, not the FPGA, is the
# capture point, so there is no setup/hold relationship inside this design to check
# against the pin. The real budget is the set_output_delay window on the signals
# that travel with it.

# Nothing else is needed on these pins, and an earlier version of this file had two things
# that were actively harmful, both recorded here because each looked like help:
#
#   * `set_output_delay -min -6.0` (and later -19.0), intended to say "hold is fine here".
#     Against a same-clock model it says the opposite of what it means: it demands that the
#     data path be at least that *long*, and the fitter obliged - a register driving
#     cram0_dq directly, zero logic levels, routed through one interconnect segment modelled
#     at 47.2 ns, 55.5 ns from the clock edge to a pin three columns away, on a 20.2 ns
#     period. Removing it took the worst path from -43 ns to -5.9 ns.
#   * `set_max_delay 8.0` from the psram registers to the pins, added to fight that route.
#     Once the cause was gone this became the violation itself (it is applied to the data
#     path alone, so it left a budget of 4.6 ns against a 6.96 ns register-to-pin path that
#     is about what this interface should cost). The -max output delay above already bounds
#     what matters, and bounds it in the direction that is wrong to be optimistic about.
#
# Result of the corrected pair: worst path on this clock +3.3 ns, register-to-pin 6.96 ns.
# Which is the number to look at if a future change moves the psram logic away from the
# cram0 pins again.
