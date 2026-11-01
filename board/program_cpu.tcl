# vivado -mode batch -source program_cpu.tcl -tclargs BITSTREAM BOARD_SERIAL
if {$argc != 2} {error "Specify a bitstream and the connected board serial number"}
set bitstream [file normalize [lindex $argv 0]]
if {![file exists $bitstream]} {error "Missing bitstream: $bitstream"}
set serial [lindex $argv 1]
open_hw_manager
connect_hw_server
set targets [get_hw_targets */Digilent/$serial]
if {[llength $targets] != 1} {error "Expected one matching board: $targets"}
open_hw_target [lindex $targets 0]
set devices [get_hw_devices]
if {[llength $devices] != 1 || ![string match xc7s50* [lindex $devices 0]]} {
  error "Expected Arty S7-50 XC7S50: $devices"
}
set device [lindex $devices 0]
set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
refresh_hw_device $device
puts "PROGRAMMED_DEVICE: $device"
puts "STATUS: [get_property REGISTER.CONFIG_STATUS $device]"
close_hw_target
disconnect_hw_server
close_hw_manager
