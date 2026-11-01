#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
  echo 'Usage: prepare_board.sh /path/to/pinned/os_book_code' >&2
  exit 2
fi
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
sim_dir=$(mktemp -d /tmp/simpleos-board-XXXXXX)
python3 "$tests_dir/../tools/assemble_sample.py" "$1" "$tests_dir/../samples/hello_led.asm" "$sim_dir/sample.bin"
python3 - "$sim_dir" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
(p/'sample.hex').write_text(''.join(f'{x:02X}\n' for x in (p/'sample.bin').read_bytes()))
PY
cd "$sim_dir"
"$vivado_bin/xvhdl" --2008 "$tests_dir/../rtl/simpleos_cpu.vhd" "$tests_dir/../rtl/simpleos_uart.vhd" "$tests_dir/../rtl/simpleos_board.vhd" "$tests_dir/tb_simpleos_board.vhd"
"$vivado_bin/xelab" tb_simpleos_board -s simpleos_board_test
echo "Run separately: cd '$sim_dir' && '$vivado_bin/xsim' simpleos_board_test -R"
