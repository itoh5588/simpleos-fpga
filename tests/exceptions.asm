; Physical page 2 contains code executed at logical page 0.
.ADDR 0x20000
low_code:
MOVI R6, 0x56789
SYSCALL 20
JPI finish
.ADDR 0x50000
SYSCALL 20
JPI fetch_return
; Identity-mapped handler and main code.
.ADDR 0x80000
MOVI PT, 0xFFF00
MOVI VT, vectors
MOVI R0, 0xC0000
MULI R0, 0x1000
MOV CR, R0
SYSCALL 20
; A timer interrupt is queued after this checkpoint.
MOVI R5, 0x12345
STDI R5, 0x10000
LDDI R7, 0x10000
SYSCALL 20
; Reload uses a page-table entry changed by the preceding instruction.
JPI 0
finish:
SYSCALL 20
; Cross-page store: first two bytes written before a fault on page 4.
STDI R5, 0x3FFFE
LDDI R7, 0x3FFFE
SYSCALL 20
; Fetch from initially missing logical page 5, mapped by the handler.
JPI 0x50000
fetch_return:
SYSCALL 20
HALT
irq_handler:
INC TP
SYSCALL 20
IRET
fault_handler:
PUSH R0
PUSH R1
PUSH R8
SYSCALL 41
SYSCALL 20
MOV R0, SP
ADDI R0, 16
LDD R1, [R0]
SBT R1, R8
JPZI no_rewind
SUBI R1, 4
STD R1, [R0]
no_rewind:
DIVI R8, 0x10000
MOV R0, R8
ADDI R0, 0xFFF00
STB R8, [R0]
POP R8
POP R1
POP R0
IRET
.ADDR 0xFF800
vectors:
.DWORD irq_handler
.DWORD irq_handler
.DWORD irq_handler
.DWORD fault_handler
.ADDR 0xFFF00
.BYTE 2
.BYTE 255
.BYTE 2
.BYTE 3
.BYTE 255
.BYTE 255
.BYTE 6
.BYTE 7
.BYTE 8
.BYTE 9
.BYTE 10
.BYTE 11
.BYTE 12
.BYTE 13
.BYTE 14
.BYTE 15
