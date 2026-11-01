#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
sim_dir=$(mktemp -d /tmp/simpleos-ddr3unit-XXXXXX)
cd "$sim_dir"
"$vivado_bin/xvhdl" --2008 "$tests_dir/../rtl/simpleos_ddr3.vhd" "$tests_dir/migui_model.vhd" "$tests_dir/tb_simpleos_ddr3.vhd"
"$vivado_bin/xelab" tb_simpleos_ddr3 -s simpleos_ddr3_unit
echo "Prepared simulation in $sim_dir"
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_ddr3_unit -R"
