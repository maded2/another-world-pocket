#!/bin/bash
# Four framebuffer shapes x 4 instances (the design has 4 framebuffers).
cd "$(dirname "$0")"
for v in a b c d e; do
  rm -rf rs_$v; mkdir -p rs_$v
  cat > rs_$v/rs.qpf <<QPF
QUARTUS_VERSION = "22.1"
PROJECT_REVISION = "rs"
QPF
  cat > rs_$v/rs.qsf <<QSF
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CEBA4F23C8
set_global_assignment -name TOP_LEVEL_ENTITY top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 8
set_global_assignment -name EDA_SIMULATION_TOOL "none"
set_global_assignment -name VERILOG_FILE ../shapes.v
set_global_assignment -name VERILOG_FILE ../top_$v.v
QSF
  echo "=== variant $v ==="
  ( cd rs_$v && timeout 420 quartus_map rs.qpf -c rs > map.log 2>&1 ) ; rc=$?
  if [ $rc -eq 124 ]; then echo "  TIMEOUT (>420s)"; continue; fi
  grep -E "Total block memory bits|Total RAM Blocks|Total logic elements|Total registers" rs_$v/output_files/rs.map.summary 2>/dev/null | sed 's/;/ = /;s/^/  /'
  grep -cE "^Error" rs_$v/map.log | sed 's/^/  errors: /'
  grep -m1 -oE "Error \([0-9]+\)[^\n]{0,110}" rs_$v/map.log | sed 's/^/  first: /'
done
