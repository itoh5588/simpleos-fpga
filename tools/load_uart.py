"""Load a <=8 KiB RAM image and run it on the Simple OS Arty S7 bring-up CPU."""
import argparse
import os
import pathlib
import select
import sys
import termios
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('port')
    p.add_argument('image', type=pathlib.Path)
    p.add_argument('--timeout', type=float, default=10)
    p.add_argument('--start-only', action='store_true', help='Start without waiting for HALT')
    p.add_argument('--input', default='', help='ASCII input to send after starting the program')
    a = p.parse_args()
    input_data = a.input.encode('ascii')
    data = a.image.read_bytes()
    if not 0 < len(data) <= 8192:
        p.error('image must be 1..8192 bytes at origin 0x80000')
    fd = os.open(a.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = attrs[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        termios.tcflush(fd, termios.TCIOFLUSH)
        packet = b'W' + len(data).to_bytes(2, 'big') + data + bytes([sum(data) & 255])
        sent = 0
        deadline = time.monotonic() + a.timeout
        while sent < len(packet):
            if time.monotonic() > deadline:
                raise TimeoutError('UART upload timed out')
            if select.select([], [fd], [], .1)[1]:
                sent += os.write(fd, packet[sent:])
        termios.tcdrain(fd)
        def read_one():
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    value = os.read(fd, 1)
                    if value:
                        return value
            raise TimeoutError('No UART response; verify CPU bitstream and reset BTN0')
        ack = read_one()
        if ack == b'E':
            raise RuntimeError('Loader rejected image')
        if ack != b'K':
            raise RuntimeError(f'Unexpected response {ack!r}; stop the running sample with BTN0 or JTAG reconfiguration before loading')
        print(f'LOADED {len(data)} bytes, checksum {sum(data) & 255:02X}', flush=True)
        os.write(fd, b'R')
        for value in input_data:
            os.write(fd, bytes([value]))
            time.sleep(.01)
        if a.start_only:
            termios.tcdrain(fd)
            print('RUNNING; UART released', flush=True)
            return
        deadline = time.monotonic() + a.timeout
        while True:
            ch = read_one()
            if ch == b'\x04':
                print('HALT_OK', flush=True)
                break
            if ch == b'\x15':
                raise RuntimeError('CPU fault, unmapped address or unsupported SYSCALL')
            sys.stdout.buffer.write(ch)
            sys.stdout.buffer.flush()
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()
