# SPDX-License-Identifier: MIT
# Generate the MIG 7-series IP from board/mig_artys7.prj into build/mig/.
set source_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $source_dir build mig]
file mkdir $out_dir
create_project -in_memory -part xc7s50csga324-1
set_property target_language VHDL [current_project]
create_ip -vlnv [lindex [get_ipdefs xilinx.com:ip:mig_7series:*] 0] \
  -module_name simpleos_mig -dir $out_dir -force
set ip_dir [get_property IP_DIR [get_ips simpleos_mig]]
file copy -force [file join $source_dir board mig_artys7.prj] [file join $ip_dir mig_artys7.prj]
set_property -dict [list CONFIG.XML_INPUT_FILE mig_artys7.prj \
  CONFIG.RESET_BOARD_INTERFACE {Custom} CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
  CONFIG.BOARD_MIG_PARAM {Custom}] [get_ips simpleos_mig]
generate_target all [get_ips simpleos_mig]
puts "MIG IP: [get_property IPDEF [get_ips simpleos_mig]] in $ip_dir"
