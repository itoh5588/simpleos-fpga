#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run every fast simulation and require its PASS line.
# Usage: run_regression.sh /path/to/pinned/os_book_code /path/to/pinned/Simple-C
# (the real-MIG test, prepare_ddr3_mig.sh, takes ~20 minutes and is run separately)
set -uo pipefail
if [[ $# -ne 2 ]]; then echo "Usage: $0 os_book_code Simple-C" >&2; exit 2; fi
book=$(realpath "$1"); compiler=$(realpath "$2")
tests_dir=$(cd -- "$(dirname -- "$0")" && pwd)
vivado_bin=${SIMPLEOS_VIVADO_BIN:-/home/itoh/Xilinx/Vivado/2022.1/bin}
failures=0
run() { # name prepare-command...
  local name=$1; shift
  local out dir snapshot log
  out=$("$@" 2>&1) || { echo "FAIL $name (prepare)"; echo "$out" | grep -E 'ERROR|Error' | head -3; failures=$((failures+1)); return; }
  dir=$(sed -n 's/^Prepared simulation in //p' <<<"$out")
  snapshot=$(sed -n "s/.*xsim' \([a-z0-9_]*\) -R.*/\1/p" <<<"$out")
  log=$(cd "$dir" && "$vivado_bin/xsim" "$snapshot" -R 2>&1)
  if grep -q 'PASS' <<<"$log" && ! grep -qE 'Failure|FATAL' <<<"$log"; then
    echo "ok   $name: $(grep -o 'PASS.*' <<<"$log" | head -1)"
  else
    echo "FAIL $name"; grep -E 'Failure|Error|mismatch' <<<"$log" | head -3; failures=$((failures+1))
  fi
}
run isa bash "$tests_dir/prepare.sh" "$book" "$compiler"
run io bash "$tests_dir/prepare_io.sh"
run ddr3-unit bash "$tests_dir/prepare_ddr3.sh"
run os-core bash "$tests_dir/prepare_os_core.sh" "$book" os
for mode in exceptions os tasks c-tasks; do
  extra=(); [[ $mode == c-* ]] && extra=("$compiler")
  run "system-$mode" bash "$tests_dir/prepare_system.sh" "$book" "$mode" "${extra[@]}"
  run "ddr3-$mode" bash "$tests_dir/prepare_ddr3_system.sh" "$book" "$mode" "${extra[@]}"
done
if log=$(timeout 600 python3 "$tests_dir/test_host.py" "$book" 2>&1) && grep -q '^PASS' <<<"$log"; then
  echo "ok   host: $(grep -o '^PASS.*' <<<"$log")"
else
  echo "FAIL host"; tail -5 <<<"$log"; failures=$((failures+1))
fi
echo "$failures failure(s)"
exit $((failures>0))
