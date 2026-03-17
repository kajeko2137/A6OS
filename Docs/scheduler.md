# A6OS Scheduler Architecture Specification

## 1. Overview
The A6OS scheduler is a custom Tiered Lottery Scheduler highly optimized for the ARM1176JZF-S (BCM2835) bare-metal environment. It is designed as a low-latency microkernel scheduler, prioritizing a mathematically instant, $O(1)$ context switch on the hardware timer tick over infinite, desktop-level scaling.

At a high level, the system divides all active processes into 4 distinct priority tiers (Tier 0 through Tier 3). Each process within a tier is assigned a fixed number of "tickets" based on its tier (for example, Tier 0 processes might receive 20 tickets each, while Tier 3 processes receive only 5). On every hardware tick, the kernel calculates the total pool of active tickets and draws a random winning ticket using a blazing-fast software Xorshift algorithm. Because ticket weights are uniform within each tier, the scheduler can mathematically compute the exact array index of the winning process instantly, bypassing traditional ticket-counting loops entirely.

## 2. Memory Layout (The 5-Array Ring Buffer)
To eliminate memory fragmentation and avoid dynamic allocation inside interrupts, the scheduler relies on static arrays and zero-copy pointer swapping.

The `.bss` section will manage:
- **5 Physical Buffers:** `buf0`, `buf1`, `buf2`, `buf3`, and `buf_sink` (acting as the permanent Tier 3 accumulator).
- **4 Tier Pointers:** `*t0`, `*t1`, `*t2`, `*t3`.
- **4 Counters:** `q0_count`, `q1_count`, `q2_count`, `q3_count`.

At boot, the pointers map 1:1 to the buffers (`t0` -> `buf0`, etc.), with `t3` permanently mapped to `buf_sink`.

## 3. The Hot Path (10ms Hardware Tick)
The hardware timer fires every 10,000 microseconds (10ms). Because every process within a specific tier is guaranteed to have the exact same ticket weight, the scheduler bypasses traditional $O(n)$ ticket-counting loops.

**Execution Flow ($O(1)$ Time Complexity):**
1. **Calculate Total Tickets:** Multiply each tier's process count by its fixed tier weight and sum them.
2. **Draw Ticket:** Generate a random number using the software Xorshift PRNG.
3. **Find Tier:** Use simple comparisons to determine which tier the winning ticket falls into.
4. **Find Index:** Calculate `Random % Tier_Count` to get the exact array index.
5. **Execute:** Load the process address from `tX[Winning_Index]` and perform the context switch.

## 4. The Cold Path (100ms Downgrade)
Every 100ms, the system penalizes CPU-heavy processes by dropping them down a priority tier. This is achieved almost entirely via zero-copy pointer manipulation to keep CPU overhead microscopic.

**Execution Flow:**
- **The Accumulator ($O(n)$):** Append all elements from the array pointed to by `t2` into `t3` (`buf_sink`).
- **The Pointer Swap ($O(1)$):**
  1. Save `t2`'s now-empty buffer address as `free_buffer`.
  2. Rotate pointers downwards: `t2 = t1`, then `t1 = t0`.
  3. Assign the empty buffer to the top: `t0 = free_buffer`.

## 5. The Reset Path (1000ms Starvation Prevention)
Every 1 second, all processes are hoisted back to Tier 0 to prevent total starvation of low-priority tasks.

**Execution:** All active processes are copied out of their respective arrays and flattened into the `buf0` array.

**Hardware Limit:** This action relies on the ARM11's 16KB L1 Data Cache for extreme speed. The scheduler will remain blazingly fast up to approximately 4,000 processes, at which point the L1 cache will overflow and cause minor latency spikes during the 1-second reset.

## 6. Random Number Generation
- **Seeding:** The Hardware RNG peripheral (`0x20104000`) is read exactly once during the kernel boot sequence to generate a cryptographically secure 32-bit seed.
- **Generation:** All subsequent random numbers required by the 10ms Hot Path are generated using a pure-software 32-bit Xorshift algorithm. This avoids the massive Memory-Mapped I/O latency penalty of polling the hardware RNG peripheral during a critical interrupt.