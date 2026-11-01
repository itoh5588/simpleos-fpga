#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# UART-protocol test of simpleos_os_core with the MIG model.
# Usage: prepare_os_core.sh /path/to/pinned/os_book_code [os|c-os] [/path/to/Simple-C]
set -euo pipefail
source_dir=$(realpath "$1"); mode=${2:-os}
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
sim_dir=$(mktemp -d /tmp/simpleos-core-XXXXXX)
python3 "$tests_dir/make_system_vectors.py" "$source_dir" "$sim_dir" "$mode" ${3:+"$3"}
cd "$sim_dir"
r=$tests_dir/../rtl
"$vivado_bin/xvhdl" --2008 "$r/simpleos_cpu.vhd" "$r/simpleos_mmu.vhd" "$r/simpleos_uart.vhd" \
  "$r/simpleos_timer.vhd" "$r/simpleos_ddr3.vhd" "$r/simpleos_os_core.vhd" \
  "$tests_dir/migui_model.vhd" "$tests_dir/tb_simpleos_os_core.vhd"
"$vivado_bin/xelab" tb_simpleos_os_core -s simpleos_os_core
echo "Prepared simulation in $sim_dir"
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_os_core -R"
