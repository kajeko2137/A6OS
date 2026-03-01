.section ".text.vectors"
.globl _vectors

// Exception Vector Table
// Copied to address 0x00000000 by install_vectors in kernel.S
_vectors:
    ldr pc, reset_addr          // 0x00: Reset
    ldr pc, undef_addr          // 0x04: Undefined Instruction
    ldr pc, swi_addr            // 0x08: Software Interrupt (Syscalls)
    ldr pc, prefetch_addr       // 0x0C: Prefetch Abort
    ldr pc, data_addr           // 0x10: Data Abort
    ldr pc, unused_addr         // 0x14: Reserved
    ldr pc, irq_addr            // 0x18: Hardware IRQ
    ldr pc, fiq_addr            // 0x1C: Fast IRQ

// Absolute addresses of handler functions (loaded by the ldr instructions above)
reset_addr:     .word _start
undef_addr:     .word undef_handler
swi_addr:       .word swi_handler
prefetch_addr:  .word prefetch_handler
data_addr:      .word data_handler
unused_addr:    .word 0
irq_addr:       .word irq_handler
fiq_addr:       .word fiq_handler

// ---------------------------------------------------------
// Exception Handlers
// ---------------------------------------------------------

undef_handler:
    ldr r0, =msg_undef
    bl uart_puts
    b halt_sys

swi_handler:
    push {lr}               // Save return address (bl clobbers LR in SVC mode)

    cmp r7, #1
    beq sys_exit

    cmp r7, #2
    beq sys_alloc_page

    cmp r7, #3
    beq sys_free_page

    // Unknown syscall
    ldr r0, =msg_swi
    bl uart_puts
    b halt_sys

// sys_alloc_page — Syscall #2
// Allocates a new page for the calling process.
// Returns: r0 = virtual address of new page (0 if fail)
sys_alloc_page:
    bl alloc_process_page   // r0 = virtual address (or 0)
    pop {lr}
    movs pc, lr             // Return to process, r0 is preserved!

// sys_free_page — Syscall #3
// Frees a previously allocated page.
// Argument: r0 = virtual address
// Returns: r0 = 0 (Success) or -1 (Fail)
sys_free_page:
    bl free_process_page
    pop {lr}
    movs pc, lr

prefetch_handler:
    ldr r0, =msg_prefetch
    bl uart_puts
    b halt_sys

data_handler:
    ldr r0, =msg_data
    bl uart_puts
    
    // Read and print DFSR
    mrc p15, 0, r0, c5, c0, 0
    bl uart_print_hex
    ldr r0, =msg_space
    bl uart_puts
    
    // Read and print DFAR
    mrc p15, 0, r0, c6, c0, 0
    bl uart_print_hex
    ldr r0, =msg_crlf
    bl uart_puts
    
    b halt_sys

irq_handler:
    ldr r0, =msg_irq
    bl uart_puts
    b halt_sys

fiq_handler:
    ldr r0, =msg_fiq
    bl uart_puts
    b halt_sys

halt_sys:
    b halt_sys

// ---------------------------------------------------------
// sys_exit — Syscall #1
// Identifies the calling process, switches to kernel page
// table, frees all process memory, returns to kernel.
// ---------------------------------------------------------
.section ".text.syscalls"
sys_exit:
    // 1. Read TTBR0 to identify which process is running
    mrc p15, 0, r4, c2, c0, 0  // r4 = process L1 phys addr

    // 2. Switch to kernel page table
    ldr r0, =kernel_l1_base
    ldr r0, [r0]
    mcr p15, 0, r0, c2, c0, 0  // TTBR0 = kernel L1

    // 3. Invalidate TLB
    mov r0, #0
    mcr p15, 0, r0, c8, c7, 0
    mcr p15, 0, r0, c7, c5, 4  // flush prefetch buffer

    // 4. Restore kernel stack pointer
    ldr r0, =kernel_sp
    ldr sp, [r0]

    // 5. Extract L2 phys addr from the process's L1 table
    //    L1[1] = coarse descriptor = L2_phys | 0x01
    ldr r0, =0x80000000
    add r0, r4, r0             // r0 = process L1 virtual addr
    ldr r0, [r0, #4]           // read L1[1]
    bic r0, r0, #0xFF          // clear descriptor bits -> L2 phys addr

    // 6. Delete the process (frees all pages, removes from process list)
    bl delete_process

    // 7. Return to kernel
    b kernel_after_process


.section ".rodata"
msg_undef:    .asciz "\r\n[EXCEPT] Undefined Instruction\r\n"
msg_swi:      .asciz "\r\n[EXCEPT] Unknown SWI\r\n"
msg_prefetch: .asciz "\r\n[EXCEPT] Prefetch Abort\r\n"
msg_data:     .asciz "\r\n[EXCEPT] Data Abort\r\n"
msg_irq:      .asciz "\r\n[EXCEPT] Unhandled IRQ\r\n"
msg_fiq:      .asciz "\r\n[EXCEPT] Unhandled FIQ\r\n"
msg_swi_entry: .asciz "[DBG] SWI handler entered\r\n"
msg_space:    .asciz " "
msg_crlf:     .asciz "\r\n"