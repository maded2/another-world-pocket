#!/bin/bash
cd "$(dirname "$0")"
rm -rf budget; mkdir budget
printf 'QUARTUS_VERSION = "22.1"\nPROJECT_REVISION = "bud"\n' > budget/bud.qpf
{
  echo 'set_global_assignment -name FAMILY "Cyclone V"'
  echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
  echo 'set_global_assignment -name TOP_LEVEL_ENTITY top'
  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
  echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 8'
  echo 'set_global_assignment -name VERILOG_FILE ../shapes.v'
  echo 'set_global_assignment -name VERILOG_FILE ../rom_bank.v'
  echo 'set_global_assignment -name VERILOG_FILE ../whole_budget.v'
} > budget/bud.qsf
echo "=== whole memory budget: map ==="
( cd budget && timeout 500 quartus_map bud.qpf > map.log 2>&1; echo "  map rc=$?" )
echo "=== fit ==="
( cd budget && timeout 500 quartus_fit bud.qpf > fit.log 2>&1; echo "  fit rc=$?" )
cat budget/output_files/bud.fit.summary 2>/dev/null | sed "s/^/  /"
grep -m3 -E "^Error" budget/fit.log budget/map.log 2>/dev/null | sed 's/^/  /'
