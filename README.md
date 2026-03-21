# A6OS

A bare-metal operating system for the **Raspberry Pi 1 Model B**, written entirely in ARM assembly. The project features physical page allocation, advanced ARMv6 Extended Page Table MMU initialization, process isolation across User/Supervisor modes, a functional software interrupt (SWI) system call dispatcher, and an O(1) Tiered Lottery Scheduler.

## Hardware Target

| Detail | Value |
|---|---|
| **Board** | Raspberry Pi 1 Model B |
| **SoC** | Broadcom BCM2835 |
| **CPU** | ARM1176JZF-S (ARMv6) |
| **RAM** | 512 MB |
| **Kernel load address** | `0x8000` |

## Core Features

- **Tiered Lottery Scheduler (TLS)** — A custom O(1) scheduler driven by a 10ms system timer interrupt. Manages processes across 4 priority tiers using a zero-copy pointer-swapping mechanism for downgrades (100ms) and array flattening for starvation prevention resets (1000ms).
- **Physical page allocator** — Tracks exactly 131,072 4KB pages across 512MB of RAM using a byte array tracking map.
- **MMU & Virtual Memory** — Creates L1 coarse tables and initializes ARMv6 Extended Page Table format (SCTLR.XP enabled), mapping the kernel identity region and 512MB RAM physical translation through a higher-half offset (0x80000000+).
- **Process Memory Isolation (L2 Tables)** — Maps separate 4KB virtual pages per process into L2 coarse tables, restricting User mode constraints. The code is mapped at `0x00100000`, the heap at `0x00101000`, and the stack dynamically allocated downwards from `0x00200000`.
- **System Calls (SWI dispatcher)** — A system call handler tracking software interrupt triggers. Handlers preserve exception execution states and process registers, seamlessly returning control to user execution.
- **Dynamic User Memory Allocation** — Provides processes the ability to ask for additional physical pages dynamically through system calls. Features O(1) bump-allocation and creates contiguous internal L2 translation tables automatically.
- **Lazy Memory Mapping** — Seamlessly intercepts physical access to unused virtual heap boundaries via the kernel's Data Abort Exception handler, instantly provisioning requested memory pages invisibly to the application.
- **Hardware True RNG** — Initializes and reads the silicon BCM2835 True Random Number Generator once during boot to securely seed the software deterministic Xorshift PRNG used by the Lottery Scheduler.

## Boot Sequence

```
ROM (SoC) → bootcode.bin → start.elf → kernel.img (A6OS)
```

On startup, the kernel:

1. Maps CPU execution contexts, setting stack pointers for all processor modes.
2. Zeroes the `.bss` section.
3. Initializes UART0 for basic serial output.
4. Initializes the MMU, translating the kernel layout across hardware contexts.
5. Initializes the Tiered Lottery Scheduler (TLS) memory structs and RNG seed.
6. Maps `process1` directly into the Tier 0 Scheduler ring buffer.
7. Enables the 10ms hardware timer interrupt and enters the `system_idle` loop.
8. Bootstraps user mode process execution naturally via the timer interrupt context switcher.

## Project Structure

```
A6OS/
├── src/
│   ├── kernel.S                 # Entry point, boot flow, MMU enable & launch control
│   ├── process1.S               # Example user mode process executable code
│   ├── allocator.S              # Paging, L1/L2 table manipulation, process footprint track
│   ├── scheduler.S              # O(1) Tiered Lottery Scheduler logic and context switcher
│   ├── timer.S                  # Hardware 10ms interrupt timer configuration
│   ├── exception.S              # Exception routines, SWI system call dispatch
│   └── Drivers/
│       ├── UART_setup.S         # UART0 initialization
│       └── UART_send.S          # Print wrappers
├── Docs/
│   ├── allocator.md             # Virtual memory specification
│   └── scheduler.md             # TLS Scheduler architecture specification
├── linker.ld                    # Linker script 
├── Makefile                     # Build system
├── config.txt                   # RPi firmware config
└── fetch_boot_files.sh          # Bootloader fetcher logic
```

## Prerequisites

- **ARM cross-toolchain** — `arm-none-eabi-gcc`, `arm-none-eabi-ld`, `arm-none-eabi-objcopy`
- **wget** — for fetching the GPU bootloader files
- A **FAT32-formatted SD card** and a **USB-to-serial adapter** for testing on hardware

## Building

```bash
# Fetch the proprietary GPU bootloader files (only needed once)
./fetch_boot_files.sh

# Build the kernel
make

# Clean build artifacts
make clean
```

## Running on Hardware

1. Format an SD card as **FAT32**.
2. Copy to the root of the SD card: `bootcode.bin`, `start.elf`, `config.txt`, `kernel.img`.
3. Connect a serial adapter to **GPIO 14 (TX)** and **GPIO 15 (RX)**.
4. Open a serial terminal at **115200 baud, 8N1**.
5. Insert the SD card and power on the Pi.

Expected clean execution output:

```
Welcome to A6OS!
Process exited, returned to kernel.
```
