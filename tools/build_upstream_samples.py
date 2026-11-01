"""Wrap unmodified upstream test1/test2 routines for the physical RAM CPU."""
import argparse
import pathlib
import subprocess
import sys
p = argparse.ArgumentParser()
p.add_argument('upstream', type=pathlib.Path)
p.add_argument('--repeat', action='store_true')
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
build = root/'build'
build.mkdir(exist_ok=True)
header = '''.ADDR 0x80000
MOVI R8, banner
SYSCALL 1
MOVI R8, 13
SYSCALL 0
MOVI R8, 10
SYSCALL 0
CALLI upstream_test1
SBTI R0, 100
JPNZI failure
MOVI R8, test1_message
SYSCALL 1
CALLI print_uint
CALLI newline
CALLI upstream_test2
SBTI R0, 55
JPNZI failure
MOVI R8, test2_message
SYSCALL 1
CALLI print_uint
CALLI newline
MOVI R8, passed
SYSCALL 1
CALLI newline
HALT
failure:
MOVI R8, failed
SYSCALL 1
CALLI newline
HALT
print_uint:
MOV R8, R0
MODI R8, 10
PUSH R8
DIVI R0, 10
SBTI R0, 0
JPZI emit_digit
CALLI print_uint
emit_digit:
POP R8
ADDI R8, 48
SYSCALL 0
RET
newline:
MOVI R8, 13
SYSCALL 0
MOVI R8, 10
SYSCALL 0
RET
banner:
.STRING "Upstream os_book_code samples"
test1_message:
.STRING "test1 result = "
test2_message:
.STRING "test2 sum 1..10 = "
passed:
.STRING "PASS - both upstream results matched"
failed:
.STRING "FAIL - upstream result mismatch"
upstream_test1:
'''
if a.repeat:
    header = header.replace('.ADDR 0x80000\n', '.ADDR 0x80000\nrun_samples:\n', 1)
    header = header.replace('CALLI newline\nHALT\nfailure:', '''CALLI newline
MOVI R4, 5
sample_delay_outer:
MOVI R0, 0xFFFFF
sample_delay:
DEC R0
JPNZI sample_delay
DEC R4
JPNZI sample_delay_outer
JPI run_samples
failure:''')
name = 'upstream_tests_repeat' if a.repeat else 'upstream_tests'
image = build/(name+'.asm')
image.write_text(header + (a.upstream/'test1.asm').read_text() + '\nupstream_test2:\n' + (a.upstream/'test2.asm').read_text())
subprocess.run([sys.executable, str(root/'tools/assemble_sample.py'), str(a.upstream), str(image), str(build/(name+'.bin'))], check=True)
