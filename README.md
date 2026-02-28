# A6OS

A bare-metal operating system for the **Raspberry Pi 1 Model B**, written entirely in ARM assembly. Currently at the "first light" stage — the kernel boots, initializes UART0, and prints a welcome message over serial.

## Hardware Target

| Detail | Value |
|---|---|
| **Board** | Raspberry Pi 1 Model B |
| **SoC** | Broadcom BCM2835 |
| **CPU** | ARM1176JZF-S (ARMv6) |
| **Kernel load address** | `0x8000` |

## What It Does (So Far)

1. **Boots** — the GPU bootloader loads `kernel.img` to `0x8000` and hands off to `_start`.
2. **Sets up the stack** — stack pointer is placed just below the kernel at `0x8000`, growing downward.
3. **Initializes UART0 (PL011)** — configures GPIO pins 14 (TX) and 15 (RX) for ALT0, disables pull-up/down resistors, sets 115200 baud (8N1 with FIFOs enabled).
4. **Prints** `Welcome to A6OS!` over serial.
5. **Halts** — enters an infinite loop.

## Project Structure

```
A6OS/
├── src/
│   ├── kernel.S                 # Entry point (_start), stack setup, main logic
│   └── Drivers/
│       ├── UART_setup.S         # UART0 initialization (gpio, baud, fifos)
│       └── UART_send.S          # uart_send (char) and uart_puts (string)
├── linker.ld                    # Linker script — places .text.boot at 0x8000
├── Makefile                     # Build system (assembles, links, objcopy → kernel.img)
├── config.txt                   # RPi firmware config (enable UART, set clock to 3 MHz)
├── fetch_boot_files.sh          # Downloads bootcode.bin and start.elf from RPi firmware repo
└── .vscode/                     # VS Code build task integration
```

## Prerequisites

- **ARM cross-toolchain** — `arm-none-eabi-gcc`, `arm-none-eabi-ld`, `arm-none-eabi-objcopy`
- **wget** — for fetching the GPU bootloader files
- A **FAT32-formatted SD card** and a **USB-to-serial adapter** (or a Pico UART bridge) for testing on real hardware

## Building

```bash
# 1. Fetch the proprietary GPU bootloader files (only needed once)
./fetch_boot_files.sh

# 2. Build the kernel
make
```

This produces `kernel.img` — a raw binary image ready to boot.

To clean build artifacts:

```bash
make clean
```

## Running on Hardware

1. Format an SD card as **FAT32**.
2. Copy these files to the root of the SD card:
   - `bootcode.bin`
   - `start.elf`
   - `config.txt`
   - `kernel.img`
3. Connect a serial adapter to **GPIO 14 (TX)** and **GPIO 15 (RX)** on the Pi's header.
4. Open a serial terminal at **115200 baud, 8N1**.
5. Insert the SD card and power on the Pi.

You should see:

```
Welcome to A6OS!
```

## Boot Sequence

```
ROM (SoC) → bootcode.bin (Stage 2) → start.elf (Stage 3) → kernel.img (A6OS)
```

The BCM2835's on-chip ROM loads `bootcode.bin` from the SD card, which in turn loads the GPU firmware `start.elf`. The GPU firmware reads `config.txt`, then loads `kernel.img` to address `0x8000` and releases the ARM CPU to begin execution.

## License

Not yet specified.
