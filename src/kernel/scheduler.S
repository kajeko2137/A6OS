.equ MAX_PROCS_PER_TIER, 256
.equ QUEUE_SIZE,         (MAX_PROCS_PER_TIER * 4) // 4 bytes per process address

// Hardware RNG Peripheral Registers
.equ RNG_CTRL,           0x20104000
.equ RNG_STATUS,         0x20104004
.equ RNG_DATA,           0x20104008

// -----------------------------------------------------------------
// .bss Section: The 5-Array Ring Buffer Memory Layout
// -----------------------------------------------------------------
.section ".bss"
.align 4

// 1. The 5 Physical Buffers
buf0:       .space QUEUE_SIZE
buf1:       .space QUEUE_SIZE
buf2:       .space QUEUE_SIZE
buf3:       .space QUEUE_SIZE
buf_sink:   .space QUEUE_SIZE

// 2. The Tier Pointers
.globl t0, t1, t2, t3, free_buffer
t0:             .space 4
t1:             .space 4
t2:             .space 4
t3:             .space 4
free_buffer:    .space 4

// 3. The Tier Counters
.globl q0_count, q1_count, q2_count, q3_count
q0_count:       .space 4
q1_count:       .space 4
q2_count:       .space 4
q3_count:       .space 4

// 4. The RNG State (Xorshift Seed)
.globl rng_state
rng_state:      .space 4

// -----------------------------------------------------------------
// .text Section
// -----------------------------------------------------------------
.section ".text.scheduler"

// Initialize the TLS memory structures and hardware RNG
.globl init_TLS
init_TLS:
    push {lr}

    // 1. Map initial pointers to physical buffers
    ldr r0, =buf0
    ldr r1, =t0
    str r0, [r1]

    ldr r0, =buf1
    ldr r1, =t1
    str r0, [r1]

    ldr r0, =buf2
    ldr r1, =t2
    str r0, [r1]

    // t3 permanently points to the sink accumulator
    ldr r0, =buf_sink
    ldr r1, =t3
    str r0, [r1]

    // buf3 starts as our empty reserve buffer
    ldr r0, =buf3
    ldr r1, =free_buffer
    str r0, [r1]

    // 2. Wake up the Hardware RNG (The Stark Way)
    ldr r0, =RNG_STATUS
    ldr r1, =0x40000        // Load the 262k warm-up count
    str r1, [r0]            // Tell the silicon to discard initial cold bits

    ldr r0, =RNG_CTRL
    mov r1, #1
    str r1, [r0]            // Now enable the RNG hardware

1:  // 3. Spin-wait for the silicon FIFO to contain at least 1 word
    ldr r0, =RNG_STATUS
    ldr r1, [r0]
    lsr r1, r1, #24         // Shift right 24 bits to read the FIFO count
    cmp r1, #0
    beq 1b                  // If 0 words available, keep waiting

    // 4. Read the true random seed and store it
    ldr r0, =RNG_DATA
    ldr r1, [r0]
    ldr r2, =rng_state
    str r1, [r2]

    // 5. Done initializing
    pop {pc}

// -----------------------------------------------------------------
// .data Section: State Variables
// -----------------------------------------------------------------
.section ".data"
.align 4
tick_counter:      .word 0     // Tracks 10ms invocations
downgrade_counter: .word 0     // Tracks 100ms invocations
.globl current_process
current_process: .word 0     // Phys addr of L2 table for current process

// -----------------------------------------------------------------
// .text Section: The Scheduler Core
// -----------------------------------------------------------------
.section ".text.scheduler"

// Fast Software PRNG (Xorshift32)
// Executes in ~5 cycles. Returns random 32-bit integer in r0.
.globl xorshift32
xorshift32:
    ldr r1, =rng_state
    ldr r0, [r1]
    
    eor r0, r0, r0, lsl #13     // x ^= x << 13
    eor r0, r0, r0, lsr #17     // x ^= x >> 17
    eor r0, r0, r0, lsl #5      // x ^= x << 5
    
    str r0, [r1]
    bx lr

// The 100ms Downgrade Placeholder
.globl downgrade_tiers
downgrade_tiers:
    push {r4-r9, lr}

    // -------------------------------------------------------------
    // Phase 1: Append Tier 2 into Tier 3
    // -------------------------------------------------------------
    ldr r4, =q2_count
    ldr r4, [r4]                // r4 = count of items in Tier 2
    cmp r4, #0
    beq .skip_append            // Nothing to append if Tier 2 is empty

    ldr r5, =q3_count
    ldr r6, [r5]                // r6 = current count in Tier 3 (Sink)

    ldr r7, =t2
    ldr r7, [r7]                // r7 = src buffer (Tier 2 array base)
    
    ldr r8, =t3
    ldr r8, [r8]                // r8 = dst buffer (Tier 3 array base)
    add r8, r8, r6, lsl #2      // r8 = dst pointer offset by current count

    mov r9, #0                  // r9 = loop counter
.append_loop:
    ldr r0, [r7, r9, lsl #2]    // read from Tier 2
    str r0, [r8], #4            // write to Tier 3 and increment destination pointer
    
    add r9, r9, #1
    cmp r9, r4
    blt .append_loop

    // Update Tier 3 count: q3_count += q2_count
    add r6, r6, r4
    str r6, [r5]

.skip_append:
    // -------------------------------------------------------------
    // Phase 2: Rotate tier array pointers
    // -------------------------------------------------------------
    
    // Save t2's now-empty buffer as the new free_buffer candidate
    ldr r4, =free_buffer
    ldr r5, =t2
    ldr r6, [r5]                // r6 = old buf2 address
    str r6, [r4]                // free_buffer = old buf2

    // t2 becomes t1
    ldr r6, =t1
    ldr r7, [r6]                // r7 = old buf1 address
    str r7, [r5]                // t2 = old buf1

    // t1 becomes t0
    ldr r7, =t0
    ldr r8, [r7]                // r8 = old buf0 address
    str r8, [r6]                // t1 = old buf0

    // t0 gets the reserved free buffer (which we know is empty)
    ldr r4, =buf3               // Note: During the first rotation, buf3 is the reserved empty start buffer
    ldr r8, =free_buffer
    ldr r8, [r8]                // Fetch whatever the real current free_buffer is
    str r8, [r7]                // t0 = empty buffer

    // Update the queue counts
    ldr r4, =q0_count
    ldr r5, =q1_count
    ldr r6, =q2_count

    ldr r7, [r5]                // load q1 count
    str r7, [r6]                // q2 count = old q1 count

    ldr r7, [r4]                // load q0 count
    str r7, [r5]                // q1 count = old q0 count

    mov r7, #0
    str r7, [r4]                // q0 count is now 0 (new processes only!)

    pop {r4-r9, pc}

// The 1000ms Reset Array Flattening
.globl reset_tiers
reset_tiers:
    push {r4-r9, lr}

    // Flatten all tiers into t0
    // First, load t0 pointer and q0_count
    ldr r4, =t0
    ldr r4, [r4]                // r4 = dst buffer (buf0)
    ldr r5, =q0_count
    ldr r6, [r5]                // r6 = current q0 count
    add r4, r4, r6, lsl #2      // r4 = end of buf0 pointer

    // Append t1
    ldr r7, =q1_count
    ldr r8, [r7]
    cmp r8, #0
    beq .skip_reset_t1

    ldr r9, =t1
    ldr r9, [r9]                // r9 = src buffer (Tier 1)
    mov r0, #0
.reset_t1_loop:
    ldr r1, [r9, r0, lsl #2]
    str r1, [r4], #4
    add r0, r0, #1
    cmp r0, r8
    blt .reset_t1_loop

    add r6, r6, r8              // q0_count += q1_count
    mov r0, #0
    str r0, [r7]                // q1_count = 0

.skip_reset_t1:

    // Append t2
    ldr r7, =q2_count
    ldr r8, [r7]
    cmp r8, #0
    beq .skip_reset_t2

    ldr r9, =t2
    ldr r9, [r9]                // r9 = src buffer (Tier 2)
    mov r0, #0
.reset_t2_loop:
    ldr r1, [r9, r0, lsl #2]
    str r1, [r4], #4
    add r0, r0, #1
    cmp r0, r8
    blt .reset_t2_loop

    add r6, r6, r8              // q0_count += q2_count
    mov r0, #0
    str r0, [r7]                // q2_count = 0

.skip_reset_t2:

    // Append t3 (sink)
    ldr r7, =q3_count
    ldr r8, [r7]
    cmp r8, #0
    beq .skip_reset_t3

    ldr r9, =t3
    ldr r9, [r9]                // r9 = src buffer (Tier 3)
    mov r0, #0
.reset_t3_loop:
    ldr r1, [r9, r0, lsl #2]
    str r1, [r4], #4
    add r0, r0, #1
    cmp r0, r8
    blt .reset_t3_loop

    add r6, r6, r8              // q0_count += q3_count
    mov r0, #0
    str r0, [r7]                // q3_count = 0

.skip_reset_t3:
    // Update newly accumulated q0_count!
    str r6, [r5]

    pop {r4-r9, pc}

// The 10ms Timer Interrupt Handler
.globl reschedule
reschedule:
    push {r4-r8, lr}

    // -------------------------------------------------------------
    // 1. Tick Counter Trigger
    // -------------------------------------------------------------
    ldr r4, =tick_counter
    ldr r5, [r4]
    add r5, r5, #1
    cmp r5, #10                 // Have we hit 10 ticks (100ms)?
    bne 1f

    // We hit 100ms: Reset tick counter
    mov r5, #0
    str r5, [r4]
    
    // Check downgrade counter
    ldr r4, =downgrade_counter
    ldr r5, [r4]
    add r5, r5, #1
    cmp r5, #10                 // Have we hit 10 downgrades (1000ms)?
    bne .do_downgrade

    // We hit 1000ms: Reset downgrade counter and perform reset_tiers
    mov r5, #0
    str r5, [r4]
    bl reset_tiers
    b 2f                        // Resume scheduling

.do_downgrade:
    str r5, [r4]                // Save incremented downgrade counter
    bl downgrade_tiers
    b 2f                        // Resume scheduling
1:
    str r5, [r4]                // Save incremented tick counter

2:
    // -------------------------------------------------------------
    // 2. Calculate Total Tickets (O(1) Hot Path)
    // Weights: T0=16, T1=8, T2=4, T3=1
    // -------------------------------------------------------------
    ldr r4, =q0_count
    ldr r5, [r4]
    lsl r5, r5, #4              // T0_tickets = q0 * 16

    ldr r4, =q1_count
    ldr r6, [r4]
    lsl r6, r6, #3              // T1_tickets = q1 * 8

    ldr r4, =q2_count
    ldr r7, [r4]
    lsl r7, r7, #2              // T2_tickets = q2 * 4

    ldr r4, =q3_count
    ldr r8, [r4]                // T3_tickets = q3 * 1

    // Sum all tickets into r4
    add r4, r5, r6
    add r4, r4, r7
    add r4, r4, r8

    cmp r4, #0
    beq system_idle_fallback    // If 0 tickets, skip context switch

    // -------------------------------------------------------------
    // 3. Draw Ticket
    // -------------------------------------------------------------
    bl xorshift32               // r0 = Random 32-bit number
    
    // r0 * r4 (Total Tickets) -> lower 32 in r1, upper 32 in r2
    umull r1, r2, r0, r4        
    mov r0, r2                  // r0 is now our winning ticket!

    // -------------------------------------------------------------
    // 4. Find Tier and Index
    // -------------------------------------------------------------
    cmp r0, r5
    bhs check_t1                // If ticket >= T0_tickets, check Tier 1

    // --- Tier 0 Wins ---
    lsr r1, r0, #4              // Index = Ticket / 16
    ldr r2, =t0
    ldr r2, [r2]                // Load buf0 physical address
    ldr r0, [r2, r1, lsl #2]    // r0 = Process Address (Index * 4)
    b execute_context_switch

check_t1:
    sub r0, r0, r5              // Subtract T0_tickets
    cmp r0, r6
    bhs check_t2

    // --- Tier 1 Wins ---
    lsr r1, r0, #3              // Index = Ticket / 8
    ldr r2, =t1
    ldr r2, [r2]
    ldr r0, [r2, r1, lsl #2]
    b execute_context_switch

check_t2:
    sub r0, r0, r6              // Subtract T1_tickets
    cmp r0, r7
    bhs check_t3

    // --- Tier 2 Wins ---
    lsr r1, r0, #2              // Index = Ticket / 4
    ldr r2, =t2
    ldr r2, [r2]
    ldr r0, [r2, r1, lsl #2]
    b execute_context_switch

check_t3:
    // --- Tier 3 Wins ---
    sub r0, r0, r7              // Subtract T2_tickets
    mov r1, r0                  // Index = Ticket / 1
    ldr r2, =t3
    ldr r2, [r2]
    ldr r0, [r2, r1, lsl #2]
    b execute_context_switch

system_idle_fallback:
    pop {r4-r8, lr}
    
.globl system_idle
system_idle:
    // Check if we have a pending reschedule 
    // (set by timer interrupt returning to SVC WFI loop)
    ldr r0, =needs_reschedule
    ldr r1, [r0]
    cmp r1, #1
    beq .call_reschedule
    wfi
    b system_idle
.call_reschedule:
    mov r1, #0
    str r1, [r0]
    b reschedule

execute_context_switch:
    // We arrived here from `reschedule` math, which pushed r4-r8, lr.
    // Pop them now since we are abandoning this SVC stack frame!
    pop {r4-r8, lr}

    // Success! r0 now holds the exact Process Descriptor Address.
    // Set current_process
    ldr r1, =current_process
    str r0, [r1]

    // r0 holds physical address of L2 descriptor table
    ldr r1, =0x80000000
    add r2, r0, r1
    add r2, r2, #0x400          // r2 = descriptor base (virtual)

    // Set TTBR0
    ldr r1, [r2, #4]            // L1 physical address
    mcr p15, 0, r1, c2, c0, 0   // Switch TTBR0
    
    // Invalidate TLB and Prefetch
    mov r1, #0
    mcr p15, 0, r1, c8, c7, 0
    mcr p15, 0, r1, c7, c5, 4
    
    // Restore Context
    // Restore User SPSR (we're in SVC mode, so spsr_svc is populated)
    ldr r3, [r2, #100]          // usr_cpsr
    msr spsr_cxsf, r3
    
    // Restore User SP and LR using System Mode trampoline
    mrs r3, cpsr
    bic r4, r3, #0x1F
    orr r4, r4, #0x1F
    msr cpsr_c, r4
    
    ldr sp, [r2, #88]           // usr_sp
    ldr lr, [r2, #92]           // usr_lr
    
    msr cpsr_c, r3              // Jump back to SVC mode
    
    // Restore target PC into our current LR (for the eventual movs pc, lr return)
    ldr lr, [r2, #96]           // usr_pc
    
    // Restore r0-r12
    add r1, r2, #36             // r1 = saved r0 offset
    ldmia r1, {r0-r12}
    
    // Return to user space
    movs pc, lr