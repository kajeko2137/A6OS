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
// Allocate Process
// Returns L1 table address in r0
// -----------------------------------------------------------------
.globl alloc_process
alloc_process:
    push {r4, lr}           // Save r4 and link register
    
    bl alloc_l1_table
    cmp r0, #0
    beq process_fail
    
    mov r4, r0              // Save L1 table base in r4

    // Zero out the 16KB table to prevent MMU crashes
    mov r1, r0
    ldr r2, =0x4000
    add r2, r1, r2
    mov r3, #0
1:  str r3, [r1], #4        // Write 0 and increment r1 by 4
    cmp r1, r2
    blo 1b

    // Map Kernel (0x0 -> 0x0)
    mov r0, r4
    mov r1, #0
    mov r2, #0
    ldr r3, =0x402          // Privileged RW Section
    bl map_l1_section

    // Map UART (0x20200000 -> 0x20200000)
    mov r0, r4
    ldr r1, =0x20200000
    ldr r2, =0x20200000
    ldr r3, =0x402
    bl map_l1_section

    ldr r0, =mmu_map_msg
    bl uart_puts

    mov r0, r4              // Restore L1 address to return it
    pop {r4, pc}

process_fail:
    mov r0, #0
    pop {r4, pc}

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

.section ".bss"
page_table:
    .space NUM_PAGES

.section ".rodata"
mmu_map_msg:
    .asciz "Kernel and UART mapped to L1 Table.\r\n"