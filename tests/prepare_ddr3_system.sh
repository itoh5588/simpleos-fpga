#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo 'Usage: prepare_ddr3_system.sh /path/to/pinned/os_book_code exceptions|os|tasks|c-os|c-tasks [/path/to/Simple-C]' >&2
  exit 2
fi
source_dir=$(realpath "$1")
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
sim_dir=$(mktemp -d /tmp/simpleos-ddr3-XXXXXX)
python3 "$tests_dir/make_system_vectors.py" "$source_dir" "$sim_dir" "$2" ${3:+"$3"}
cd "$sim_dir"
"$vivado_bin/xvhdl" --2008 "$tests_dir/../rtl/simpleos_cpu.vhd" "$tests_dir/../rtl/simpleos_mmu.vhd" "$tests_dir/../rtl/simpleos_ddr3.vhd" "$tests_dir/migui_model.vhd" "$tests_dir/tb_simpleos_ddr3_system.vhd"
"$vivado_bin/xelab" tb_simpleos_ddr3_system -s simpleos_ddr3
echo "Prepared simulation in $sim_dir"
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_ddr3 -R"
