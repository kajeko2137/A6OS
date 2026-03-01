// process1.S — Simple test process
// Loops 10 times as a proof-of-concept.
// Exits via SWI syscall.
// Entry point: process1_entry

.section ".text.process1"

.globl process1_entry
process1_entry:
    mov r0, #0              // r0 = counter
    mov r1, #10             // r1 = upper bound

.loop:
    add r0, r0, #1
    cmp r0, r1
    blt .loop

    // Done - call sys_exit
    mov r0, #0
    mov r7, #1
    swi #0