# A6OS

A bare-metal operating system for the **Raspberry Pi 1 Model B**, written entirely in ARM assembly. The project now features a physical page allocator, L1 translation table management, and MMU initialization — the foundations of virtual memory.

## Hardware Target

| Detail | Value |
|---|---|
| **Board** | Raspberry Pi 1 Model B |
| **SoC** | Broadcom BCM2835 |
| **CPU** | ARM1176JZF-S (ARMv6) |
| **RAM** | 512 MB |
| **Kernel load address** | `0x8000` |

## Features

- **BSS zeroing** — clears uninitialized data (including the page table) at boot using fast 16-byte `stmia` writes.
- **UART0 (PL011) driver** — serial output at 115200 baud over GPIO 14/15. Supports single character, string, and 32-bit hex printing.
- **Physical page allocator** — tracks all 131,072 4KB pages across 512MB of RAM using a byte array. Supports `alloc_page` and `free_page`.
- **L1 translation table allocator** — finds and reserves 4 contiguous pages (16KB, 16KB-aligned) for ARMv6 first-level page tables.
- **Process allocation** — allocates an L1 table, zeroes it, and maps the kernel (1MB identity-mapped at `0x0`) and UART peripheral region (`0x20200000`) as privileged read/write sections.
- **MMU enable** — loads the L1 table into TTBR0, sets Domain 0 to client mode, enables the MMU, and flushes the prefetch buffer.

## Boot Sequence

```
ROM (SoC) → bootcode.bin → start.elf → kernel.img (A6OS)
         Stage 1        Stage 2      Stage 3       ARM CPU
```

On startup, the kernel:

1. Sets up the stack pointer at `0x8000` (growing downward).
2. Zeroes the `.bss` section.
3. Initializes UART0 for serial debug output.
4. Reserves 1MB of physical pages for the kernel.
5. Allocates a process (L1 table + identity-mapped kernel and UART sections).
6. Enables the MMU.
7. Prints a confirmation message and halts.

## Project Structure

```
A6OS/
├── src/
│   ├── kernel.S                 # Entry point, BSS init, boot flow, MMU enable
│   ├── allocator.S              # Page allocator, L1 table allocator, section mapping
│   └── Drivers/
│       ├── UART_setup.S         # UART0 initialization (GPIO, baud rate, FIFOs)
│       └── UART_send.S          # uart_send, uart_puts, uart_print_hex
├── linker.ld                    # Linker script (entry at 0x8000, .text.boot first)
├── Makefile                     # Build system (auto-discovers .S/.c files under src/)
├── config.txt                   # RPi firmware config (UART clock = 3 MHz)
├── fetch_boot_files.sh          # Downloads bootcode.bin and start.elf
└── .vscode/                     # VS Code build task (Ctrl+Shift+B)
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

Expected output:

```
Welcome to A6OS!
Kernel and UART mapped to L1 Table.
UART still works!
```

## Memory Layout

| Region | Address | Description |
|---|---|---|
| Stack | `0x0000` – `0x7FFF` | Grows downward from `0x8000` |
| Kernel | `0x8000` – ~`0x9000` | Code, rodata, data |
| BSS | After kernel | Page table (128KB byte array) |
| Free pages | After BSS | Available for allocation |

## License

Not yet specified.
