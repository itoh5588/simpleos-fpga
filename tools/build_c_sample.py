"""Compile the checked-in Simple-C sample and wrap main with a hardware entry."""
import argparse
import pathlib
import shutil
import subprocess
import sys
p = argparse.ArgumentParser()
p.add_argument('compiler', type=pathlib.Path)
p.add_argument('upstream', type=pathlib.Path)
a = p.parse_args()
compiler = a.compiler.resolve()
assert subprocess.check_output(['git', '-C', str(compiler), 'rev-parse', 'HEAD'], text=True).strip() == 'a970ef6736a64916c8659be33403d76b1ba4ff6f'
root = pathlib.Path(__file__).resolve().parents[1]
build = root/'build'
build.mkdir(exist_ok=True)
source = build/'hello_c.c'
shutil.copyfile(root/'samples/hello_c.c', source)
subprocess.run([sys.executable, str(compiler/'cc.py'), str(source)], check=True)
assembly = build/'hello_c.asm'
assembly.write_text('.ADDR 0x80000\nCALLI main\nMOV R8, R0\nSYSCALL 50\nHALT\n' + assembly.read_text())
subprocess.run([sys.executable, str(root/'tools/assemble_sample.py'), str(a.upstream), str(assembly), str(build/'hello_c.bin')], check=True)
