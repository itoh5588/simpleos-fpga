# SPDX-License-Identifier: MIT
"""Hardware check of the DDR3 Simple OS bitstream through the UART monitor.

1. BREAK -> 'B', 'Z', random 16 KiB blocks written and read back at four
   places, zeroed bytes elsewhere checked, 'G' answered.
2. The unchanged OS is booted with simpleos_host and driven with typed
   commands: ls, date, reg, taskexec pagefault.bin, exit (then HALT).

  python check_board.py COM5 --book /path/to/os_book_code --dir DIR_WITH_pagefault.bin
"""
import argparse
import io
import os
import pathlib
import re
import sys
import threading
import time
from types import SimpleNamespace

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import simpleos_host  # noqa: E402


def memory_test(link):
    t = time.monotonic()
    link.reset()
    link.zero()
    print(f'B and Z ok ({time.monotonic() - t:.2f} s)', flush=True)
    for addr in (0x00000, 0x40000, 0x80000, 0xFC000):
        data = os.urandom(16384)
        t = time.monotonic()
        link.write(addr, data)
        back = link.read(addr, len(data))
        bad = [i for i in range(len(data)) if data[i] != back[i]]
        assert not bad, f'{len(bad)} mismatches at {addr:05X}, first +{bad[0]:X}'
        print(f'16 KiB at {addr:05X} written and read back ({time.monotonic() - t:.1f} s)', flush=True)
    for addr in (0x20000, 0x60000, 0xC0000, 0xF8000):
        assert link.read(addr, 256) == bytes(256), f'Z left data at {addr:05X}'
    print('zeroed areas read back as 0', flush=True)
    regs = link.registers()
    assert regs[11] == 0xFF000 and regs[12] == 0x80000, [hex(r) for r in regs]
    print('G: reset registers SP=FF000 PC=80000', flush=True)


def os_test(link, book, directory, image):
    host = simpleos_host.Host(link, book / 'emu.py', directory)
    screen = io.StringIO()
    host.ns['sys'] = SimpleNamespace(stdout=screen)
    result = {}
    t0 = time.monotonic()
    host.boot(image)
    runner = threading.Thread(target=lambda: result.setdefault('status', host.run()), daemon=True)
    runner.start()

    def seen():
        return screen.getvalue() + ''.join(host.ns['vc_buffers'])

    def wait_for(pattern, timeout=60):
        deadline = time.monotonic() + timeout
        while not re.search(pattern, seen()):
            if time.monotonic() > deadline:
                raise AssertionError(f'timeout waiting for {pattern!r}; screen:\n{screen.getvalue()}')
            time.sleep(0.05)

    wait_for('Welcome to Simple OS!')
    print(f'OS booted ({time.monotonic() - t0:.1f} s)', flush=True)
    for line, pattern in (('ls', r'pagefault\.bin'), ('date', r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d'),
                          ('reg', r'CR: [0-9A-F]{8}'), ('taskexec pagefault.bin', '12345'),
                          ('exit', 'CPU halted')):
        t = time.monotonic()
        for ch in line + '\n':
            host.key(ch)
        wait_for(pattern)
        print(f'{line!r}: ok ({time.monotonic() - t:.1f} s)', flush=True)
    runner.join(10)
    assert result.get('status') == 0, result
    print('--- VC 0 ---')
    print(screen.getvalue().replace('\r\n', '\n').replace('\x1b[2K', ''))
    print('--- VC 1 ---')
    print(host.ns['vc_buffers'][1])


def main():
    p = argparse.ArgumentParser()
    p.add_argument('port')
    p.add_argument('--book', type=pathlib.Path, required=True)
    p.add_argument('--os-bin', type=pathlib.Path)
    p.add_argument('--dir', type=pathlib.Path)
    a = p.parse_args()
    import serial
    port = serial.Serial(a.port, 115200, timeout=0.05)
    link = simpleos_host.Link(port)
    try:
        memory_test(link)
        os_test(link, a.book, a.dir or a.book / 'dir', (a.os_bin or a.book / 'os.bin').read_bytes())
    finally:
        port.close()
    print('PASS: board memory test and OS session')


if __name__ == '__main__':
    main()
