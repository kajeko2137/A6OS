# AOS Scheduler Architecture Specification

## 1. Overview
The AOS scheduler is a custom Tiered Lottery Scheduler optimized for the ARM1176JZF-S (BCM2835) bare-metal environment. It uses an O(1) context switch triggered by a hardware timer.

The system divides active processes into 4 priority tiers (Tier 0 through Tier 3). Each process within a tier is assigned a fixed number of tickets based on its tier (e.g., Tier 0 receives 16 tickets, Tier 1 receives 8, Tier 2 receives 4, Tier 3 receives 1). On every hardware tick, the kernel calculates the total pool of active tickets and draws a random winning ticket using a software Xorshift algorithm. Because ticket weights are uniform within each tier, the scheduler computes the exact array index of the winning process mathematically, bypassing ticket-counting loops.

## 2. Memory Layout (Ring Buffer)
To eliminate memory fragmentation and avoid dynamic allocation inside interrupts, the scheduler relies on static arrays and pointer swapping.

The `.bss` section manages:
- **5 Physical Buffers:** `buf0`, `buf1`, `buf2`, `buf3`, and `buf_sink` (acting as the permanent Tier 3 accumulator).
- **4 Tier Pointers:** `*t0`, `*t1`, `*t2`, `*t3`.
- **4 Counters:** `q0_count`, `q1_count`, `q2_count`, `q3_count`.

At boot, the pointers map 1:1 to the buffers (`t0` -> `buf0`, etc.), with `t3` permanently mapped to `buf_sink`. `buf3` is initially reserved as an empty buffer.

## 3. Hardware Tick (10ms)
The hardware timer fires every 10ms. Because every process within a specific tier has the same ticket weight, the scheduler resolves the winner in O(1) time complexity.

**Execution Flow:**
1. **Calculate Total Tickets:** Multiply each tier's process count by its fixed tier weight and sum them.
2. **Draw Ticket:** Generate a random number using the software Xorshift PRNG.
3. **Find Tier:** Use simple comparisons to determine which tier the winning ticket falls into.
4. **Find Index:** Calculate the exact array index using a bit shift.
5. **Execute:** Load the process address from `tX[Winning_Index]` and perform the context switch.

## 4. Tier Downgrade (100ms)
Every 100ms, the system drops currently executing processes down a priority tier to accommodate new tasks. This is achieved via pointer manipulation to minimize CPU overhead.

**Execution Flow:**
- **Accumulator Phase (O(n)):** Append all elements from the array pointed to by `t2` into `t3` (`buf_sink`).
- **Pointer Swap (O(1)):**
  1. Save `t2`'s now-empty buffer address as `free_buffer`.
  2. Rotate pointers downwards: `t2 = t1`, then `t1 = t0`.
  3. Assign the empty buffer to the top: `t0 = free_buffer`.
  4. Shift queue counts downwards.

## 5. Starvation Prevention Reset (1000ms)
Every 1 second, all processes are returned to Tier 0 to prevent total starvation of low-priority tasks.

**Execution:** All active processes are copied out of their respective arrays and flattened sequentially into the `buf0` array. Previous sub-tier counts are zeroed.

## 6. Random Number Generation
- **Seeding:** The Hardware RNG peripheral (`0x20104000`) is read once during the kernel boot sequence to generate a 32-bit seed.
- **Generation:** All subsequent random numbers required by the 10ms tick are generated using a pure-software 32-bit Xorshift algorithm. This avoids polling the hardware RNG peripheral during an interrupt.