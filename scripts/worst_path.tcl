# Report the worst failing paths, which the plain .sta.rpt summarises but does not list.
#   ./docker/run.sh sh -c "cd cores/aw/src/fpga && quartus_sta -t /work/scripts/worst_path.tcl"
load_package flow
project_open aw -current
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -npaths 4 -detail full_path -file /work/build/aw_worst.txt
project_close
