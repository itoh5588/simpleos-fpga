#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapter test against the generated MIG and its Micron DDR3 model.
# Generate the MIG first: vivado -mode batch -source board/gen_mig.tcl
set -euo pipefail
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
mig=$tests_dir/../build/mig/simpleos_mig/simpleos_mig
if [[ ! -d $mig/user_design/rtl ]]; then
  echo "MIG not generated; run: $vivado_bin/vivado -mode batch -source board/gen_mig.tcl" >&2
  exit 2
fi
rtl=$mig/user_design/rtl
sim_dir=$(mktemp -d /tmp/simpleos-mig-XXXXXX)
cd "$sim_dir"
"$vivado_bin/xvlog" -sv -i "$mig/example_design/sim" "$mig/example_design/sim/ddr3_model.sv"
"$vivado_bin/xvlog" $(find "$rtl" -name '*.v' | sort) "$vivado_bin/../data/verilog/src/glbl.v"
# Simulation variant of the MIG core: SIMULATION=TRUE, SIM_BYPASS_INIT_CAL=FAST.
"$vivado_bin/xvhdl" "$rtl/phy/mig_7series_v4_2_ddr_phy_top.vhd" "$rtl/simpleos_mig_mig_sim.vhd" "$rtl/simpleos_mig.vhd"
"$vivado_bin/xvhdl" --2008 "$tests_dir/../rtl/simpleos_ddr3.vhd" "$tests_dir/tb_simpleos_ddr3_mig.vhd"
"$vivado_bin/xelab" tb_simpleos_ddr3_mig glbl -L unisims_ver -L unisim -L secureip -s simpleos_ddr3_mig
echo "Prepared simulation in $sim_dir"
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_ddr3_mig -R"
