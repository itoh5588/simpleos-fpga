#!/usr/bin/env bash
set -euo pipefail
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
sim_dir=$(mktemp -d /tmp/simpleos-io-XXXXXX)
cd "$sim_dir"
"$vivado_bin/xvhdl" --2008 "$tests_dir/../rtl/simpleos_timer.vhd" "$tests_dir/../rtl/simpleos_uart.vhd" "$tests_dir/../rtl/simpleos_io_demo.vhd" "$tests_dir/tb_simpleos_io.vhd"
"$vivado_bin/xelab" tb_simpleos_io -s simpleos_io
echo "Prepared simulation in $sim_dir"
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_io -R"
