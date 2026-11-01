# SPDX-License-Identifier: MIT
"""PC host for Simple OS on the Arty S7-50 DDR3 FPGA CPU.

The FPGA runs the unmodified Simple OS image (os_book_code os.bin) on its
CPU+MMU with 1 MiB of DDR3. Every SYSCALL except 41 stops the CPU and is
sent here over the UART (protocol in rtl/simpleos_os_core.vhd). This host
plays the part of emu.py's do_syscall: the console, virtual consoles,
register display, dump and string helpers are loaded unchanged from the
book's emu.py, and only memory access is redirected to the FPGA.

  python simpleos_host.py COM5 --book /path/to/os_book_code

Keys: Ctrl+] then 0-3 switches virtual console (as in emu.py),
      Ctrl+] then q quits the host (the FPGA keeps its state; the next start
      sends a BREAK and reloads).
"""
import argparse
import ast
import os
import pathlib
import queue
import sys
import threading
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from queue import Empty
from types import SimpleNamespace

REGISTER_NAMES = ['R0', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9',
                  'TP', 'SP', 'PC', 'PT', 'VT', 'CR']
TASK_PT_ADDR = [0xFFF00, 0xFFF10, 0xFFF20, 0xFFF30]
# Initial task page tables, as written by emu.py before it starts the CPU.
TASK_PAGE_TABLES = [bytes([task] + [0xFF] * 7 + list(range(8, 16))) for task in range(4)]
EMU_FUNCTIONS = ['_task_to_vc', '_vc_trunc', '_tty_show_vc', 'switch_vc', 'vc_write',
                 'print_registers', 'get_paddr', 'read_lmem', '_read_c_string', 'hexdump']
EMU_CLASSES = ['PageFault']
CHUNK = 4096


class ProtocolError(Exception):
    pass


def load_emu(emu_path, names=EMU_FUNCTIONS, classes=EMU_CLASSES):
    """Return a namespace holding the named functions/classes of emu.py.

    Only definitions are executed; emu.py's module code (terminal setup,
    processes) is not run. Globals the functions use are added by the caller.
    """
    tree = ast.parse(pathlib.Path(emu_path).read_text(encoding='utf-8'))
    wanted = set(names) | set(classes)
    body = [n for n in tree.body
            if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in wanted]
    missing = wanted - {n.name for n in body}
    if missing:
        raise SystemExit(f'emu.py lacks {sorted(missing)}')
    ns = {'sys': sys, 'time': time, 'Path': Path, 'datetime': datetime,
          'timezone': timezone, 'timedelta': timedelta, 'Empty': Empty}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(emu_path), 'exec'), ns)
    return ns


class Link:
    """FPGA monitor protocol over a pyserial-like port."""

    def __init__(self, port):
        self.port = port

    def _read(self, n, timeout=5.0):
        data = bytearray()
        deadline = time.monotonic() + timeout
        while len(data) < n:
            chunk = self.port.read(n - len(data))
            if chunk:
                data += chunk
            elif time.monotonic() > deadline:
                raise ProtocolError(f'timeout waiting for {n - len(data)} of {n} bytes')
        return bytes(data)

    def byte(self, timeout=5.0):
        return self._read(1, timeout)[0]

    def reset(self):
        """BREAK returns the FPGA to its loader, which answers 'B'."""
        self.port.reset_input_buffer()
        self.port.send_break(0.02)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            b = self.port.read(1)
            if b == b'B':
                return
        raise ProtocolError('no B from the FPGA after BREAK (bitstream loaded? DDR3 calibrated?)')

    def zero(self):
        self.port.write(b'Z')
        if self.byte(timeout=5) != ord('K'):
            raise ProtocolError('Z not acknowledged')

    def write(self, addr, data):
        data = bytes(data)
        for off in range(0, len(data), CHUNK):
            part = data[off:off + CHUNK]
            a = (addr + off) & 0xFFFFF
            packet = (b'W' + a.to_bytes(3, 'big') + len(part).to_bytes(2, 'big')
                      + part + bytes([sum(part) & 0xFF]))
            for attempt in range(3):
                self.port.write(packet)
                reply = self.byte()
                if reply == ord('K'):
                    break
            else:
                raise ProtocolError(f'W at {a:05X} rejected: {reply:#x}')

    def read(self, addr, length):
        out = bytearray()
        for off in range(0, length, CHUNK):
            n = min(CHUNK, length - off)
            a = (addr + off) & 0xFFFFF
            self.port.write(b'R' + a.to_bytes(3, 'big') + n.to_bytes(2, 'big'))
            part = self._read(n + 1)
            if sum(part[:n]) & 0xFF != part[n]:
                raise ProtocolError(f'R at {a:05X}: checksum mismatch')
            out += part[:n]
        return bytes(out)

    def registers(self):
        self.port.write(b'G')
        raw = self._read(64)
        return [int.from_bytes(raw[i:i + 4], 'big') for i in range(0, 64, 4)]

    def start(self):
        self.port.write(b'X')

    def complete(self, result=None, call=False):
        flags = (1 if result is not None else 0) | (2 if call else 0)
        value = 0 if result is None else result & 0xFFFFFFFF
        self.port.write(b'C' + bytes([flags]) + value.to_bytes(4, 'big'))

    def event(self, stop=None):
        """Wait for 'S' or 'H'. Returns ('S', n, r8, r9) or ('H', status)."""
        while stop is None or not stop.is_set():
            b = self.port.read(1)
            if not b:
                continue
            if b == b'S':
                raw = self._read(10)
                return ('S', int.from_bytes(raw[0:2], 'big'),
                        int.from_bytes(raw[2:6], 'big'), int.from_bytes(raw[6:10], 'big'))
            if b == b'H':
                return ('H', self.byte())
            raise ProtocolError(f'unexpected byte {b[0]:#04x} from the FPGA')
        return None


class RemoteMemory:
    """bytearray-like view of the FPGA's physical memory for emu.py helpers."""

    def __init__(self, link):
        self.link = link

    def __getitem__(self, key):
        if isinstance(key, slice):
            start, stop, step = key.indices(1 << 20)
            if step != 1:
                raise ValueError('step slices are not supported')
            return self.link.read(start, max(0, stop - start))
        return self.link.read(key & 0xFFFFF, 1)[0]

    def __setitem__(self, key, value):
        if isinstance(key, slice):
            start = key.start or 0
            self.link.write(start, bytes(value))
        else:
            self.link.write(key & 0xFFFFF, bytes([value & 0xFF]))


class Host:
    def __init__(self, link, emu_path, directory):
        self.link = link
        self.directory = pathlib.Path(directory)
        ns = load_emu(emu_path)
        self.ns = ns
        self.registers = dict.fromkeys(REGISTER_NAMES, 0)
        ns.update(
            registers=self.registers, registers_name=REGISTER_NAMES,
            memory=RemoteMemory(link), mmu_flag=0, pagetable=list(range(16)),
            page_bases=[i << 16 for i in range(16)], pagefault_laddr=0,
            NUM_VC=4, MAX_VC_BUFFER=200000, vc_buffers=['' for _ in range(4)],
            current_task_id=0, _active_vc=0, active_vc_shared=SimpleNamespace(value=0))
        self.key_queues = [queue.Queue() for _ in range(4)]
        self.vc_switch_queue = queue.Queue()
        self.stop = threading.Event()
        self.halted = threading.Event()     # CPU stopped; the next key closes the host

    # -- emu.py do_syscall, with memory and CPU state on the FPGA ---------
    def _sync_state(self, r8, r9):
        values = self.link.registers()
        self.registers.update(zip(REGISTER_NAMES, values))
        assert self.registers['R8'] == r8 and self.registers['R9'] == r9
        ns = self.ns
        ns['mmu_flag'] = 1 if self.registers['CR'] & 0x80000000 else 0
        if ns['mmu_flag']:
            pt = self.registers['PT'] & 0xFFFFF
            ns['pagetable'][:] = self.link.read(pt, 16)
            for i in range(16):
                ns['page_bases'][i] = (ns['pagetable'][i] & 0xFF) << 16

    def service(self, num, r8, r9):
        ns = self.ns
        vc_write = ns['vc_write']
        self.registers['R8'], self.registers['R9'] = r8, r9
        if num in (1, 2, 11, 20, 22, 23, 40):
            self._sync_state(r8, r9)
        try:
            if num == 0:
                vc_write(chr(r8 & 0xFF))
            elif num == 1:
                vc_write(ns['_read_c_string'](r8))
            elif num == 2:
                fmt = ns['_read_c_string'](r9)
                vc_write(format(r8, fmt))
            elif num == 3:
                vc_idx = ns['_task_to_vc'](ns['current_task_id'])
                if vc_idx is None:
                    vc_idx = ns['active_vc_shared'].value
                try:
                    ch = self.key_queues[vc_idx].get(timeout=0.005)
                except Empty:
                    ch = '\0'
                return self.link.complete(ord(ch) & 0x7F)
            elif num == 10:
                return self.link.complete(int(time.time()) & 0xFFFFFFFF)
            elif num == 11:
                timedata = r8 + int(self.registers['TP'] / 10)
                dt = datetime.fromtimestamp(timedata).replace(tzinfo=timezone.utc)
                vc_write(dt.strftime('%Y-%m-%d %H:%M:%S') + "\n")
            elif num == 20:
                ns['print_registers']()
            elif num == 21:
                try:
                    for f in self.directory.iterdir():
                        if f.is_file():
                            vc_write(f.name + "\n")
                except Exception:
                    vc_write("ls error.\n")
            elif num == 22:
                pfile = ns['_read_c_string'](r8)
                try:
                    prog = (self.directory / pfile).read_bytes()
                except Exception:
                    vc_write("File open error.\n")
                else:
                    self.link.write(0, prog)
                    return self.link.complete(call=True)   # push PC, PC=0 on the FPGA
            elif num == 23:
                paddr = ns['memory'][TASK_PT_ADDR[r8 & 0xFF]] * 0x10000
                pfile = ns['_read_c_string'](r9)
                try:
                    prog = (self.directory / pfile).read_bytes()
                    if len(prog) > 0x10000:
                        raise Exception
                except Exception:
                    vc_write("File open error.\n")
                else:
                    self.link.write(paddr, prog)
            elif num == 30:
                ns['current_task_id'] = r8 & 0xFF
            elif num == 40:
                start_addr = r8 & 0xFFFFF
                if r9 & 1:
                    memdata = []
                    for i in range(256):
                        memdata += ns['read_lmem'](r8 + i, 1).to_bytes()
                else:
                    memdata = ns['memory'][r8:r8 + 256]
                ns['hexdump'](memdata, start_addr)
            else:
                vc_write(f"Syscall {num} not implement yet.\n")
        except ns['PageFault']:
            vc_write(f"\n[host] page fault at {ns['pagefault_laddr']:05X} during SYSCALL {num}\n")
        self.link.complete()

    def boot(self, image):
        self.link.reset()
        self.link.zero()
        # os.bin is ~1 MiB of mostly zero gaps between .ADDR sections; memory
        # is already zeroed, so all-zero blocks need not cross the UART.
        for off in range(0, len(image), CHUNK):
            block = image[off:off + CHUNK]
            if any(block):
                self.link.write(off, block)
        for addr, table in zip(TASK_PT_ADDR, TASK_PAGE_TABLES):
            self.link.write(addr, table)
        self.link.start()

    def run(self):
        while not self.stop.is_set():
            try:
                while True:
                    self.ns['switch_vc'](self.vc_switch_queue.get_nowait())
            except Empty:
                pass
            ev = self.link.event(self.stop)
            if ev is None:
                return None
            if ev[0] == 'H':
                # emu.py prints this itself at HALT; the halted CPU keeps its registers.
                self.registers.update(zip(REGISTER_NAMES, self.link.registers()))
                if ev[1] & 1:
                    self.ns['vc_write']("CPU fault stop (invalid instruction or size).\n")
                else:
                    self.ns['vc_write']("CPU halted.\n")
                self.ns['print_registers']()
                return ev[1]
            self.service(*ev[1:])
        return None

    # -- keyboard (emu.py keyboard_listener) -------------------------------
    def key(self, ch):
        """Feed one typed character; returns False when the user quits."""
        if self.halted.is_set():
            self.stop.set()
            return False
        if getattr(self, '_awaiting_digit', False):
            self._awaiting_digit = False
            if ch in '0123':
                self.vc_switch_queue.put(ord(ch) - ord('0'))
                self.ns['active_vc_shared'].value = ord(ch) - ord('0')
            elif ch in 'qQ':
                self.stop.set()
                return False
            return True
        if ch == '\x1d':
            self._awaiting_digit = True
            return True
        self.key_queues[self.ns['active_vc_shared'].value].put(ch)
        return True


def keyboard_thread(host):
    if os.name == 'nt':
        import msvcrt
        while not host.stop.is_set():
            ch = msvcrt.getwch()
            if ch in ('\x00', '\xe0'):      # arrow/function key prefix: skip both
                msvcrt.getwch()
                continue
            if ch == '\r':                  # emu.py on a Linux tty receives LF
                ch = '\n'
            if not host.key(ch):
                return
    else:
        import termios
        import tty
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setcbreak(fd)
            while not host.stop.is_set():
                ch = os.read(fd, 1).decode(errors='ignore')
                if ch and not host.key(ch):
                    return
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)


def enable_ansi():
    if os.name == 'nt':
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)  # VT processing


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('port', help='serial port of the USB-TTL adapter, e.g. COM5 or /dev/ttyUSB0')
    p.add_argument('--book', type=pathlib.Path, required=True,
                   help='os_book_code checkout (emu.py, os.bin, dir/)')
    p.add_argument('--os-bin', type=pathlib.Path, help='OS image (default: BOOK/os.bin)')
    p.add_argument('--dir', type=pathlib.Path, help='program directory (default: BOOK/dir)')
    p.add_argument('--baud', type=int, default=3000000,
                   help='must match the bitstream (default 3000000); set the FTDI latency timer to 1 ms')
    a = p.parse_args()
    import serial
    image = (a.os_bin or a.book / 'os.bin').read_bytes()
    port = serial.Serial(a.port, a.baud, timeout=0.05)
    host = Host(Link(port), a.book / 'emu.py', a.dir or a.book / 'dir')
    enable_ansi()
    print(f'[host] loading {len(image)} bytes on {a.port}; Ctrl+] q quits', flush=True)
    host.boot(image)
    threading.Thread(target=keyboard_thread, args=(host,), daemon=True).start()
    try:
        status = host.run()
    except KeyboardInterrupt:
        status = None
    finally:
        port.close()
    if status is not None:
        # A console window started for the host closes when it exits; keep the
        # HALT output on screen until a key is pressed.
        host.halted.set()
        print('\r\n[host] CPU stopped. Press any key to close.', flush=True)
        try:
            host.stop.wait()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
