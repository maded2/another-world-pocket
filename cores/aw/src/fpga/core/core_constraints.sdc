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
# clk_core and clk_psram come from the same PLL (factor five apart), but they are
# grouped apart too: the crossing between them is a FIFO with synchronized
# pointers, which is deliberately not a synchronous path.
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

# The chip runs in async mode: its CLK pin is held low and it samples what the FPGA
# drives according to the protocol's own setup/hold windows (see aw_psram), so there
# is no forwarded clock and no launch-to-capture edge relationship for the analyzer to
# model. What remains, and what these constraints are for, is keeping every
# register-to-pin path short enough that a signal driven on one sequence edge is at the
# pin before the next edge - at 92.8125 MHz (10.77 ns period) that budget is what
# keeps this interface honest, which is exactly why an unconstrained build would
# quietly let the fitter fling these paths across the die and the protocol would break
# in ways the simulator never sees. The frequency itself was chosen around this:
# 123.75 MHz failed setup on exactly these register-to-pin paths (7.4 ns clock-to-pin
# vs an 8.08 ns period), so the sequence runs at 92.8125 - fast enough that a seven-
# cycle WRITE clears t_wp/t_aw/t_dw with a cycle to spare each way, slow enough that
# the physical path fits. The read is no longer the reason for the frequency: it runs
# twelve cycles so that the part sees ~117 ns of access time at its own pins against a
# 70 ns maximum (the seven-cycle version had 63 ns once this fabric's 7.4 ns
# clock-to-pin and the capture's setup were subtracted, and hardware is where that
# shows up, not in this report - STA cannot see it, because there is no clock at the
# part). What these constraints DO protect is that the ~12 ns taken off the read
# budget for pin delays really is pin delay and not the fitter routing a control
# register across the die: keep the 10.0 ns bound, and keep watching for the 332049
# "collection is empty" warning that means they were dropped.
#
# The first build with real constraints on these pins showed why that matters - a register
# driving cram0_ub_n directly, zero logic levels, 10.1 ns of interconnect and 3.5 ns of
# output buffer: 17.1 ns from the clock edge to the pin, on a period that was then twice
# as long. It would have been reported as fine by an unconstrained build; it is the kind
# of path this interface cannot afford at any period near today's 12.12 ns.
#
# The cap is a plain data-delay bound, not an output delay - and that distinction is
# why this file once failed the build. set_output_delay against this clock invents a
# same-edge external capture, and the PLL bookkeeping around it subtracts ~3.8 ns of
# "skew" from every budget (the same phantom that shows up on a clock-less set_max_delay
# endpoint; see the 12.0 ns note below); at 12.12 ns period that made physically fine paths fail
# (measured: 6.97 ns clock-to-pin against an effective 5.3 ns). There is no external
# capture in async mode, so set_max_delay says what is actually required: a value
# changed on one edge settles at the pin before the next edge can matter. Ten ns keeps
# ~2 ns of margin inside the period and forces the fitter to keep the psram logic near
# the cram0 pins - short paths, held values (every pin value is stable for at least a
# full cycle before any protocol transition that depends on it), and nothing more.
#
# There is deliberately no -min here, and that is a lesson worth its own line: a
# *negative* set_output_delay -min is a demand that the data path be at least that long,
# because the tool models capture on the same edge that launched the data. What that asks
# the fitter for, politely, is a long route - which is how a register driving cram0_dq
# directly, zero logic levels, came to be routed through a single interconnect segment
# modelled at 47.2 ns on a period that was then twice as long, in a die small enough that
# the same register is three columns from the pin. Hold on this interface is not an
# in-FPGA question at all: every value is held for at least a full cycle before any
# transition that depends on it, so what is left is clock-to-data skew on traces nobody
# publishes. Say nothing, rather than say something that the fitter will obey in the wrong
# direction.
#
# The input delays on cram0_dq model the protocol, not a clock relationship: the part's
# DQ transitions are caused by OE#/tCO/tOE events that this design launches, so they land
# mid-cycle relative to this clock and never race a sampling edge. -min 10.7 (one period
# at 92.8125 MHz) says exactly that - without it the hold check assumes external data
# could change on the very edge rd_q samples it, which is false by construction and
# failed the build with spurious ~1 ns hold violations.
# The sources are the controller's own registers: a clock-based -from still makes the
# tool invent a pseudo capture clock at the port and subtract ~3.5 ns of PLL bookkeeping
# "skew" that has no physical meaning for an async pin (this Quartus Lite also rejects
# -datapath_only), and a register-to-port bound is a pure data-delay bound, which is
# what is actually required.
#
# Getting this to match anything took two fixes, and the history matters because the
# constraint silently did nothing for many builds while every report looked clean:
#
#   * get_pins names pins *of* instances, not the registers driving them; the objects
#     wanted here are registers (get_registers);
#   * the hierarchy was spelled from core_top down, but the netlist's top entity is
#     apf_top (|apf_top|core_top:ic|aw_rom:u_rom|aw_psram:u_psram), so the path never
#     matched. A leading wildcard matches whatever the APF wrapper ends up called.
#
# Both were reported, and ignored: TimeQuest said "Ignored set_max_delay ... Argument
# <from> is an empty collection" (332049) in every build up to this one. Grepping the
# build log for 332049 after any SDC or rename change is now part of the gate:
# scripts/check_build.py fails the build when the log carries one. (An in-SDC guard was
# tried and is not available here - Quartus Lite 22.1 has no size_of_collection in the
# SDC context, and a bad command does not merely skip the guard, it rejects the whole
# file: "Critical Warning (332008): Read_sdc failed due to errors", clock groups and all.
# Check the SDC by its effects in the report, never by trusting it to load.)
set psram_out_regs [get_registers {*aw_psram:u_psram|*}]
# 12.0 ns, and the number is not the one it looks like. An endpoint with no capture
# clock (an output pin: the part is not clocked, so TimeQuest has no latch edge) gets a
# phantom -3.58 ns of "clock skew" subtracted from the bound, so a 12.0 ns bound really
# demands about 8.4 ns of register-to-pin. That is the number worth asking for: it is
# the pin-delay allowance the twelve-cycle read budget is built on (aw_psram subtracts
# ~12 ns for clock-to-pin, traces and capture setup before it claims the part got 117 ns
# of tAA), and it still rules out the pathological case this constraint exists for - the
# time a register driving cram0_dq directly, zero logic levels, was routed through one
# interconnect segment modelled at 47.2 ns.
#
# 10.0 was tried first and is not achievable: it asks for 6.4 ns of real path against a
# fabric that takes ~7.2 ns to get from a register to these particular pins (measured on
# the first build where the constraint actually applied - dq_out[2] -> cram0_dq[2],
# 7.175 ns data path, -0.757 ns slack). A bound the physics cannot meet is not a
# constraint, it is a permanent violation that trains you to ignore the report.
set_max_delay 12.0 -from $psram_out_regs -to [get_ports {cram0_a[*] cram0_adv_n cram0_ce0_n cram0_ce1_n cram0_oe_n cram0_we_n cram0_ub_n cram0_lb_n}]
set_max_delay 12.0 -from $psram_out_regs -to [get_ports {cram0_dq[*]}]
set_input_delay  -clock $clk_psram_pin -max 10.7 [get_ports {cram0_dq[*]}]
set_input_delay  -clock $clk_psram_pin -min 10.7 [get_ports {cram0_dq[*]}]
set_input_delay  -clock $clk_psram_pin -max 12.0 [get_ports cram0_wait]

# clk_psram (92.8125 MHz) is the PSRAM *sequence* clock; the chip's own CLK pin is held
# low, so there is no setup/hold relationship inside this design to check against any
# pin. The real budget is the set_output_delay window above.

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
