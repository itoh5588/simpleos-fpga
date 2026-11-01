# SPDX-License-Identifier: MIT
# Read the whole 16 MiB SPI flash (Micron MT25QL128) of an Arty S7-50 into a
# binary file without changing it. The FPGA is reconfigured with Vivado's
# flash-access bitstream, so its current (JTAG) configuration is lost.
#   vivado -mode batch -source board/readback_flash.tcl -tclargs OUT.bin BOARD_SERIAL
if {$argc != 2} { error "Specify the output file and the board serial number" }
set out [file normalize [lindex $argv 0]]
set serial [lindex $argv 1]
open_hw_manager
connect_hw_server
set targets [get_hw_targets */Digilent/$serial]
if {[llength $targets] != 1} { error "Expected one matching board: $targets" }
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices xc7s50*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mt25ql128-spi-x1_x2_x4}] 0]
set cm [get_property PROGRAM.HW_CFGMEM $dev]
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
set t0 [clock seconds]
readback_hw_cfgmem -force -all -format bin -file $out -hw_cfgmem $cm
puts "READBACK: $out in [expr {[clock seconds] - $t0}] s"
close_hw_target
disconnect_hw_server
close_hw_manager
