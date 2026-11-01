# SPDX-License-Identifier: MIT
# Write a bitstream to the Arty S7-50 SPI flash (Micron MT25QL128), verify it
# and boot the FPGA from it. Booting from flash at power-up needs the MODE
# jumper (JP1). Read the old contents first with board/readback_flash.tcl.
#   vivado -mode batch -source board/flash.tcl -tclargs BITSTREAM BOARD_SERIAL
# Also used to put another design back (e.g. the w11 standalone .bit).
if {$argc != 2} { error "Specify a bitstream and the board serial number" }
set bit [file normalize [lindex $argv 0]]
set serial [lindex $argv 1]
if {![file exists $bit]} { error "Missing bitstream: $bit" }
set mcs "[file rootname $bit].mcs"
# The bitstreams use the default SPI_BUSWIDTH = 1.
write_cfgmem -force -format mcs -size 16 -interface SPIx1 -loadbit "up 0x0 $bit" -file $mcs
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
set_property PROGRAM.ADDRESS_RANGE          {use_file} $cm
set_property PROGRAM.FILES                  [list $mcs] $cm
set_property PROGRAM.PRM_FILE               {}         $cm
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cm
set_property PROGRAM.BLANK_CHECK            0 $cm
set_property PROGRAM.ERASE                  1 $cm
set_property PROGRAM.CFG_PROGRAM            1 $cm
set_property PROGRAM.VERIFY                 1 $cm
set_property PROGRAM.CHECKSUM               0 $cm
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
set t0 [clock seconds]
program_hw_cfgmem -hw_cfgmem $cm
puts "FLASHED: $bit in [expr {[clock seconds] - $t0}] s (erase, program, verify)"
boot_hw_device $dev
after 8000
refresh_hw_device $dev
puts "DONE_PIN: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
disconnect_hw_server
close_hw_manager
