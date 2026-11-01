# SPDX-License-Identifier: MIT
# Arty S7-50 Simple OS on DDR3. DDR3 pins and MIG timing come from the MIG IP.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
# 12 MHz oscillator on F14 (the R2 100 MHz clock region's MMCM is used by the MIG).
set_property PACKAGE_PIN F14 [get_ports I_CLK12]
set_property IOSTANDARD LVCMOS33 [get_ports I_CLK12]
create_clock -name board_clk -period 83.333 [get_ports I_CLK12]
# BTN0, UART on Pmod JC (JC1 = FPGA TX, JC2 = FPGA RX, JC5 = GND), LED0..3.
set_property PACKAGE_PIN G15 [get_ports I_RESET]
set_property PACKAGE_PIN V16 [get_ports I_RXD]
set_property PACKAGE_PIN U15 [get_ports O_TXD]
set_property PACKAGE_PIN E18 [get_ports {O_LED[0]}]
set_property PACKAGE_PIN F13 [get_ports {O_LED[1]}]
set_property PACKAGE_PIN E13 [get_ports {O_LED[2]}]
set_property PACKAGE_PIN H15 [get_ports {O_LED[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {I_RESET I_RXD O_TXD O_LED[*]}]
set_property DRIVE 8 [get_ports {O_TXD O_LED[*]}]
set_property SLEW SLOW [get_ports {O_TXD O_LED[*]}]
set_property PULLUP true [get_ports I_RXD]
# Asynchronous inputs end at their synchronizers; outputs are slow/static.
set_false_path -from [get_ports I_RXD] -to [get_cells -hier -filter {NAME =~ *sync1_reg || NAME =~ *line1_reg}]
set_false_path -from [get_ports I_RESET]
set_false_path -to [get_ports {O_TXD O_LED[*]}]
