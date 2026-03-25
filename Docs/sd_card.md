# AOS SD Card Driver & Boot Manager

The AOS SD card subsystem provides bare-metal access to the BCM2835 Arasan eMMC host controller. It initializes the hardware, negotiates with the SD card's internal microcontroller, and reads raw 512-byte sectors into RAM.

The subsystem spans three source files and one supporting driver:

| File | Role |
|---|---|
| `Arasan_Init.S` | GPIO multiplexing, host controller initialization, and command dispatcher |
| `boot_manager.S` | Boot-time orchestrator: init → negotiate → read MBR → first boot check |
| `sd_read_block.S` | CMD17 single-block read via hardware FIFO |
| `mailbox.S` | GPU Mailbox interface for power cycling and clock queries |

---

## 1. GPIO Configuration (`sd_init_part1`)

Routes GPIO pins 48–53 to the Arasan eMMC controller via ALT0 alternate function and enables internal pull-up resistors.

| Pin | Signal | GPFSEL Register |
|---|---|---|
| GPIO 48 | CLK | GPFSEL4 bits [26:24] |
| GPIO 49 | CMD | GPFSEL4 bits [29:27] |
| GPIO 50–53 | DAT0–DAT3 | GPFSEL5 bits [11:0] |

> **Note:** During normal SD card boot, the GPU firmware has already configured these pins. `sd_init_part1` is currently bypassed in `boot_manager.S` to avoid conflicting with the GPU's prior configuration.

---

## 2. Host Controller Initialization (`sd_host_init`)

Brings the Arasan EMMC controller from a cold state to a stable, clocked configuration ready to accept SD commands. The initialization follows 8 phases:

### Phase 1 — GPU Mailbox Power Cycle
Calls `mbox_sd_power_cycle` to cleanly power OFF then ON the SD card via the VideoCore GPU. This ensures a deterministic starting state regardless of prior controller activity.

### Phase 2 — Controller Version Read
Reads `EMMC_SLOTISR_VER` (offset `0xFC`) for diagnostic output over UART.

### Phase 3 — Hardware Reset (SRST_HC)
Issues a full host controller reset via CONTROL1 bit 24 (`SRST_HC`), simultaneously disabling the SD clock and internal clock. Spin-waits until reset bits [26:24] self-clear.

### Phase 4 — Card Detection
Polls `EMMC_STATUS` bit 16 (Card Inserted) with a ~500ms timeout. If no card is detected, prints the STATUS register value over UART and halts.

### Phase 5 — Bus Power
Enables SD bus power by setting CONTROL0 bits [11:8].

### Phase 6 — Clock Configuration
Queries the EMMC base clock rate from the GPU via `mbox_get_emmc_clock`, then configures CONTROL1:
- Enables the internal clock (bit 0)
- Sets the data timeout (bits [19:16] = 7)
- Sets the clock divider to `0xFF << 8` (~400kHz initialization frequency)
- Waits for internal clock stability (bit 1)
- Enables the SD clock output (bit 2)

### Phase 7 — Interrupt Configuration
Configures the BCM2835's inverted interrupt semantics:
- `IRPT_EN` (0x34) = `0xFFFFFEFF` — All status bits visible for polling, except SDIO Card Interrupt (bit 8)
- `IRPT_MASK` (0x38) = `0x00000000` — No ARM IRQ generation (pure polling model)
- Clears all pending interrupt flags by writing `0xFFFFFFFF` to the INTERRUPT register (0x30)

---

## 3. Command Dispatcher (`sd_send_command`)

Sends an arbitrary SD command to the card and waits for completion. Used by both `sd_card_init` (initialization commands) and `sd_read_block` (data transfer commands).

**Input:**
- `r0` = CMDTM register configuration (command index, response type, transfer flags)
- `r1` = 32-bit argument for ARG1

**Execution:**
1. Spin-waits on `EMMC_STATUS` bit 0 (Command Inhibit) until the command line is idle
2. Clears all pending interrupt flags
3. Writes the argument to `EMMC_ARG1` (offset `0x08`)
4. Writes to `EMMC_CMDTM` (offset `0x0C`) to physically initiate the transmission
5. Spin-waits on the INTERRUPT register for bit 0 (CMD_DONE) or bit 15 (ERR_INTR)
6. On error: prints the INTERRUPT register, resets the command and data state machines (CONTROL1 bits [26:25]), and returns `-1`
7. On success: clears the CMD_DONE flag and returns `0`

---

## 4. SD Card Initialization Protocol (`sd_card_init`)

Negotiates with the SD card's internal microcontroller to bring it from idle state to transfer-ready state.

| Step | Command | Purpose | Argument |
|---|---|---|---|
| 1 | CMD0 (×2) | GO_IDLE_STATE — hardware reset | `0x00000000` |
| 2 | CMD8 | SEND_IF_COND — verify 3.3V support | `0x000001AA` |
| 3 | CMD55 + ACMD41 (loop) | SD_SEND_OP_COND — power-up negotiation | `0x40FF0000` (HCS bit set for SDHC) |
| 4 | CMD2 | ALL_SEND_CID — request Card ID | `0x00000000` |
| 5 | CMD3 | SEND_RELATIVE_ADDR — obtain RCA | `0x00000000` |

The RCA (Relative Card Address) returned by CMD3 is stored in the global `sd_rca` variable for use by all subsequent read/write commands.

The first CMD0 is sent as a dummy command to force 74+ clock cycles on the bus (the Arasan controller only toggles CLK during an active transmission), followed by a 1-second delay for the card's internal power-on sequence.

Any hardware failure at any step results in a fatal halt (`wfe` loop).

---

## 5. Block Read (`sd_read_block`)

Reads a single 512-byte block from the SD card into a RAM buffer using CMD17 (READ_SINGLE_BLOCK).

**Input:**
- `r0` = Sector number (block address)
- `r1` = Destination RAM address

**Execution:**
1. Configures `EMMC_BLKSIZECNT` to 1 block × 512 bytes
2. Sends CMD17 with the sector number as argument
3. Spin-waits for Buffer Read Ready (INTERRUPT bit 5)
4. Pumps 128 × 32-bit words from the `EMMC_DATA` FIFO register into RAM
5. Spin-waits for Transfer Complete (INTERRUPT bit 1)
6. Returns `0` on success, `-1` on error

---

## 6. GPU Mailbox Interface (`mailbox.S`)

Communicates with the VideoCore GPU via the BCM2835 property tag mailbox (Channel 8).

### `mbox_call`
Generic mailbox send/receive. Writes a 16-byte-aligned buffer address (OR'd with channel 8) to the Mailbox Write register, then spin-reads the Mailbox Read register until a matching response arrives. Checks the response code for `0x80000000` (success).

### `mbox_sd_power_cycle`
Sends two consecutive Set Power State (`0x00028001`) property tag messages:
1. **Power OFF**: Device ID 0, State = 2 (OFF + wait for stable)
2. **Power ON**: Device ID 0, State = 3 (ON + wait for stable)

A ~5ms delay separates the two operations for power rail settling.

### `mbox_get_emmc_clock`
Sends a Get Clock Rate (`0x00030002`) property tag for Clock ID 1 (EMMC). Returns the clock rate in Hz (typically 250,000,000 for the BCM2835).

---

## 7. Boot Manager (`boot_manager`)

The boot manager is the first driver-level code the kernel calls after enabling the MMU and scheduler structures. It orchestrates the full SD card startup and implements a first-boot detection mechanism.

**Execution flow:**
1. Calls `sd_host_init` to initialize the Arasan eMMC controller
2. Calls `sd_card_init` to negotiate with the SD card microcontroller
3. Calls `sd_read_block` to read Sector 0 (MBR) into a 512-byte BSS buffer
4. Reads the byte at MBR offset `0x01B8` (inside the normally unused disk signature area)
5. If the byte is `0x01` (first boot flag), branches to `claim_free_space`
6. Otherwise, returns to the kernel

The first-boot flag is injected during the build process by the Makefile, which writes `0x01` at MBR byte offset 440 (`0x01B8`) of the generated `AOS.img`.

> **Note:** `claim_free_space` is currently a stub that prints a debug message. The intended behavior is to parse the MBR partition table and perform first-boot disk provisioning.

---

## CMDTM Reference

The BCM2835 CMDTM register encodes the command index, response type, and transfer flags:

```
Bits [29:24] = Command Index
Bit  [21]    = Data Present Select
Bits [17:16] = Response Type (0=None, 2=48-bit, 1=136-bit, 3=48-bit busy)
Bit  [4]     = Data Transfer Direction (1=Read, 0=Write)
```

| Constant | Value | Description |
|---|---|---|
| `CMD0_CMDTM` | `0x00000000` | GO_IDLE_STATE (no response) |
| `CMD8_CMDTM` | `0x08020000` | SEND_IF_COND (48-bit response) |
| `CMD55_CMDTM` | `0x37020000` | APP_CMD (48-bit response) |
| `ACMD41_CMDTM` | `0x29020000` | SD_SEND_OP_COND (48-bit response) |
| `CMD2_CMDTM` | `0x02090000` | ALL_SEND_CID (136-bit response) |
| `CMD3_CMDTM` | `0x03020000` | SEND_RELATIVE_ADDR (48-bit response) |
| `CMD17_CMDTM` | `0x11220010` | READ_SINGLE_BLOCK (48-bit + data read) |
