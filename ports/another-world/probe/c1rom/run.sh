#!/bin/bash
# Does a bridge-written / VM-read dual-clock ROM infer M9K block RAM cleanly,
# and at what cost?  quartus_map reports the block memory bits.
cd "$(dirname "$0")"
for v in 160; do
  rm -rf "c1_$v"; mkdir -p "c1_$v"
  printf 'QUARTUS_VERSION = "22.1"\nPROJECT_REVISION = "c1"\n' > "c1_$v/c1.qpf"
  {
    echo 'set_global_assignment -name FAMILY "Cyclone V"'
    echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
    echo 'set_global_assignment -name TOP_LEVEL_ENTITY top'
    echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
    echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 8'
    echo 'set_global_assignment -name VERILOG_FILE ../rom_bank.v'
    echo "set_global_assignment -name VERILOG_FILE ../top_$v.v"
  } > "c1_$v/c1.qsf"
  echo "=== ${v} KB bank ==="
  ( cd "c1_$v" && timeout 400 quartus_map c1.qpf > map.log 2>&1; echo "  map rc=$?" )
  grep -E "Total block memory bits|Total RAM Blocks|Total logic elements|Total registers" \
      "c1_$v/output_files/c1.map.summary" 2>/dev/null | sed 's/;/ = /;s/^/  /'
  grep -m2 -E "^Error" "c1_$v/map.log" | sed 's/^/  /'
  grep -m2 -iE "M9K|m9k" "c1_$v/output_files/c1.map.rpt" 2>/dev/null | head -2 | sed 's/^/  /'
done
