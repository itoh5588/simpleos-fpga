# SPDX-License-Identifier: MIT
# Build the DDR3 Simple OS bitstream for Arty S7-50.
#   vivado -mode batch -source board/gen_mig.tcl        (once)
#   vivado -mode batch -source board/build_os.tcl -tclargs build/os
# No bitstream is written when setup or hold timing fails.
if {$argc != 1} { error "Specify an output directory" }
set source_dir [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file normalize [lindex $argv 0]]
set xci [file join $source_dir build mig simpleos_mig simpleos_mig.xci]
if {![file exists $xci]} { error "MIG not generated; run board/gen_mig.tcl first" }
file mkdir $output_dir
cd $output_dir
create_project -in_memory -part xc7s50csga324-1
set_property target_language VHDL [current_project]
read_ip $xci
set_property generate_synth_checkpoint false [get_files $xci]
generate_target all [get_files $xci]
foreach name {simpleos_uart simpleos_timer simpleos_cpu simpleos_mmu simpleos_ddr3 simpleos_os_core simpleos_os_board} {
  read_vhdl -vhdl2008 [file join $source_dir rtl ${name}.vhd]
}
read_xdc [file join $source_dir board artys7_os.xdc]
synth_design -top simpleos_os_board -part xc7s50csga324-1
opt_design
place_design
route_design
set optimize_timing 0
foreach path [concat [get_timing_paths -delay_type max -max_paths 1] [get_timing_paths -delay_type min -max_paths 1]] {
  if {[get_property SLACK $path] < 0} {set optimize_timing 1}
}
if {$optimize_timing} {
  phys_opt_design -directive AggressiveExplore
  route_design -directive Explore
}
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $output_dir timing.rpt]
report_clocks -file [file join $output_dir clocks.rpt]
report_drc -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir simpleos_os_board.dcp]
foreach path [concat [get_timing_paths -delay_type max -max_paths 1] [get_timing_paths -delay_type min -max_paths 1]] {
  if {[get_property SLACK $path] < 0} { error "Timing violation" }
}
write_bitstream -force [file join $output_dir simpleos_os_board.bit]
