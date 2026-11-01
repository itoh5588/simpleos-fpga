"""Run the pinned upstream CPU without terminal setup or helper processes.

Usage: python3 check_reference.py /path/to/os_book_code
Host services are deterministic stubs; this is not a full emulator test.
"""
import ast
import pathlib
import subprocess
import sys

source = pathlib.Path(sys.argv[1]).resolve()
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
assert revision == 'd377b03a8ca71f443474fa6c549fd710deaafedf', revision
tree = ast.parse((source / 'emu.py').read_text())
# Retain the actual CPU functions; omit console/process globals and main.
functions = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef))]
namespace = {}
exec(compile(ast.Module(body=functions, type_ignores=[]), 'upstream-emu-functions', 'exec'), namespace)
import importlib.util
spec = importlib.util.spec_from_file_location('upstream_assembler', source / 'asm.py')
assembler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assembler)
assembler.first_pass((source / 'os.asm').read_text())
assembler.second_pass((source / 'os.asm').read_text())
memory = bytearray(1048576)
memory[:len(assembler.binary_code)] = assembler.binary_code
for task in range(4):
    start = 0xFFF00 + task * 16
    memory[start:start+16] = bytes([task] + [255]*7 + list(range(8,16)))
names = ['R'+str(i) for i in range(10)] + ['TP','SP','PC','PT','VT','CR']
registers = dict.fromkeys(names, 0)
registers.update(SP=0xFF000, PC=0x80000)
from queue import Queue, Empty
from types import SimpleNamespace
output = []
keys = iter(b'exit\r')
calls = []
def syscall(number):
    calls.append(number)
    if number == 10:
        registers['R8'] = 1700000000
    elif number == 1:
        output.append(namespace['_read_c_string'](registers['R8']))
    elif number == 0:
        output.append(chr(registers['R8'] & 255))
    elif number == 3:
        registers['R8'] = next(keys)
    else:
        raise AssertionError(f'unexpected syscall {number}')
namespace.update(registers=registers, registers_name=names, memory=memory,
                 mmu_flag=0, pagetable=list(range(16)), page_bases=[i<<16 for i in range(16)],
                 vc_switch_queue=Queue(), int_queue=Queue(), int_flag=SimpleNamespace(value=0),
                 Empty=Empty, vc_write=output.append, do_syscall=syscall)
steps = 0
def bounded_trace(frame, event, arg):
    global steps
    if event == 'line' and frame.f_code.co_filename == 'upstream-emu-functions':
        steps += 1
        if steps > 500000:
            raise AssertionError('CPU did not halt within execution budget')
    return bounded_trace
sys.settrace(bounded_trace)
try:
    namespace['run']()
finally:
    sys.settrace(None)
text = ''.join(output)
assert 'Welcome to Simple OS!' in text
assert 'bye.' in text
assert 'CPU halted.' in text
assert registers['PT'] == 0xFFF00
assert namespace['mmu_flag'] == 1
print(f'PASS: revision={revision}; OS boot, MMU enable, exit command, HALT')
print(f'SYSCALL sequence: {calls}')
