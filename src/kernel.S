.section ".text.boot"
.globl _start

// Program Entry Point
_start:
    // Setup the stack pointer
    mov sp, #0x8000

    // Sterilize the .bss section (Zero-out the page table)
    ldr r4, =__bss_start
    ldr r9, =__bss_end
    mov r5, #0
    mov r6, #0
    mov r7, #0
    mov r8, #0
1:  
    cmp r4, r9
    bhs 2f                  // If we reached the end, break out
    stmia r4!, {r5-r8}      // Blast 16 bytes of zeroes into memory
    b 1b
2:

    // Install the exception vector table at address 0x0
    bl install_vectors

    // Now we can safely initialize the system
    bl uart_init

    // Reserve 1MB of physical memory for the kernel (256 × 4KB pages)
    bl reserve_kernel_pages

    // Send the welcome message
    ldr r0, =welcome_msg
    bl uart_puts    

    // Set up kernel MMU tables (identity + UART + higher-half)
    bl init_kernel_mmu

    // Save the kernel's L1 table address for sys_exit
    ldr r1, =kernel_l1_base
    str r0, [r1]

    // Enable the MMU with the kernel's L1 table (returned in r0)
    bl enable_mmu
    
    // Send the debug message
    ldr r0, =debug_msg
    bl uart_puts

    // Launch process1
    ldr r0, =_process1_start
    ldr r1, =_process1_end
    bl launch_process

    // Process returned via sys_exit — fall through here
.globl kernel_after_process
kernel_after_process:
    ldr r0, =returned_msg
    bl uart_puts

    // Halt the CPU in an infinite loop
.globl halt
halt:
    b halt

// -----------------------------------------------------------------
// Install Exception Vector Table
// Copies 64 bytes (8 vectors + 8 address words) from _vectors to 0x0
// -----------------------------------------------------------------
install_vectors:
    ldr r0, =_vectors       // source
    mov r1, #0              // destination = 0x00000000
    mov r2, #16             // 16 words = 64 bytes
1:
    ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    bx lr

// -----------------------------------------------------------------
// Launch Process
// r0 = process code start, r1 = process code end
// Allocates the process, switches to its page table, and jumps in.
// -----------------------------------------------------------------
.globl launch_process
launch_process:
    push {r4-r5, lr}

    // Save kernel stack pointer
    ldr r3, =kernel_sp
    str sp, [r3]

    // Allocate the process
    bl alloc_process
    // r0 = L1 table base, r1 = entry point, r2 = stack pointer

    // Save entry and SP before TTBR switch
    mov r4, r1              // r4 = entry point
    mov r5, r2              // r5 = process SP

    // Switch TTBR0 to process L1 table
    mcr p15, 0, r0, c2, c0, 0

    // Invalidate TLB and flush prefetch
    mov r0, #0
    mcr p15, 0, r0, c8, c7, 0
    mcr p15, 0, r0, c7, c5, 4

    // Set process stack and jump to entry point
    mov sp, r5
    bx r4
    // Does not return — sys_exit brings us back to kernel_after_process

// -----------------------------------------------------------------
// Reserve 1MB (256 pages) of physical memory for the kernel
// -----------------------------------------------------------------
reserve_kernel_pages:
    push {r4, lr}
    mov r4, #0              // page counter

1:
    bl alloc_page           // allocate one 4KB page (result discarded)
    add r4, r4, #1
    cmp r4, #256            // 256 × 4KB = 1MB
    blt 1b

    pop {r4, pc}

// Enable MMU
// r0 = Physical Address of L1 Table (16KB aligned)
.globl enable_mmu
enable_mmu:
    // 1. Invalidate TLB
    mov r1, #0
    mcr p15, 0, r1, c8, c7, 0

    // 2. Set Domain 0 to Client mode
    mov r1, #1
    mcr p15, 0, r1, c3, c0, 0

    // 3. Set Translation Table Base Register 0 (TTBR0)
    mcr p15, 0, r0, c2, c0, 0

    // 4. Enable MMU in System Control Register (SCTLR)
    mrc p15, 0, r1, c1, c0, 0
    orr r1, r1, #1
    mcr p15, 0, r1, c1, c0, 0

    // 5. Flush Prefetch Buffer
    mov r1, #0
    mcr p15, 0, r1, c7, c5, 4

    bx lr


.section ".rodata"
welcome_msg:
    .asciz "Welcome to A6OS!\r\n"
debug_msg:
    .asciz "UART still works!\r\n"
returned_msg:
    .asciz "Process exited, returned to kernel.\r\n"
