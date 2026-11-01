# vivado -mode batch -source build_io.tcl -tclargs /tmp/output-directory
if {$argc != 1} { error "Specify an output directory" }
set source_dir [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file normalize [lindex $argv 0]]
file mkdir $output_dir
create_project -in_memory -part xc7s50csga324-1
foreach name {simpleos_uart simpleos_io_demo} {
  read_vhdl -vhdl2008 [file join $source_dir rtl ${name}.vhd]
}
read_xdc [file join $source_dir board artys7_io.xdc]
synth_design -top simpleos_io_demo -part xc7s50csga324-1
opt_design
place_design
route_design
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $output_dir timing.rpt]
report_drc -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir simpleos_io_demo.dcp]
# Reject timing violations instead of silently publishing the test image.
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
foreach path [concat $setup_paths $hold_paths] {
  if {[get_property SLACK $path] < 0} { error "Timing violation" }
}
write_bitstream -force [file join $output_dir simpleos_io_demo.bit]
