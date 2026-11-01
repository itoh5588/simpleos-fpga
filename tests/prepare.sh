#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'Usage: prepare.sh /path/to/pinned/os_book_code [/path/to/Simple-C]' >&2
  exit 2
fi
source_dir=$(realpath "$1")
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
sim_dir=$(mktemp -d /tmp/simpleos-base-XXXXXX)
python3 "$tests_dir/make_vectors.py" "$source_dir" "$sim_dir" ${2:+"$2"}
cd "$sim_dir"
"$vivado_bin/xvhdl" --2008 "$tests_dir/../rtl/simpleos_cpu.vhd" "$tests_dir/tb_simpleos_cpu.vhd"
"$vivado_bin/xelab" tb_simpleos_cpu -s simpleos_base
echo "Prepared simulation in $sim_dir"
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_base -R"
