# Arty S7-50 CPU console: existing COM5 adapter on Pmod JC.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property PACKAGE_PIN R2 [get_ports I_CLK100]
set_property IOSTANDARD SSTL135 [get_ports I_CLK100]
create_clock -name board_clk -period 10.000 [get_ports I_CLK100]
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
# External asynchronous signals terminate at their input synchronizers.
set_false_path -from [get_ports I_RXD] -to [get_cells -hier -filter {NAME =~ *sync1_reg}]
set_false_path -from [get_ports I_RESET]

# JC2 input from 3.3V USB-TTL adapter; idle high.
set_property PULLUP true [get_ports I_RXD]
