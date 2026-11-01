"""Create a binary packet and a Tera Term macro that keeps COM5 connected."""
import argparse
import pathlib
p = argparse.ArgumentParser()
p.add_argument('image', type=pathlib.Path)
a = p.parse_args()
data = a.image.read_bytes()
if not 0 < len(data) <= 8192:
    p.error('RAM image must be 1..8192 bytes')
packet = a.image.with_suffix('.uart')
packet.write_bytes(b'W' + len(data).to_bytes(2, 'big') + data + bytes([sum(data) & 255]))
macro = a.image.with_suffix('.ttl')
macro.write_text('''; Run this from the already connected Tera Term: Control > Macro.
; COM5 stays open; UART BREAK stops the CPU and returns to the loader.
testlink
if result <> 2 then
  messagebox 'Run from the connected Tera Term window using Control > Macro.' 'Simple OS FPGA'
  end
endif
setbaud 115200
setflowctrl 3
setecho 0
timeout = 5
flushrecv
sendbreak
wait 'B'
if result = 0 then
  messagebox 'Loader did not respond. Check COM5 and the BREAK-capable bitstream.' 'Simple OS FPGA'
  end
endif
getdir packet
strconcat packet '\\''' + packet.name + ''''
sendfile packet 1
wait 'K' 'E'
if result <> 1 then
  messagebox 'Image transfer failed.' 'Simple OS FPGA'
  end
endif
send 'R'
; Return control to the same terminal window; do not disconnect or close it.
end
''', encoding='ascii')
macro.write_text(macro.read_text().replace(chr(92)*2, chr(92)), encoding='ascii')
print(f'{macro}: {len(data)}-byte program; packet {packet}')
