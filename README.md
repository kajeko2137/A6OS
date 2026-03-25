# AOS

A bare-metal operating system for the **Raspberry Pi 1 Model B**, written entirely in ARM assembly. The project features physical page allocation, ARMv6 Extended Page Table MMU, process isolation, a system call dispatcher, an O(1) Tiered Lottery Scheduler, and an SD card driver with boot management.

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
- **MMU & Virtual Memory** — Creates L1 coarse tables and initializes ARMv6 Extended Page Table format (SCTLR.XP enabled), mapping the kernel identity region and 512MB RAM physical translation through a higher-half offset (0x80000000+). Identity maps peripheral regions for UART, eMMC, Timers, Interrupt Controller, and Hardware RNG.
- **Process Memory Isolation (L2 Tables)** — Maps separate 4KB virtual pages per process into L2 coarse tables, restricting User mode constraints. The code is mapped at `0x00100000`, the heap at `0x00101000`, and the stack dynamically allocated downwards from `0x00200000`.
- **System Calls (SWI dispatcher)** — A system call handler tracking software interrupt triggers. Handlers preserve exception execution states and process registers, seamlessly returning control to user execution.
- **Dynamic User Memory Allocation** — Provides processes the ability to ask for additional physical pages dynamically through system calls. Features O(1) bump-allocation and creates contiguous internal L2 translation tables automatically.
- **Lazy Memory Mapping** — Seamlessly intercepts physical access to unused virtual heap boundaries via the kernel's Data Abort Exception handler, instantly provisioning requested memory pages invisibly to the application.
- **Hardware True RNG** — Initializes and reads the silicon BCM2835 True Random Number Generator once during boot to securely seed the software deterministic Xorshift PRNG used by the Lottery Scheduler.
- **SD Card Driver (Arasan eMMC)** — Full bare-metal driver for the BCM2835 Arasan eMMC host controller. Implements GPIO multiplexing (ALT0), GPU Mailbox power cycling, host controller reset, clock configuration, and the SD card initialization protocol (CMD0/CMD8/ACMD41/CMD2/CMD3). Supports single-block reads (CMD17) via hardware FIFO polling.
- **GPU Mailbox Interface** — Communicates with the VideoCore GPU via the property tag channel to power-cycle the SD card peripheral and query the EMMC base clock rate.
- **Boot Manager** — Reads the Master Boot Record (MBR) from the SD card at startup, checks a "First Boot" flag at MBR offset `0x01B8`, and branches to a space-claiming routine on first boot.

## Boot Sequence

```
ROM (SoC) → bootcode.bin → start.elf → kernel.img (AOS)
```

On startup, the kernel:

1. Maps CPU execution contexts, setting stack pointers for all processor modes.
2. Zeroes the `.bss` section.
3. Installs the exception vector table at address `0x0`.
4. Initializes UART0 for basic serial output.
5. Reserves 1MB of physical memory for the kernel (256 × 4KB pages).
6. Prints the welcome message.
7. Sets up kernel MMU tables (identity + peripheral mappings + higher-half).
8. Enables the MMU with the kernel's L1 table.
9. Initializes the Tiered Lottery Scheduler (TLS) memory structs and hardware RNG seed.
10. Runs the boot manager (SD card init → card negotiation → MBR read → first boot check).
11. Enables the 10ms hardware timer interrupt and enters the `system_idle` loop.
12. Bootstraps user mode process execution naturally via the timer interrupt context switcher.

## Project Structure

```
AOS/
├── src/
│   ├── kernel/
│   │   ├── kernel.S             # Entry point, boot flow, MMU enable & launch control
│   │   ├── process1.S           # Example user mode process executable code
│   │   ├── allocator.S          # Paging, L1/L2 table manipulation, process footprint track
│   │   ├── scheduler.S          # O(1) Tiered Lottery Scheduler logic and context switcher
│   │   ├── timer.S              # Hardware 10ms interrupt timer configuration
│   │   └── exception.S          # Exception routines, SWI system call dispatch
│   └── Drivers/
│       ├── UART/
│       │   ├── UART_setup.S     # UART0 (PL011) initialization & delay loop
│       │   └── UART_send.S      # Character, string, and hex print wrappers
│       ├── Arasan/
│       │   ├── Arasan_Init.S    # GPIO mux, host controller init, command dispatcher
│       │   ├── boot_manager.S   # Boot manager: MBR read & first boot flag check
│       │   └── sd_read_block.S  # CMD17 single-block read via hardware FIFO
│       └── Mailbox/
│           └── mailbox.S        # GPU property tag interface (power & clock control)
├── Docs/
│   ├── allocator.md             # Virtual memory specification
│   ├── scheduler.md             # TLS Scheduler architecture specification
│   └── sd_card.md               # SD card driver & boot manager specification
├── linker.ld                    # Linker script
├── Makefile                     # Build system
├── config.txt                   # RPi firmware config
└── fetch_boot_files.sh          # Bootloader fetcher logic
```

## Prerequisites

- **ARM cross-toolchain** — `arm-none-eabi-gcc`, `arm-none-eabi-ld`, `arm-none-eabi-objcopy`
- **wget** — for fetching the GPU bootloader files
- **mtools** — `mcopy` for building the SD card disk image
- **parted** — for partitioning the disk image
- A **FAT32-formatted SD card** and a **USB-to-serial adapter** for testing on hardware

## Building

```bash
# Fetch the proprietary GPU bootloader files (only needed once)
./fetch_boot_files.sh

# Build the kernel and SD card image
make

# Clean build artifacts
make clean
```

The build produces `kernel.img` (raw kernel binary) and `AOS.img` (partitioned 128MB SD card image with a FAT32 boot partition containing all boot files and a first-boot flag injected at MBR offset `0x01B8`).

## Running on Hardware

1. Flash `AOS.img` to an SD card:
   ```bash
   sudo dd if=AOS.img of=/dev/sdX bs=1M status=progress
   ```
   Replace `/dev/sdX` with your SD card device (e.g. `/dev/sdb`).
2. Connect a serial adapter to **GPIO 14 (TX)** and **GPIO 15 (RX)**.
3. Open a serial terminal at **115200 baud, 8N1**.
4. Insert the SD card and power on the Pi.

Expected clean execution output:

```
Welcome to AOS!
Process exited, returned to kernel.
```
