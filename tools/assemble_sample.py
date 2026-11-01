"""Assemble with the pinned upstream assembler; emit only the RAM image at 0x80000."""
import argparse
import importlib.util
import pathlib
import subprocess
p = argparse.ArgumentParser()
p.add_argument('upstream', type=pathlib.Path)
p.add_argument('source', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
a = p.parse_args()
assert subprocess.check_output(['git', '-C', str(a.upstream), 'rev-parse', 'HEAD'], text=True).strip() == 'd377b03a8ca71f443474fa6c549fd710deaafedf'
spec = importlib.util.spec_from_file_location('assembler', a.upstream/'asm.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
s = a.source.read_text()
m.first_pass(s)
m.second_pass(s)
image = bytes(m.binary_code[0x80000:])
if not 0 < len(image) <= 8192:
    raise SystemExit('RAM image must be 1..8192 bytes')
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_bytes(image)
print(f'{a.output}: {len(image)} bytes, origin 0x80000')
