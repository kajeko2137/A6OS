.section ".text"

.equ PAGE_SIZE,  0x1000                 // 4KB
.equ RAM_SIZE,   0x20000000             // 512MB
.equ NUM_PAGES,  (RAM_SIZE / PAGE_SIZE) // 131072 pages

// -----------------------------------------------------------------
// Allocate L1 Table (16KB aligned)
// Returns physical address in r0 (0 if fail)
// -----------------------------------------------------------------
.globl alloc_l1_table
alloc_l1_table:
    push {r4}
    ldr r0, =page_table
    ldr r1, =NUM_PAGES
    mov r2, #0              // r2 = index

1:  // Alignment Check Loop
    cmp r2, r1
    bge alloc_fail

    // Check 4 contiguous pages
    ldrb r3, [r0, r2]
    cmp r3, #0
    bne next_block

    add r4, r2, #1
    ldrb r3, [r0, r4]
    cmp r3, #0
    bne next_block

    add r4, r2, #2
    ldrb r3, [r0, r4]
    cmp r3, #0
    bne next_block

    add r4, r2, #3
    ldrb r3, [r0, r4]
    cmp r3, #0
    beq found_block

next_block:
    add r2, r2, #4          // Next 16KB boundary
    b 1b

found_block:
    // Mark 4 pages as used
    mov r3, #1
    strb r3, [r0, r2]
    add r4, r2, #1
    strb r3, [r0, r4]
    add r4, r2, #2
    strb r3, [r0, r4]
    add r4, r2, #3
    strb r3, [r0, r4]

    lsl r0, r2, #12         // Convert index to address
    pop {r4}
    bx lr

alloc_fail:
    mov r0, #0
    pop {r4}
    bx lr

// -----------------------------------------------------------------
// Map 1MB Section
// r0 = Table Base, r1 = Virtual Addr, r2 = Phys Addr, r3 = Flags
// -----------------------------------------------------------------
.globl map_l1_section
map_l1_section:
    lsr r1, r1, #20         // Get 1MB index
    lsl r1, r1, #2          // Convert to byte offset
    add r0, r0, r1          // r0 = address of table entry

    lsr r2, r2, #20         // Align physical address
    lsl r2, r2, #20
    orr r2, r2, r3          // Combine with flags
    
    str r2, [r0]            // Write descriptor
    bx lr

// -----------------------------------------------------------------
// Initialize Kernel MMU Tables (call BEFORE enable_mmu)
// Allocates L1 table, maps kernel identity, UART, and 512MB
// higher-half (0x80000000+ -> physical RAM).
// Returns: r0 = L1 table physical address (for enable_mmu)
// -----------------------------------------------------------------
.globl init_kernel_mmu
init_kernel_mmu:
    push {r4-r7, lr}

    // Allocate & zero L1 table
    bl alloc_l1_table
    cmp r0, #0
    beq .kernel_mmu_fail
    mov r4, r0              // r4 = L1 table base

    mov r1, r0
    ldr r2, =0x4000
    add r2, r1, r2
    mov r3, #0
1:  str r3, [r1], #4
    cmp r1, r2
    blo 1b

    // Map 512MB Physical RAM to Higher-Half (0x80000000+)
    ldr r5, =0x80000000     // r5 = current virtual address
    mov r6, #0              // r6 = current physical address
    ldr r7, =512            // r7 = loop counter (512 x 1MB)
2:
    mov r0, r4
    mov r1, r5
    mov r2, r6
    ldr r3, =0x402          // Privileged RW Section
    bl map_l1_section

    add r5, r5, #0x100000
    add r6, r6, #0x100000
    subs r7, r7, #1
    bne 2b

    // Identity map kernel (0x0 -> 0x0) — needed to survive MMU enable
    mov r0, r4
    mov r1, #0
    mov r2, #0
    ldr r3, =0x402
    bl map_l1_section

    // Identity map UART (0x20200000 -> 0x20200000)
    mov r0, r4
    ldr r1, =0x20200000
    ldr r2, =0x20200000
    ldr r3, =0x402
    bl map_l1_section

    ldr r0, =kernel_mmu_msg
    bl uart_puts

    mov r0, r4              // r0 = L1 table base for enable_mmu
    pop {r4-r7, pc}

.kernel_mmu_fail:
    mov r0, #0
    pop {r4-r7, pc}

// -----------------------------------------------------------------
// Allocate Process (call AFTER MMU is enabled)
// r0 = start address of process code (in kernel image)
// r1 = end address of process code
// Returns: r0 = L1 table, r1 = entry point, r2 = stack pointer
// -----------------------------------------------------------------
.globl alloc_process
alloc_process:
    push {r4-r10, lr}
    mov r10, r0             // r10 = process code start
    mov r9, r1              // r9 = process code end (reused later)

    // ---- Allocate & zero process L1 table ----
    bl alloc_l1_table
    cmp r0, #0
    beq process_fail
    mov r4, r0              // r4 = L1 table base (physical)

    // Zero through higher-half virtual address
    ldr r1, =0x80000000
    add r1, r0, r1          // r1 = L1 table virtual addr
    ldr r2, =0x4000
    add r2, r1, r2
    mov r3, #0
1:  str r3, [r1], #4
    cmp r1, r2
    blo 1b

    // Compute L1 table virtual addr for writing descriptors
    ldr r5, =0x80000000
    add r5, r4, r5          // r5 = L1 table virtual addr

    // Identity map kernel (0x0 -> 0x0)
    mov r0, r5
    mov r1, #0
    mov r2, #0
    ldr r3, =0x402
    bl map_l1_section

    // Identity map UART (0x20200000 -> 0x20200000)
    mov r0, r5
    ldr r1, =0x20200000
    ldr r2, =0x20200000
    ldr r3, =0x402
    bl map_l1_section

    // Map 512MB higher-half (0x80000000+ -> 0x0+)
    ldr r6, =0x80000000
    mov r7, #0
    ldr r8, =512
2:
    mov r0, r5
    mov r1, r6
    mov r2, r7
    ldr r3, =0x402
    bl map_l1_section

    add r6, r6, #0x100000
    add r7, r7, #0x100000
    subs r8, r8, #1
    bne 2b

    // ---- Allocate L2 table ----
    bl alloc_l2_table
    cmp r0, #0
    beq process_fail
    mov r6, r0              // r6 = L2 table phys addr

    // Write L1 coarse descriptor: L1[1] -> L2 table
    // L1 index for virt 0x00100000 = 1, byte offset = 4
    orr r1, r6, #0x01       // coarse descriptor = L2 base | 0x01
    str r1, [r5, #4]        // L1[1] via virtual addr

    // ---- Allocate code page -> L2[0] (virt 0x00100000) ----
    bl alloc_page
    cmp r0, #0
    beq process_fail
    mov r7, r0              // r7 = code page phys addr

    // Write L2 entry via higher-half
    ldr r1, =0x80000000
    add r1, r6, r1          // r1 = L2 table virtual addr
    orr r2, r7, #0x30       // AP=0b11<<4
    orr r2, r2, #0x02       // Small page type
    str r2, [r1, #0]        // L2[0]

    // ---- Allocate heap page -> L2[1] (virt 0x00101000) ----
    bl alloc_page
    cmp r0, #0
    beq process_fail
    mov r8, r0              // r8 = heap page phys addr

    ldr r1, =0x80000000
    add r1, r6, r1
    orr r2, r8, #0x30
    orr r2, r2, #0x02
    str r2, [r1, #4]        // L2[1]

    // ---- Allocate stack page -> L2[2] (virt 0x00102000) ----
    bl alloc_page
    cmp r0, #0
    beq process_fail
    push {r0}               // Save stack page phys addr (out of regs)

    ldr r1, =0x80000000
    add r1, r6, r1
    orr r2, r0, #0x30
    orr r2, r2, #0x02
    str r2, [r1, #8]        // L2[2]

    // ---- Write process descriptor into L2 page (offset 0x400) ----
    // The L2 table only uses 1KB (0x000-0x3FF). We store the process
    // descriptor in the remaining 3KB, safe from user-mode access.
    // Layout: [count, L1p0, L1p1, L1p2, L1p3, L2, code, heap, stack]
    ldr r0, =0x80000000
    add r0, r6, r0          // r0 = L2 page virtual addr
    add r0, r0, #0x400      // skip past the 1KB L2 table entries
    pop {r3}                // r3 = stack page phys addr

    mov r1, #8
    str r1, [r0, #0]        // [0]  count = 8
    str r4, [r0, #4]        // [4]  L1 page 0
    add r1, r4, #0x1000
    str r1, [r0, #8]        // [8]  L1 page 1
    add r1, r4, #0x2000
    str r1, [r0, #12]       // [12] L1 page 2
    add r1, r4, #0x3000
    str r1, [r0, #16]       // [16] L1 page 3
    str r6, [r0, #20]       // [20] L2 table
    str r7, [r0, #24]       // [24] code page
    str r8, [r0, #28]       // [28] heap page
    str r3, [r0, #32]       // [32] stack page

    // ---- Register process in kernel process list ----
    ldr r0, =process_count
    ldr r1, [r0]
    ldr r2, =process_list
    str r6, [r2, r1, lsl #2]   // process_list[count] = L2 phys addr
    add r1, r1, #1
    str r1, [r0]               // process_count++

    // ---- Copy process code into code page (via higher-half) ----
    ldr r0, =0x80000000
    add r0, r7, r0          // dest = code page virtual addr
    mov r1, r10             // src = process code start (from argument)
    mov r2, r9              // end = process code end (from argument)
3:  cmp r1, r2
    bge 4f
    ldrb r3, [r1], #1
    strb r3, [r0], #1
    b 3b
4:

    // ---- Return ----
    ldr r0, =proc_alloc_msg
    bl uart_puts

    mov r0, r4              // r0 = L1 table base (physical)
    ldr r1, =0x00100000     // r1 = entry point (virtual)
    ldr r2, =0x00103000     // r2 = SP (top of stack page)
    pop {r4-r10, pc}

process_fail:
    mov r0, #0
    pop {r4-r10, pc}

// -----------------------------------------------------------------
// Delete Process
// r0 = L2 page physical address (used to find descriptor at +0x400)
// Reads the process descriptor, frees all listed pages, and removes
// the process from the kernel process list.
// Must be called with kernel page table active in TTBR0.
// -----------------------------------------------------------------
.globl delete_process
delete_process:
    push {r4-r7, lr}
    mov r4, r0              // r4 = L2 phys addr

    // Access descriptor via higher-half
    ldr r5, =0x80000000
    add r5, r4, r5
    add r5, r5, #0x400      // r5 = descriptor virtual addr

    // Read page count
    ldr r6, [r5, #0]        // r6 = count
    mov r7, #0              // r7 = index

.del_loop:
    cmp r7, r6
    bge .del_remove_from_list
    add r0, r7, #1          // entry offset = (index+1) * 4
    ldr r0, [r5, r0, lsl #2]
    bl free_page
    add r7, r7, #1
    b .del_loop

.del_remove_from_list:
    // Remove this process from process_list
    ldr r5, =process_count
    ldr r6, [r5]            // r6 = count
    ldr r7, =process_list
    mov r0, #0              // r0 = search index

.del_find:
    cmp r0, r6
    bge .del_done           // Not found (shouldn't happen)
    ldr r1, [r7, r0, lsl #2]
    cmp r1, r4              // Compare with our L2 addr
    beq .del_found
    add r0, r0, #1
    b .del_find

.del_found:
    // Shift remaining entries down by one
    add r1, r0, #1          // r1 = next index
.del_shift:
    cmp r1, r6
    bge .del_dec_count
    ldr r2, [r7, r1, lsl #2]
    str r2, [r7, r0, lsl #2]
    add r0, r0, #1
    add r1, r1, #1
    b .del_shift

.del_dec_count:
    sub r6, r6, #1
    str r6, [r5]            // process_count--

.del_done:
    ldr r0, =proc_deleted_msg
    bl uart_puts
    pop {r4-r7, pc}

// -----------------------------------------------------------------
// Allocate L2 Table (allocate a 4KB page and zero it)
// Returns physical address in r0 (0 if fail)
// -----------------------------------------------------------------
.globl alloc_l2_table
alloc_l2_table:
    push {r4, lr}
    bl alloc_page
    cmp r0, #0
    beq 1f

    // Zero the full 4KB page via higher-half virtual address
    mov r4, r0              // r4 = physical address (to return)
    ldr r1, =0x80000000
    add r1, r0, r1          // r1 = virtual address
    ldr r2, =0x1000
    add r2, r1, r2
    mov r3, #0
5:  str r3, [r1], #4
    cmp r1, r2
    blo 5b

    mov r0, r4
1:  pop {r4, pc}

// -----------------------------------------------------------------
// Allocate 4KB Page
// -----------------------------------------------------------------
.globl alloc_page
alloc_page:
    ldr r0, =page_table
    ldr r1, =NUM_PAGES
    mov r2, #0
1:  ldrb r3, [r0, r2]
    cmp r3, #0
    beq 2f
    add r2, r2, #1
    cmp r2, r1
    blt 1b
    mov r0, #0
    bx lr
2:  mov r3, #1
    strb r3, [r0, r2]
    lsl r0, r2, #12
    bx lr

// -----------------------------------------------------------------
// Free a 4KB Page
// r0 = physical address of the page to free
// -----------------------------------------------------------------
.globl free_page
free_page:
    lsr r1, r0, #12        // Convert address to page index
    ldr r0, =page_table
    mov r2, #0
    strb r2, [r0, r1]      // Mark page as free
    bx lr


.section ".bss"
page_table:
    .space NUM_PAGES

// Kernel globals
.globl kernel_l1_base
kernel_l1_base:
    .space 4                    // Physical addr of kernel's L1 table

.globl kernel_sp
kernel_sp:
    .space 4                    // Saved kernel stack pointer

.equ MAX_PROCESSES, 16
.globl process_count
process_count:
    .space 4                    // Number of active processes

.globl process_list
process_list:
    .space (MAX_PROCESSES * 4)  // L2 phys addrs (descriptor at +0x400)

.section ".rodata"
kernel_mmu_msg:
    .asciz "Kernel MMU tables ready.\r\n"
proc_alloc_msg:
    .asciz "Process allocated: L1, L2, code, heap, stack ready.\r\n"
proc_deleted_msg:
    .asciz "Process deleted: all pages freed.\r\n"