#!/bin/bash
# Compile the PLL probe and report the counters Quartus chose plus the
# frequency it actually achieved (post-fit PLL summary).
cd "$(dirname "$0")"
PLLQIP="$(find "$QUARTUS_ROOTDIR/ip" -name 'altera_pll.qip' 2>/dev/null | head -1)"
echo "altera_pll qip: ${PLLQIP:-<not found>}"

for rev in frac div3; do
  if [ "$rev" = div3 ]; then SRC=../plltest2.v; else SRC=../plltest.v; fi
  rm -rf "pllp_$rev"; mkdir -p "pllp_$rev"
  cat > "pllp_$rev/pllp.qpf" <<QPF
QUARTUS_VERSION = "22.1"
PROJECT_REVISION = "$rev"
QPF
  {
    echo 'set_global_assignment -name FAMILY "Cyclone V"'
    echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
    echo 'set_global_assignment -name TOP_LEVEL_ENTITY plltest'
    echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
    echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 8'
    echo 'set_global_assignment -name EDA_SIMULATION_TOOL "none"'
    echo "set_global_assignment -name VERILOG_FILE $SRC"
    echo 'set_global_assignment -name SDC_FILE ../plltest.sdc'
    echo 'set_location_assignment PIN_V15 -to refclk'   # clk_74a on the Pocket
    if [ -n "$PLLQIP" ]; then
      echo "set_global_assignment -name QIP_FILE $PLLQIP"
    fi
  } > "pllp_$rev/pllp.qsf"

  echo "=== revision $rev ==="
  ( cd "pllp_$rev" && timeout 400 quartus_map pllp.qpf > map.log 2>&1; echo "  map rc=$?" )
  grep -E "^Error" "pllp_$rev/map.log" | head -6
  ( cd "pllp_$rev" && timeout 400 quartus_fit pllp.qpf > fit.log 2>&1; echo "  fit rc=$?" )
  sed -n '/PLL Summary/,/^+$/' "pllp_$rev/output_files/pllp.fit.rpt" 2>/dev/null | head -34
done
