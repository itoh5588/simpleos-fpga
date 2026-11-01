# SPDX-License-Identifier: MIT
"""Board-free test of tools/simpleos_host.py.

A fake FPGA runs the book's own emu.py CPU/MMU (unchanged functions) behind
the same byte protocol as rtl/simpleos_os_core.vhd: SYSCALLs other than 41
are sent to the host as 'S' and the CPU waits for 'C'; W/R/G/Z/X/BREAK are
served from a 1 MiB memory that starts with random contents. The real host
code drives it with typed commands and its console output is checked.

  python3 tests/test_host.py /path/to/pinned/os_book_code
"""
import ast
import importlib.util
import io
import os
import pathlib
import queue
import re
import sys
import tempfile
import threading
import time
from queue import Empty
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import simpleos_host  # noqa: E402

BREAK = object()


class FakePort:
    """Host side of a serial line to the fake FPGA."""

    def __init__(self):
        self.to_device = queue.Queue()
        self.to_host = queue.Queue()

    def read(self, n):
        out = bytearray()
        try:
            out.append(self.to_host.get(timeout=0.05))
            while len(out) < n:
                out.append(self.to_host.get_nowait())
        except Empty:
            pass
        return bytes(out)

    def write(self, data):
        for b in data:
            self.to_device.put(b)

    def send_break(self, duration):
        self.to_device.put(BREAK)

    def reset_input_buffer(self):
        while True:
            try:
                self.to_host.get_nowait()
            except Empty:
                return

    def close(self):
        pass


class FakeFpga(threading.Thread):
    def __init__(self, port, emu_path):
        super().__init__(daemon=True)
        self.port = port
        tree = ast.parse(pathlib.Path(emu_path).read_text(encoding='utf-8'))
        body = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))]
        ns = {'sys': sys, 'time': time, 'Empty': Empty}
        exec(compile(ast.Module(body=body, type_ignores=[]), 'reference', 'exec'), ns)
        self.ns = ns
        self.mem = bytearray(os.urandom(1 << 20))
        self.regs = {}
        self.int_flag = SimpleNamespace(value=0)
        self.int_queue = queue.Queue()
        self.halted = threading.Event()
        self.unexpected = []

    # byte I/O from the device side
    def get(self):
        b = self.port.to_device.get()
        if b is BREAK:
            raise ConnectionResetError('BREAK')
        return b

    def get_n(self, n):
        return bytes(self.get() for _ in range(n))

    def put(self, data):
        for b in data:
            self.port.to_host.put(b)

    def reset_cpu(self):
        names = simpleos_host.REGISTER_NAMES
        self.regs.clear()
        self.regs.update(dict.fromkeys(names, 0), SP=0xFF000, PC=0x80000)
        self.ns.update(registers=self.regs, registers_name=names, memory=self.mem, mmu_flag=0,
                       pagetable=list(range(16)), page_bases=[i << 16 for i in range(16)],
                       pagefault_laddr=0, vc_switch_queue=queue.Queue(), int_queue=self.int_queue,
                       int_flag=self.int_flag, Empty=Empty, vc_write=self.unexpected.append,
                       print_registers=lambda: None, do_syscall=self.syscall)

    def command(self, cmd, mode):
        """Serve one monitor command in mode loader/service/halted."""
        in_service = mode == 'service'
        if cmd in b'WR' or (cmd == ord('C') and in_service):
            args = self.get_n(5)
            if cmd == ord('C'):
                return ('C', args[0], int.from_bytes(args[1:5], 'big'))
            addr = int.from_bytes(args[0:3], 'big') & 0xFFFFF
            length = int.from_bytes(args[3:5], 'big')
            if cmd == ord('W'):
                data = self.get_n(length)
                ok = self.get() == sum(data) & 0xFF
                for i, b in enumerate(data):
                    self.mem[(addr + i) & 0xFFFFF] = b
                self.put(b'K' if ok else b'E')
            else:
                data = bytes(self.mem[(addr + i) & 0xFFFFF] for i in range(length))
                self.put(data + bytes([sum(data) & 0xFF]))
        elif cmd == ord('G'):
            self.put(b''.join(self.regs[n].to_bytes(4, 'big') for n in simpleos_host.REGISTER_NAMES))
        elif cmd == ord('Z') and mode == 'loader':
            self.mem[:] = bytes(1 << 20)
            self.put(b'K')
        elif cmd == ord('X') and mode == 'loader':
            return ('X',)
        else:
            self.put(b'E')
        return None

    def syscall(self, number):
        ns = self.ns
        if ns['mmu_flag']:                  # same page table sync as do_syscall
            pt = self.regs['PT'] & 0xFFFFF
            ns['pagetable'][:] = self.mem[pt:pt + 16]
        if number == 41:                    # handled inside the FPGA CPU
            self.regs['R8'] = ns['pagefault_laddr'] & 0xFFFFF
            return
        self.put(b'S' + number.to_bytes(2, 'big') + self.regs['R8'].to_bytes(4, 'big')
                 + self.regs['R9'].to_bytes(4, 'big'))
        while True:
            reply = self.command(self.get(), 'service')
            if reply and reply[0] == 'C':
                _, flags, value = reply
                if flags & 1:
                    self.regs['R8'] = value
                if flags & 2:
                    ns['push'](self.regs['PC'])
                    self.regs['PC'] = 0
                return

    def timer(self):
        while not self.halted.is_set():
            time.sleep(0.1)
            if self.int_flag.value:
                self.int_queue.put(0)

    def run(self):
        threading.Thread(target=self.timer, daemon=True).start()
        while True:                         # loader: wait for BREAK, then serve
            try:
                if self.port.to_device.get() is not BREAK:
                    continue
                self.reset_cpu()
                self.put(b'B')
                while True:
                    if self.command(self.get(), 'loader') == ('X',):
                        break
                self.ns['run']()
                # The FPGA prints nothing itself; emu.py's own HALT message is dropped.
                assert self.unexpected == ['CPU halted.\n'], self.unexpected
                self.unexpected.clear()
                self.put(b'H\x00')
                self.halted.set()
                while True:                 # halted CPU keeps W/R/G until BREAK
                    self.command(self.get(), 'halted')
            except ConnectionResetError:
                self.port.to_device.put(BREAK)


def assemble(book, source):
    spec = importlib.util.spec_from_file_location('book_asm', book / 'asm.py')
    asm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asm)
    text = (book / source).read_text(encoding='utf-8')
    asm.first_pass(text)
    asm.second_pass(text)
    return bytes(asm.binary_code)


def main():
    book = pathlib.Path(sys.argv[1]).resolve()
    port = FakePort()
    fpga = FakeFpga(port, book / 'emu.py')
    fpga.start()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        for name in ('pagefault', 'hello', 'mul', 'dump'):
            (tmp / f'{name}.bin').write_bytes(assemble(book, f'{name}.asm'))
        image = assemble(book, 'os.asm')
        host = simpleos_host.Host(simpleos_host.Link(port), book / 'emu.py', tmp)
        screen = io.StringIO()
        host.ns['sys'] = SimpleNamespace(stdout=screen)
        result = {}
        host.boot(image)
        runner = threading.Thread(target=lambda: result.setdefault('status', host.run()), daemon=True)
        runner.start()

        def wait_for(pattern, timeout=30):
            deadline = time.monotonic() + timeout
            # Task output goes to its own virtual console (task n -> VC n), as in emu.py.
            while not re.search(pattern, screen.getvalue().replace('\r\n', '\n')
                                + ''.join(host.ns['vc_buffers'])):
                assert time.monotonic() < deadline, f'timeout waiting for {pattern!r}; screen:\n{screen.getvalue()}'
                time.sleep(0.05)

        def type_line(line):
            for ch in line + '\n':
                host.key(ch)

        wait_for('Welcome to Simple OS!')
        for line, expect in (('ls', r'pagefault\.bin'), ('date', None), ('reg', 'CR: '),
                             ('taskexec pagefault.bin', '12345'),
                             ('exec hello.bin', 'Hello, World!'), ('exec mul.bin', '0x1000'),
                             ('exec dump.bin', r'(?s)Physical Memory Dump.*\n000F0  [^\n]*\n'), ('exit', r'bye\.')):
            before = len(screen.getvalue())
            type_line(line)
            if expect:
                wait_for(expect)
            else:
                deadline = time.monotonic() + 30
                while not re.search(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d', screen.getvalue()[before:]):
                    assert time.monotonic() < deadline, 'no date output'
                    time.sleep(0.05)
        runner.join(30)
    out = screen.getvalue()
    consoles = ''.join(host.ns['vc_buffers'])
    assert result.get('status') == 0, f'host did not see a clean HALT: {result}'
    assert not fpga.unexpected, f'CPU printed directly: {fpga.unexpected}'
    for text in ('Welcome to Simple OS!', 'pagefault.bin', 'PC: ', 'Hello, World!', '4096\r\n0x1000',
                 '[Logical Memory Dump]', '[Physical Memory Dump]', 'bye.', 'CPU halted.'):
        assert text in out, text
    assert '12345' in host.ns['vc_buffers'][1], 'task 1 output missing from VC 1'
    print(out.replace('\r\n', '\n'))
    print('--- VC 1 ---')
    print(host.ns['vc_buffers'][1])
    print('PASS: host drove the unchanged OS through the FPGA protocol '
          '(ls, date, reg, taskexec pagefault.bin with timer and page faults, '
          'exec hello/mul/dump with SYSCALL 22/2/40, exit, HALT)')


if __name__ == '__main__':
    main()
