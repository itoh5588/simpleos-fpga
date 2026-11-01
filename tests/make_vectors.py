"""Build base-ISA vectors using unmodified upstream execution functions."""
import ast
import importlib.util
import pathlib
import subprocess
import sys
from queue import Queue, Empty
from types import SimpleNamespace

source = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2]).resolve()
target.mkdir(parents=True, exist_ok=True)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip() == 'd377b03a8ca71f443474fa6c549fd710deaafedf'
spec = importlib.util.spec_from_file_location('assembler', source/'asm.py')
assembler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assembler)
program = (pathlib.Path(__file__).parent/'base.asm').read_text()
if len(sys.argv) > 3:
    compiler = pathlib.Path(sys.argv[3]).resolve()
    assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=compiler,text=True).strip() == 'a970ef6736a64916c8659be33403d76b1ba4ff6f'
    subprocess.run([sys.executable, str(compiler/'cc.py'), str(compiler/'samples/test_bitops.c')], cwd=compiler, check=True)
    generated = (compiler/'samples/test_bitops.asm').read_text()
    # Call a genuine compiler-generated C function from the base-ISA harness.
    pos = program.rfind('HALT')
    program = program[:pos] + 'CALLI main\nSYSCALL 20\nHALT\n' + generated
assembler.first_pass(program)
assembler.second_pass(program)
image = assembler.binary_code
(target/'program.hex').write_text(''.join(f'{b:02X}\n' for b in image[0x80000:]))
tree = ast.parse((source/'emu.py').read_text())
ns = {}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef))],type_ignores=[]),'reference','exec'),ns)
names = ['R'+str(i) for i in range(10)] + ['TP','SP','PC','PT','VT','CR']
regs = dict.fromkeys(names,0)
regs.update(SP=0xFF000,PC=0x80000)
mem = bytearray(1048576)
mem[:len(image)] = image
checkpoints = []
def syscall(number):
    assert number == 20
    checkpoints.append([regs[n] for n in names])
ns.update(registers=regs,registers_name=names,memory=mem,mmu_flag=0,
          pagetable=list(range(16)),page_bases=[i<<16 for i in range(16)],
          vc_switch_queue=Queue(),int_queue=Queue(),int_flag=SimpleNamespace(value=0),
          Empty=Empty,vc_write=lambda s:None,print_registers=lambda:None,do_syscall=syscall)
steps=0
def trace(frame,event,arg):
    global steps
    if event=='line' and frame.f_code.co_filename=='reference':
        steps+=1
        assert steps < 100000, 'reference failed to halt'
    return trace
sys.settrace(trace)
try: ns['run']()
finally: sys.settrace(None)
expected_count = 21 if len(sys.argv)>3 else 20
assert len(checkpoints)==expected_count, len(checkpoints)
if expected_count==21:
    assert checkpoints[-1][0]==189, checkpoints[-1][0]
(target/'expected.hex').write_text(''.join(' '.join(f'{v:08X}' for v in row)+'\n' for row in checkpoints))
print(f'Generated {len(checkpoints)} checkpoints / {len(checkpoints)*16} register comparisons')
