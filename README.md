# A6OS

A bare-metal operating system for the **Raspberry Pi 1 Model B**, written entirely in ARM assembly. The project features physical page allocation, advanced ARMv6 Extended Page Table MMU initialization, process isolation across User/Supervisor modes, and a fully functional software interrupt (SWI) system call dispatcher for dynamic process memory management.

## Hardware Target

| Detail | Value |
|---|---|
| **Board** | Raspberry Pi 1 Model B |
| **SoC** | Broadcom BCM2835 |
| **CPU** | ARM1176JZF-S (ARMv6) |
| **RAM** | 512 MB |
| **Kernel load address** | `0x8000` |

## Features

- **BSS zeroing** — clears uninitialized data at boot using fast 16-byte `stmia` writes.
- **UART0 (PL011) driver** — serial output at 115200 baud over GPIO 14/15. Supports character, string, and 32-bit hex printing.
- **Physical page allocator** — tracks all 131,072 4KB pages across 512MB of RAM using a byte array tracking.
- **MMU & Virtual Memory** — creates L1 coarse tables and initializes ARMv6 Extended Page Table format (SCTLR.XP enabled) mapping the kernel identity region (0x0+) and 512MB RAM physical translation through higher-half offsets (0x80000000+).
- **Process Memory Isolation (L2 Tables)** — maps separate 4KB virtual pages per process into L2 coarse tables restricting User mode constraints. The code is mapped at `0x00100000`, heap at `0x00101000`, and stack memory dynamically mapped and shrinking downwards from `0x00200000` (L2[255]). Process mappings track internally and discard upon deletion.
- **System Calls (SWI dispatcher)** — features a system call handler tracking software interrupt triggers. Handlers preserve exception execution states and process registers returning control safely to user execution loop.
- **Dynamic User Memory Allocation & Deallocation** — provides processes the ability to ask for additional physical pages mapped seamlessly between the heap and the stack recursively via SWI 2 (`sys_alloc_page`) and reliably drop unused process memory bounds securely returning chunks back to kernel usage pool via SWI 3 (`sys_free_page`). TLB flushes accurately shield against fault states immediately upon dropping references.

## Boot Sequence

```
ROM (SoC) → bootcode.bin → start.elf → kernel.img (A6OS)
         Stage 1        Stage 2      Stage 3       ARM CPU
```

On startup, the kernel:

1. Maps initial CPU execution contexts setting stack pointers for `ABT`, `UND`, `IRQ`, `FIQ`, `SYS`, and `SVC` modes.
2. Zeroes the `.bss` section.
3. Initializes UART0 for serial debug output.
4. Initializes master MMU translating kernel layout across hardware contexts.
5. Launches process creation (setting isolated code mapping, initial heap/stack pages).
6. Hands execution to user mode launching `process1`.
7. Intercepts SWI interrupts dispatched from `process1`.
8. Cleans process references automatically when terminated by kernel syscalls and halts gracefully.

## Project Structure

```
A6OS/
├── src/
│   ├── kernel.S                 # Entry point, boot flow, MMU enable & launch control
│   ├── process1.S               # Example user mode process executable code
│   ├── allocator.S              # Paging, L1/L2 table manipulation, process footprint track
│   ├── exception.S              # Exception routines, SWI system call dispatch
│   └── Drivers/
│       ├── UART_setup.S         # UART0 initialization
│       └── UART_send.S          # Print wrappers
├── linker.ld                    # Linker script 
├── Makefile                     # Build system
├── config.txt                   # RPi firmware config
├── fetch_boot_files.sh          # Bootloader fetcher logic
└── .vscode/                     # VS Code configuration
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
2. Copy to the root of the SD card:
   - `bootcode.bin`
   - `start.elf`
   - `config.txt`
   - `kernel.img`
3. Connect a serial adapter to **GPIO 14 (TX)** and **GPIO 15 (RX)**.
4. Open a serial terminal at **115200 baud, 8N1**.
5. Insert the SD card and power on the Pi.

Expected typical bootloader output showcasing automated memory allocation lifecycle:

```
Welcome to A6OS!
[DBG] MMU on
[DBG] Process allocated
[DBG] TTBR switched
Allocated page for process.
Freed page for process.
Process exited, returned to kernel.
```

## Memory Layout Snapshot

| Region | Address | Description |
|---|---|---|
| Vector Table | `0x0000` | Exception jumps |
| Kernel Entry | `0x8000` | Code execution bounds |
| Boot Stack | `0x0000` – `0x7FFF` | Master Boot Stack growing downwards |
| User Code | `0x00100000` | Deployed process execution memory |
| User Stack | `0x00200000` | Dynamically provisioned downwards growing stack memory |
| Paging Matrix | `0x80000000+` | Higher-half page pool memory descriptors |

## License

Not yet specified.
