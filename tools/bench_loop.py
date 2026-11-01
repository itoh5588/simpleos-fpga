# SPDX-License-Identifier: MIT
"""Instruction rate of a simple loop on emu.py or on the FPGA.

The loop runs OUTER x 524288 iterations of DEC R0 / JPNZI (two instructions
each) and then HALTs. With --mmu the MMU is enabled first (identity page
table at 0xFFF00, CR = 0x80000000), as when the OS runs its tasks.

  python3 bench_loop.py --book OS_BOOK_CODE --emu [--outer 2] [--mmu]
  python bench_loop.py --book OS_BOOK_CODE --port COM5 [--outer 40] [--mmu] [--baud 3000000]
"""
import argparse
import ast
import importlib.util
import pathlib
import queue
import sys
import time
from queue import Empty
from types import SimpleNamespace

INNER = 0x80000
REGISTER_NAMES = ['R0', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9',
                  'TP', 'SP', 'PC', 'PT', 'VT', 'CR']


def program(book, outer, mmu):
    setup = ("        MOVI    PT, 0xFFF00\n"
             "        MOVI    R2, 0x8000\n"
             "        MULI    R2, 0x10000\n"
             "        MOV     CR, R2\n") if mmu else ""
    source = (f"        .ADDR   0x80000\n{setup}"
              f"        MOVI    R1, {outer}\n"
              f"outer:  MOVI    R0, {INNER:#x}\n"
              "inner:  DEC     R0\n"
              "        JPNZI   inner\n"
              "        DEC     R1\n"
              "        JPNZI   outer\n"
              "        HALT\n")
    spec = importlib.util.spec_from_file_location('book_asm', book / 'asm.py')
    asm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asm)
    asm.first_pass(source)
    asm.second_pass(source)
    instructions = outer * (2 * INNER + 3) + 2 + (4 if mmu else 0)
    return bytes(asm.binary_code)[0x80000:], instructions


def run_emu(book, image):
    tree = ast.parse((book / 'emu.py').read_text(encoding='utf-8'))
    body = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))]
    ns = {'sys': sys, 'time': time, 'Empty': Empty}
    exec(compile(ast.Module(body=body, type_ignores=[]), 'emu', 'exec'), ns)
    memory = bytearray(1 << 20)
    memory[0x80000:0x80000 + len(image)] = image
    memory[0xFFF00:0xFFF10] = bytes(range(16))
    regs = dict.fromkeys(REGISTER_NAMES, 0)
    regs.update(SP=0xFF000, PC=0x80000)
    ns.update(registers=regs, registers_name=REGISTER_NAMES, memory=memory, mmu_flag=0,
              pagetable=list(range(16)), page_bases=[i << 16 for i in range(16)], pagefault_laddr=0,
              vc_switch_queue=queue.Queue(), int_queue=queue.Queue(), int_flag=SimpleNamespace(value=0),
              Empty=Empty, vc_write=lambda s: None, print_registers=lambda: None)
    t = time.perf_counter()
    ns['run']()
    elapsed = time.perf_counter() - t
    return elapsed, regs['R0'], regs['R1']


def run_fpga(port_name, baud, image):
    import serial
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import simpleos_host
    port = serial.Serial(port_name, baud, timeout=0.05)
    try:
        link = simpleos_host.Link(port)
        link.reset()
        link.write(0x80000, image)
        link.write(0xFFF00, bytes(range(16)))
        t = time.perf_counter()
        link.start()
        event = None
        while event is None:
            event = link.event()
        elapsed = time.perf_counter() - t
        if event != ('H', 0):
            raise SystemExit(f'unexpected stop: {event}')
        regs = link.registers()
        return elapsed, regs[0], regs[1]
    finally:
        port.close()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--book', type=pathlib.Path, required=True, help='os_book_code (asm.py, emu.py)')
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument('--emu', action='store_true', help="run on the book's emu.py CPU")
    target.add_argument('--port', help='run on the FPGA through this serial port')
    p.add_argument('--outer', type=int, help='outer loop count (default: 2 on emu.py, 40 on the FPGA)')
    p.add_argument('--mmu', action='store_true', help='enable the MMU before the loop')
    p.add_argument('--baud', type=int, default=3000000)
    a = p.parse_args()
    outer = a.outer or (2 if a.emu else 40)
    image, instructions = program(a.book, outer, a.mmu)
    if a.emu:
        elapsed, r0, r1 = run_emu(a.book, image)
        where = 'emu.py'
    else:
        elapsed, r0, r1 = run_fpga(a.port, a.baud, image)
        where = 'FPGA'
    if r0 or r1:
        raise SystemExit(f'loop did not finish: R0={r0} R1={r1}')
    print(f"{where}{' (MMU on)' if a.mmu else ''}: {instructions} instructions in {elapsed:.2f} s"
          f" = {instructions / elapsed / 1e6:.3f} M instructions/s")


if __name__ == '__main__':
    main()
