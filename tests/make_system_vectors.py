"""Golden checkpoints for CPU+MMU tests, from the pinned Python CPU."""
import ast
import importlib.util
import pathlib
import subprocess
import sys
from queue import Queue, Empty
from types import SimpleNamespace

source=pathlib.Path(sys.argv[1]).resolve()
target=pathlib.Path(sys.argv[2]).resolve()
requested_mode=sys.argv[3]
c_mode=requested_mode.startswith('c-')
mode=requested_mode[2:] if c_mode else requested_mode
assert mode in ('exceptions','os','tasks')
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()=='d377b03a8ca71f443474fa6c549fd710deaafedf'
target.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('assembler',source/'asm.py')
assembler=importlib.util.module_from_spec(spec); spec.loader.exec_module(assembler)
program=(source/'os.asm').read_text() if mode in ('os','tasks') else (pathlib.Path(__file__).parent/'exceptions.asm').read_text()
if c_mode:
    compiler=pathlib.Path(sys.argv[4]).resolve()
    assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=compiler,text=True).strip()=='a970ef6736a64916c8659be33403d76b1ba4ff6f'
    program=(compiler/'examples/os/simple_os_hybrid.asm').read_text()
assembler.first_pass(program); assembler.second_pass(program)
mem=bytearray(1048576); mem[:len(assembler.binary_code)]=assembler.binary_code
if mode in ('os','tasks'):
    for task in range(4):
        base=0xFFF00+task*16
        mem[base:base+16]=bytes([task]+[255]*7+list(range(8,16)))
assembler_os_prompt=assembler.symbol_table.get('prompt',0)
task_image=None
if mode=='tasks':
    assembler.first_pass((source/'pagefault.asm').read_text())
    assembler.second_pass((source/'pagefault.asm').read_text())
    task_image=bytes(assembler.binary_code)
    # Isolate CPU/MMU behavior from the future host DMA loader.
    mem[0x10000:0x10000+len(task_image)]=task_image
initial=bytes(mem)
(target/'image.hex').write_text(''.join(f'{i:05X} {b:02X}\n' for i,b in enumerate(mem) if b))
tree=ast.parse((source/'emu.py').read_text()); ns={}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef))],type_ignores=[]),'reference','exec'),ns)
names=['R'+str(i) for i in range(10)]+['TP','SP','PC','PT','VT','CR']
regs=dict.fromkeys(names,0); regs.update(SP=0xFF000,PC=0x80000)
queue=Queue(); checkpoints=[]; keys=iter(b'taskexec pagefault.bin\rexit\r' if mode=='tasks' else b'exit\r'); transcript=[]
task_loaded=False; task_irq_sent=False; task_ids=[]
faults=[]
def service(number):
    global task_loaded,task_irq_sent
    # Match do_syscall's fresh page table without changing CPU functions.
    if ns['mmu_flag']:
        pt=regs['PT']&0xFFFFF; ns['pagetable'][:]=mem[pt:pt+16]
    if number==41:
        regs['R8']=ns['pagefault_laddr']&0xFFFFF
        faults.append(regs['R8']); return
    snapshot=[regs[n] for n in names]; result=0; writes=0; inject=0
    if number==10: result=1700000000; writes=1
    elif number==3: result=next(keys); writes=1
    elif number==1:
        string=ns['_read_c_string'](regs['R8']); transcript.append(string)
        if mode=='tasks' and task_loaded and not task_irq_sent and string.endswith('> '):
            for _ in range(7): queue.put(0)
            inject=7; task_irq_sent=True
    elif number==2:
        transcript.append(format(regs['R8'],ns['_read_c_string'](regs['R9'])))
    elif number==23:
        assert mode=='tasks' and regs['R8']==1
        assert ns['_read_c_string'](regs['R9'])=='pagefault.bin'
        mem[0x10000:0x10000+len(task_image)]=task_image
        task_loaded=True
    elif number==30:
        task_ids.append(regs['R8'])
    elif number==0: transcript.append(chr(regs['R8']&255))
    elif number!=20: raise AssertionError(f'unsupported service {number}')
    if mode=='exceptions' and not checkpoints:
        queue.put(0); inject=1
    checkpoints.append((number,snapshot,writes,result,inject))
    if writes: regs['R8']=result
ns.update(registers=regs,registers_name=names,memory=mem,mmu_flag=0,
          pagetable=list(range(16)),page_bases=[i<<16 for i in range(16)],
          vc_switch_queue=Queue(),int_queue=queue,int_flag=SimpleNamespace(value=0),
          Empty=Empty,vc_write=lambda s:None,print_registers=lambda:None,do_syscall=service)
steps=0
def trace(frame,event,arg):
    global steps
    if event=='line' and frame.f_code.co_filename=='reference':
        steps+=1
        assert steps<10000000, f'CPU did not halt: PC={regs["PC"]:X}, checkpoints={len(checkpoints)}, tasks={task_ids}, faults={faults}'
    return trace
sys.settrace(trace)
try: ns['run']()
finally: sys.settrace(None)
if mode=='exceptions':
    assert regs['TP']==1
    assert faults==[0x10000,0x40000,0x50000], faults
    assert mem[0x3FFFE:0x40002]==bytes.fromhex('00012345')
else:
    assert 'Welcome to Simple OS!' in ''.join(transcript)
    assert 'bye.' in ''.join(transcript)
    if mode=='tasks':
        assert task_ids==[1,0],task_ids
        assert faults==[0x23000],faults
        assert '12345' in ''.join(transcript)
        assert regs['TP']==7,regs['TP']
(target/'expected.hex').write_text(''.join(f'{num:05X} '+ ' '.join(f'{v:08X}' for v in snap)+f' {write:X} {result:08X} {inject:X}\n' for num,snap,write,result,inject in checkpoints))
(target/'final-memory.hex').write_text(''.join(f'{i:05X} {b:02X}\n' for i,b in enumerate(mem) if b!=initial[i]))
print(f'{requested_mode}: {len(checkpoints)} checkpoints, faults={faults}, modified bytes={sum(a!=b for a,b in zip(mem,initial))}')
