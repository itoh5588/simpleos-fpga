.ADDR 0x80000
MOVI R5, 0
again:
MOVI R8, message
SYSCALL 1
MOVI R8, 13
SYSCALL 0
MOVI R8, 10
SYSCALL 0
XORI R5, 1
MOV R8, R5
SYSCALL 50
MOVI R4, 5
outer_delay:
MOVI R0, 0xFFFFF
delay:
DEC R0
JPNZI delay
DEC R4
JPNZI outer_delay
JPI again
message:
.STRING "Hello from FPGA CPU - UART and LED running"
