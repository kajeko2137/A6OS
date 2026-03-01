// process1.S — Simple test process
// Loops 10 times as a proof-of-concept.
// No UART calls (avoids PC-relative branch issues when relocated).
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

    // Done — loop forever (process has no scheduler to return to yet)
.done:
    b .done
