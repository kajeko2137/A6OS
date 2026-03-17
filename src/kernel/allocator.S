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

    // Identity map Timers & Interrupt Controller (0x20000000 -> 0x20000000)
    mov r0, r4
    ldr r1, =0x20000000
    ldr r2, =0x20000000
    ldr r3, =0x402
    bl map_l1_section

    // Identity map Hardware RNG (0x20100000 -> 0x20100000)
    mov r0, r4
    ldr r1, =0x20100000
    ldr r2, =0x20100000
    ldr r3, =0x402
    bl map_l1_section

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

    // Identity map Timers & Interrupt Controller (0x20000000 -> 0x20000000)
    mov r0, r5              
    ldr r1, =0x20000000
    ldr r2, =0x20000000
    ldr r3, =0x402
    bl map_l1_section

    // Identity map Hardware RNG (0x20100000 -> 0x20100000)
    mov r0, r5
    ldr r1, =0x20100000
    ldr r2, =0x20100000
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

    // ---- Allocate stack page -> L2[255] (virt 0x001FF000) ----
    bl alloc_page
    cmp r0, #0
    beq process_fail
    push {r0}               // Save stack page phys addr (out of regs)

    ldr r1, =0x80000000
    add r1, r6, r1
    orr r2, r0, #0x30
    orr r2, r2, #0x02
    str r2, [r1, #1020]        // L2[255]

    // ---- Write process descriptor into L2 page (offset 0x400) ----
    // The L2 table only uses 1KB (0x000-0x3FF). We store the process
    // descriptor in the remaining 3KB, safe from user-mode access.
    // Layout: [count, L1p0, L1p1, L1p2, L1p3, L2, code, heap, stack, r0-r12, usr_sp, usr_lr, usr_pc, usr_cpsr]
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

    // Write initial process context
    // Process starts at PC=0x00100000, SP=0x00200000, CPSR=User Mode (0x10)
    ldr r1, =0x00100000
    str r1, [r0, #96]       // [96] usr_pc
    ldr r1, =0x00200000
    str r1, [r0, #88]       // [88] usr_sp
    mov r1, #0              // lr is whatever
    str r1, [r0, #92]       // [92] usr_lr
    mov r1, #0x10           // User Mode
    str r1, [r0, #100]      // [100] usr_cpsr

    // Initialize heap_end and next_l2
    ldr r1, =0x00102000
    sub r2, r0, #0x400      // r2 = L2 page virtual addr
    str r1, [r2, #0xFF8]    // heap_end
    mov r1, #0
    str r1, [r2, #0xFFC]    // next_l2

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
    // Clean D-cache for the copied region by MVA (ARM1176 doesn't support entire D-cache clean)
    ldr r1, =0x80000000
    add r1, r7, r1          // r1 = start of copied region
5:  cmp r1, r0              // r0 = end of copied region
    bge 6f
    mcr p15, 0, r1, c7, c10, 1  // Clean D-cache single entry by MVA
    add r1, r1, #32             // 32-byte cache line
    b 5b
6:

    // ---- Return ----
    mov r0, r6              // r0 = L2 table base (physical descriptor handle)
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
    push {r4-r8, lr}
    mov r4, r0              // r4 = current L2 phys addr (starts with initial)
    mov r8, r0              // r8 = save initial L2 phys addr (for process_list removal)

.del_l2_loop:
    cmp r4, #0
    beq .del_remove_from_list

    // Access descriptor via higher-half
    ldr r5, =0x80000000
    add r5, r4, r5

    // Read next_l2 before freeing anything! (in case r4 is freed in this loop)
    ldr r0, [r5, #0xFFC]
    push {r0}               // Save next_l2 for later

    add r5, r5, #0x400      // r5 = descriptor virtual addr

    // Read page count
    ldr r6, [r5, #0]        // r6 = count
    mov r7, #0              // r7 = index

.del_loop:
    cmp r7, r6
    bge .del_l2_done
    add r0, r7, #1          // entry offset = (index+1) * 4
    ldr r0, [r5, r0, lsl #2]
    bl free_page
    add r7, r7, #1
    b .del_loop

.del_l2_done:
    pop {r4}                // r4 = next_l2
    b .del_l2_loop

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
    cmp r1, r8              // Compare with our initial L2 addr
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
    pop {r4-r8, pc}

// -----------------------------------------------------------------
// Allocate a New Page for the Calling Process
// Called from SWI handler while process page table is active.
// Uses a heap_end pointer in the initial L2 table for O(1) allocation,
// expanding the process map by creating new L2 tables as necessary.
// Returns: r0 = virtual address of new page (0 if fail)
// -----------------------------------------------------------------
.globl alloc_process_page
alloc_process_page:
    push {r4-r10, lr}

    // Get L1 virt addr
    mrc p15, 0, r0, c2, c0, 0
    ldr r1, =0x80000000
    add r4, r0, r1              // r4 = L1 virtual addr

    // Load initial L2 table physical address
    ldr r6, [r4, #4]            // L1[1] is the initial L2 table
    bic r6, r6, #0xFF           // r6 = initial L2 phys addr

    // Load heap_end
    add r7, r6, r1              // r1 is 0x80000000, r7 = initial L2 virt addr
    ldr r5, [r7, #0xFF8]        // r5 = heap_end (e.g. 0x00102000)

    // Check bounds (e.g. 2GB max for user space)
    ldr r1, =0x70000000
    cmp r5, r1
    bge .alloc_pg_fail

    // Skip stack page if we hit it
    ldr r1, =0x001FF000
    cmp r5, r1
    bne .allocate_at_heap_end
    add r5, r5, #0x1000

.allocate_at_heap_end:
    // Update heap_end
    add r8, r5, #0x1000
    str r8, [r7, #0xFF8]        // save new heap_end

    // Use r5 as our Virtual Address
    lsr r8, r5, #20             // r8 = L1 index
    
    ldr r9, =0xFFFFF
    and r9, r5, r9
    lsr r9, r9, #12             // r9 = L2 index

    // Get or Create L2 table
    ldr r10, [r4, r8, lsl #2]   // read L1[r8]
    cmp r10, #0
    bne .l1_exists_bump

    // Need a new L2 table
    bl alloc_l2_table
    cmp r0, #0
    beq .alloc_pg_fail
    mov r10, r0                 // r10 = new L2 phys
    
    // Write L1 entry
    orr r1, r10, #0x01
    str r1, [r4, r8, lsl #2]

    // Add new L2 to descriptor
    mov r0, r10
    bl desc_add

    bic r10, r10, #0xFF
    b .do_map

.l1_exists_bump:
    bic r10, r10, #0xFF         // r10 = L2 phys

.do_map:
    ldr r1, =0x80000000
    add r10, r10, r1            // r10 = L2 virt addr

    // Allocate physical page
    bl alloc_page
    cmp r0, #0
    beq .alloc_pg_fail
    mov r6, r0                  // r6 = new page phys

    // Map page (Small, AP=3)
    orr r1, r6, #0x32
    str r1, [r10, r9, lsl #2]

    // Add to descriptor
    mov r0, r6
    bl desc_add

    // Invalidate TLB
    mov r1, #0
    mcr p15, 0, r1, c8, c7, 0
    mcr p15, 0, r1, c7, c5, 4

    // Return virtual address in r0
    mov r0, r5

    pop {r4-r10, pc}

.alloc_pg_fail:
    mov r0, #0
    pop {r4-r10, pc}

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
// Free a Page belonging to the Calling Process
// Called from SWI handler (SWI 3) while process page table is active.
// r0 = Virtual Address to free.
// 1. Decodes Virtual Address to find correct L1/L2 pages.
// 2. Unmaps L2 entry.
// 3. Removes physical address from descriptor chain and frees physical memory.
// Returns: r0 = 0 (Success), or -1 (Error)
// -----------------------------------------------------------------
.globl free_process_page
free_process_page:
    push {r4-r8, lr}
    mov r4, r0                  // r4 = requested virtual address

    // 1. Validate virtual address bounds
    ldr r1, =0x00102000         // Lowest valid dynamic addr (L1=1, L2=2)
    cmp r4, r1
    blt .free_pg_fail

    lsr r5, r4, #20             // r5 = L1 index
    ldr r1, =2048               // Arbitrary max (use first 2GB)
    cmp r5, r1
    bge .free_pg_fail

    // Protect stack page at 0x001FF000
    cmp r5, #1
    bne 1f
    ldr r1, =0x001FF000
    cmp r4, r1
    bge .free_pg_fail           // Out of bounds for L1=1 (protect stack and above)
1:
    // Check page alignment (must be 4KB aligned)
    ldr r1, =0xFFF
    tst r4, r1
    bne .free_pg_fail

    // 2. Map virtual address to physical L2 table list
    mrc p15, 0, r0, c2, c0, 0   // r0 = process L1 phys addr
    ldr r1, =0x80000000
    add r0, r0, r1               // r0 = L1 virtual addr
    
    ldr r6, [r0, r5, lsl #2]     // get L1 entry
    cmp r6, #0
    beq .free_pg_fail           // Not mapped

    bic r6, r6, #0xFF            // r6 = L2 phys addr

    // 3. Access L2 table & compute L2 index
    ldr r1, =0xFFFFF
    and r7, r4, r1               // r7 = offset within 1MB
    lsr r7, r7, #12              // r7 = L2 index

    ldr r1, =0x80000000
    add r0, r6, r1               // r0 = L2 virtual table addr

    ldr r8, [r0, r7, lsl #2]     // Read L2 entry
    cmp r8, #0
    beq .free_pg_fail            // Already vacant

    // Unmap from L2
    mov r1, #0
    str r1, [r0, r7, lsl #2]     // Clear L2 entry

    // Extract physical address (Top 20 bits)
    ldr r1, =0xFFFFF000
    and r8, r8, r1               // r8 = physical page address

    push {r0}                    // Save L2 virtual addr

    // 4. Remove from descriptor chain
    mov r0, r8
    bl desc_remove

    // 5. Free physical memory
    mov r0, r8
    bl free_page

    pop {r0}                     // Restore L2 virtual addr

    // ---- Check if L2 table is empty ----
    cmp r5, #1
    beq .skip_l2_free           // Never free the initial L2 table (holds process descriptor!)

    // Scan L2 table
    mov r1, #0
.l2_empty_check:
    cmp r1, #256
    bge .l2_is_empty
    ldr r2, [r0, r1, lsl #2]
    cmp r2, #0
    bne .skip_l2_free           // Found an entry, not empty
    add r1, r1, #1
    b .l2_empty_check

.l2_is_empty:
    // Remove L2 from descriptor
    // r6 still contains L2 phys addr
    mov r0, r6
    bl desc_remove

    // Clear L1 entry
    mrc p15, 0, r1, c2, c0, 0
    ldr r2, =0x80000000
    add r1, r1, r2
    mov r2, #0
    str r2, [r1, r5, lsl #2]    // L1[L1_index] = 0

    // Free L2 table
    mov r0, r6
    bl free_page

.skip_l2_free:
    // Invalidate TLB completely
    mov r1, #0
    mcr p15, 0, r1, c8, c7, 0   // Invalidate entire TLB
    mcr p15, 0, r1, c7, c5, 4   // Flush Prefetch Buffer

    mov r0, #0                  // Success
    pop {r4-r8, pc}

.free_pg_fail:
    mov r0, #-1                 // Failed
    pop {r4-r8, pc}

// -----------------------------------------------------------------
// Allocate Specific Virtual Page (Lazy Allocation)
// r0 = virtual address to map (guaranteed page-aligned by caller?)
// -----------------------------------------------------------------
.globl alloc_specific_page
alloc_specific_page:
    push {r4-r10, lr}
    
    // Align virtual address down to 4KB
    ldr r1, =0xFFFFF000
    and r5, r0, r1              // r5 = aligned virtual address

    // Get L1 virt addr
    mrc p15, 0, r0, c2, c0, 0
    ldr r1, =0x80000000
    add r4, r0, r1              // r4 = L1 virtual addr

    // Calculate indices
    lsr r8, r5, #20             // r8 = L1 index
    ldr r1, =0xFFFFF
    and r9, r5, r1
    lsr r9, r9, #12             // r9 = L2 index

    // Get or Create L2 table
    ldr r10, [r4, r8, lsl #2]   // read L1[r8]
    cmp r10, #0
    bne .lazy_l1_exists

    // Need a new L2 table
    bl alloc_l2_table
    cmp r0, #0
    beq .lazy_pg_fail
    mov r10, r0                 // r10 = new L2 phys
    
    // Write L1 entry
    orr r1, r10, #0x01
    str r1, [r4, r8, lsl #2]

    // Add new L2 to descriptor
    mov r0, r10
    bl desc_add

    bic r10, r10, #0xFF
    b .lazy_do_map

.lazy_l1_exists:
    bic r10, r10, #0xFF         // r10 = L2 phys

.lazy_do_map:
    ldr r1, =0x80000000
    add r10, r10, r1            // r10 = L2 virt addr

    // Ensure it's not already mapped
    ldr r1, [r10, r9, lsl #2]
    cmp r1, #0
    bne .lazy_pg_fail           // Already mapped! Memory collision?

    // Allocate physical page
    bl alloc_page
    cmp r0, #0
    beq .lazy_pg_fail
    mov r6, r0                  // r6 = new page phys

    // Map page (Small, AP=3)
    orr r1, r6, #0x32
    str r1, [r10, r9, lsl #2]

    // Add to descriptor
    mov r0, r6
    bl desc_add

    // Invalidate TLB
    mov r1, #0
    mcr p15, 0, r1, c8, c7, 0
    mcr p15, 0, r1, c7, c5, 4

    // Return virtual address in r0
    mov r0, r5

    pop {r4-r10, pc}

    pop {r4-r10, pc}

.lazy_pg_fail:
    mov r0, #0
    pop {r4-r10, pc}

// -----------------------------------------------------------------
// Helper: Add Physical Page Address to Process Descriptor Chain
// r0 = physical address to add
// Modifies descriptor spanning multiple L2 page metadata blocks if needed
// -----------------------------------------------------------------
desc_add:
    push {r4-r8, lr}
    mov r8, r0                  // r8 = phys addr to add

    // Get process first L2 table (phys) via TTBR0 -> L1[1]
    mrc p15, 0, r1, c2, c0, 0
    ldr r2, =0x80000000
    add r1, r1, r2
    ldr r1, [r1, #4]            // L1[1]
    bic r4, r1, #0xFF           // r4 = first L2 phys addr

.desc_find_space:
    ldr r5, =0x80000000
    add r5, r4, r5              // r5 = L2 virtual addr

    // read next_l2 pointer at offset 0xFFC
    ldr r6, [r5, #0xFFC]
    
    add r5, r5, #0x400          // r5 = descriptor base
    ldr r7, [r5, #0]            // r7 = count
    ldr r1, =766
    cmp r7, r1
    blt .desc_do_add

    // No space. Is there a next_l2 already?
    cmp r6, #0
    bne .desc_next_l2

    // Descriptor area is full. Allocate a new L2 page just for chaining descriptors!
    bl alloc_l2_table
    cmp r0, #0
    beq .desc_add_fail
    mov r6, r0                  // r6 = new L2 phys addr

    // Link it from current L2's next_l2 offset
    ldr r5, =0x80000000
    add r5, r4, r5
    str r6, [r5, #0xFFC]

    // Init new L2 page descriptor count to 0
    ldr r5, =0x80000000
    add r5, r6, r5
    mov r1, #0
    str r1, [r5, #0x400]        // count = 0

    // Important: we also must register the new L2 page itself into the process' descriptors list
    // so it can be automatically freed! Recurse to add it.
    mov r0, r6
    bl desc_add

.desc_next_l2:
    mov r4, r6
    b .desc_find_space

.desc_do_add:
    add r7, r7, #1              // count++
    str r7, [r5, #0]
    str r8, [r5, r7, lsl #2]    // store phys addr at desc[count]

.desc_add_fail:
    pop {r4-r8, pc}

// -----------------------------------------------------------------
// Helper: Remove Physical Page Address from Process Descriptor Chain
// r0 = physical address to remove
// -----------------------------------------------------------------
desc_remove:
    push {r4-r8, lr}
    mov r8, r0                  // r8 = phys addr to remove

    // Get first L2 from L1[1]
    mrc p15, 0, r1, c2, c0, 0
    ldr r2, =0x80000000
    add r1, r1, r2
    ldr r1, [r1, #4]
    bic r4, r1, #0xFF           // r4 = L2 phys chain start

.desc_rem_l2_loop:
    cmp r4, #0
    beq .desc_rem_fail          // Not found

    ldr r5, =0x80000000
    add r5, r4, r5
    
    // read next_l2
    ldr r6, [r5, #0xFFC]

    add r5, r5, #0x400          // r5 = descriptor base
    ldr r7, [r5, #0]            // r7 = count
    mov r1, #1                  // r1 = start index 1

.desc_rem_search:
    cmp r1, r7
    bgt .desc_rem_next_l2       // jump to next L2 page in chain
    ldr r2, [r5, r1, lsl #2]
    cmp r2, r8
    beq .desc_rem_found
    add r1, r1, #1
    b .desc_rem_search

.desc_rem_found:
    // Shift elements down
.desc_rem_shift:
    add r2, r1, #1
    cmp r2, r7
    bgt .desc_rem_shrink
    ldr r3, [r5, r2, lsl #2]
    str r3, [r5, r1, lsl #2]
    add r1, r1, #1
    b .desc_rem_shift

.desc_rem_shrink:
    sub r7, r7, #1
    str r7, [r5, #0]
    b .desc_rem_done

.desc_rem_next_l2:
    mov r4, r6
    b .desc_rem_l2_loop

.desc_rem_done:
.desc_rem_fail:
    pop {r4-r8, pc}

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