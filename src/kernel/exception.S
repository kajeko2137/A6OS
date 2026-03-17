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
    b halt_sys

swi_handler:
    push {r0-r12, lr}               // Save return address (bl clobbers LR in SVC mode)

    cmp r7, #1
    beq sys_exit

    cmp r7, #2
    beq sys_alloc_page

    cmp r7, #3
    beq sys_free_page

.swi_return:
    // Success! Return from exception and retry the instruction
    pop {r0-r12, lr}
    movs pc, lr

    // Unknown syscall
    b halt_sys

// sys_alloc_page — Syscall #2
// Allocates a new page for the calling process.
// Returns: r0 = virtual address of new page (0 if fail)
sys_alloc_page:
    bl alloc_process_page   // r0 = virtual address (or 0)
    str r0, [sp]            // Overwrite the saved r0 on the stack with the result
    b .swi_return

// sys_free_page — Syscall #3
// Frees a previously allocated page.
// Argument: r0 = virtual address
// Returns: r0 = 0 (Success) or -1 (Fail)
sys_free_page:
    bl free_process_page
    b .swi_return

prefetch_handler:
    b halt_sys

data_handler:
    // Sub LR by 8 to point to the instruction that caused the abort
    sub lr, lr, #8
    push {r0-r12, lr}        // Save registers

    // Read DFSR (Data Fault Status Register)
    mrc p15, 0, r0, c5, c0, 0
    // Check if it's a translation fault (e.g. status == 0b0101 or 0b0111)
    and r1, r0, #0xF
    cmp r1, #5              // Section translation fault
    beq .lazy_alloc
    cmp r1, #7              // Page translation fault
    beq .lazy_alloc

    // Success! Return from exception and retry the instruction
    pop {r0-r12, lr}
    movs pc, lr

.abort_fatal:
    pop {r0-r12, lr}
    bl sys_exit             // Terminate the process

.lazy_alloc:
    // Ensure the abort occurred in User Mode (0x10)
    mrs r1, spsr
    and r1, r1, #0x1F
    cmp r1, #0x10
    bne .abort_fatal         // Do not allow lazy allocation for kernel faults!

    // Read DFAR (Data Fault Address Register)
    mrc p15, 0, r0, c6, c0, 0

    // Validate bounds: must be in [0x00102000, 0x70000000)
    ldr r1, =0x00102000
    cmp r0, r1
    blt .abort_fatal

    ldr r1, =0x70000000
    cmp r0, r1
    bge .abort_fatal

    // Check if we hit the stack guard page or stack
    ldr r1, =0x001FF000
    cmp r0, r1
    beq .abort_fatal        // Protect the stack page (already allocated)

    // Call alloc_specific_page(r0 = virtual_address)
    bl alloc_specific_page
    cmp r0, #0
    beq .abort_fatal        // Allocation failed (OOM)

    // Success! Return from exception and retry the instruction
    pop {r0-r12, lr}
    movs pc, lr

// This one will periodically fire, enabling the scheduler
irq_handler:
    //adjusting lr (this is a BCM2835 quirk)
    sub lr, lr, #4

    
    push {r0-r12, lr}

    // --- CLEAR TIMER INTERRUPT ---
    ldr r0, =0x20003000     // TIMER_BASE
    
    // 1. Read current time
    ldr r1, [r0, #0x04]     // TIMER_CLO
    
    // 2. Add interval (10ms)
    ldr r2, =10000          // TIMER_INTERVAL
    add r1, r1, r2
    
    // 3. Set next match time
    str r1, [r0, #0x10]     // TIMER_C1
    
    // 4. Clear the interrupt flag
    mov r1, #(1 << 1)
    str r1, [r0, #0x00]     // TIMER_CS
    // -----------------------------
    
    //check if we're in kernel mode
    mrs r0, spsr
    and r0, r0, #0x1F //we're only interested in bottom 5 bits
    cmp r0, #0x10 // We check if we were in user mode
    bne .resume_kernel
    
    // We were in user mode! Interrupt fired while running user code.
    // Save context!
    ldr r0, =current_process
    ldr r0, [r0]
    cmp r0, #0
    beq .skip_save               // Should not happen if in user mode, but safe

    // Access via higher-half
    ldr r1, =0x80000000
    add r0, r0, r1
    add r0, r0, #0x400           // r0 = Descriptor base

    // Save r0-r12 using values from IRQ stack
    add r1, r0, #36              // r1 points to [36]
    mov r2, sp
    ldmia r2, {r3-r10}           // load r0-r7
    stmia r1!, {r3-r10}          // store r0-r7
    add r2, r2, #32
    ldmia r2, {r3-r7}            // load r8-r12
    stmia r1!, {r3-r7}           // store r8-r12

    // Save user sp and lr
    // Switch to System Mode
    mrs r3, cpsr
    bic r4, r3, #0x1F
    orr r4, r4, #0x1F
    msr cpsr_c, r4
    mov r5, sp                   // User SP
    mov r6, lr                   // User LR
    msr cpsr_c, r3               // Back to IRQ mode
    stmia r1!, {r5, r6}

    // Save user PC
    ldr r5, [sp, #52]            // lr is at sp + 52
    str r5, [r1], #4             // store user PC

    // Save user CPSR
    mrs r5, spsr
    str r5, [r1], #4             // store user CPSR

.skip_save:
    // Clean up IRQ stack!
    add sp, sp, #56
    
    // Switch to SVC mode
    mrs r1, cpsr
    bic r1, r1, #0x1F
    orr r1, r1, #0x13
    msr cpsr_c, r1
    
    b reschedule

.resume_kernel:
    // telling the kernel to run scheduler after finnishing interrupt
    ldr r0, =needs_reschedule
    mov r1, #1
    str r1, [r0]

    pop {r0-r12, lr}
    movs pc, lr

fiq_handler:
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


.section ".bss"
.align 4
.globl needs_reschedule
needs_reschedule:
    .space 4
