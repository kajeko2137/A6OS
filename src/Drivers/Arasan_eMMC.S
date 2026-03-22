//Arasan eMMC Host Controller Driver

.section ".text"

.equ GPIO_BASE, 0x20200000
.equ GPFSEL4,   (GPIO_BASE + 0x10)  // Controls GPIO 40-49
.equ GPFSEL5,   (GPIO_BASE + 0x14)  // Controls GPIO 50-59
.equ GPPUD,     (GPIO_BASE + 0x94)  // Pull-up/Pull-down Enable
.equ GPPUDCLK1, (GPIO_BASE + 0x9C)  // Pull-up/Pull-down Clock 1 (GPIO 32-53)

// Initialize GPIO pins 48-53 for SD Card access (ALT3)
.globl sd_init_part1
sd_init_part1:
    push {lr}

    // 1. Route GPIO 48 (CLK) and 49 (CMD) to ALT3
    ldr r0, =GPFSEL4
    ldr r1, [r0]
    
    // Clear bits 24-29 (3 bits per pin * 2 pins)
    ldr r2, =~(0x3F << 24)      
    and r1, r1, r2
    
    // Set bits 24-29 to 0b111 (ALT3) -> 0b111111 = 0x3F
    ldr r2, =(0x3F << 24)       
    orr r1, r1, r2
    str r1, [r0]

    // 2. Route GPIO 50-53 to ALT3
    ldr r0, =GPFSEL5
    ldr r1, [r0]
    
    // Clear bits 0-11 (3 bits per pin * 4 pins)
    ldr r2, =~(0xFFF)           
    and r1, r1, r2
    
    // Set bits 0-11 to 0b111 (ALT3) -> 4 pins of 1s = 0xFFF
    ldr r2, =0xFFF              
    orr r1, r1, r2
    str r1, [r0]

    // 3. Engage internal Pull-Up resistors for GPIO 48-53
    ldr r0, =GPPUD
    mov r1, #2                  // 2 = Enable Pull-Up control
    str r1, [r0]
    
    // Wait 150 cycles for the control signal to set
    mov r0, #150
    bl delay

    // Assert the clock on pins 48-53 to lock in the pull-up state
    // GPIO 48 is bit 16 in GPPUDCLK1 (48 - 32 = 16). 6 pins = 0x3F
    ldr r0, =GPPUDCLK1
    ldr r1, =(0x3F << 16)       
    str r1, [r0]
    
    // Wait 150 cycles for the electrical state to latch
    mov r0, #150
    bl delay

    // Remove the control signal and clock
    mov r1, #0
    ldr r0, =GPPUD
    str r1, [r0]
    ldr r0, =GPPUDCLK1
    str r1, [r0]

    pop {pc}

// Arasan EMMC Peripheral Registers
.equ EMMC_BASE,     0x20300000
.equ EMMC_STATUS,   (EMMC_BASE + 0x24)
.equ EMMC_CONTROL0, (EMMC_BASE + 0x28)
.equ EMMC_CONTROL1, (EMMC_BASE + 0x2C)

// Initialize the Arasan Host Controller
.globl sd_host_init
sd_host_init:
    push {lr}

    // Phase 2: Hardware Reset
    ldr r0, =EMMC_CONTROL1
    ldr r1, [r0]
    
    // Bit 24 is "Software Reset for All" (SRST_HC)
    orr r1, r1, #(1 << 24)
    str r1, [r0]

    // Spin-wait: The silicon takes time to reset. The hardware will 
    // automatically clear Bit 24 to '0' when the reset is physically complete.
1:  ldr r1, [r0]
    tst r1, #(1 << 24)
    bne 1b                  

    // Phase 3: 400kHz Safe Mode Clock Setup
    // Set Internal Clock Enable (Bit 0) and Timeout Control (Bits 16-19 = 0xE)
    ldr r1, =(0xE << 16) | (1 << 0)
    
    // Inject the split 10-bit divider for 500 (0x1F4)
    // Lower 8 bits (0xF4 << 8) | Upper 2 bits (0x01 << 6)
    ldr r2, =((0xF4 << 8) | (0x01 << 6))
    orr r1, r1, r2
    str r1, [r0]

    // Spin-wait: Wait for the Arasan internal clock generator to stabilize.
    // Bit 1 will turn to '1' when the clock is mathematically stable.
2:  ldr r1, [r0]
    tst r1, #(1 << 1)
    beq 2b                  

    // Now that the internal clock is stable, route it to the physical SD card pin
    // Enable SD Clock (Bit 2)
    ldr r1, [r0]
    orr r1, r1, #(1 << 2)
    str r1, [r0]

    // Wait 150 cycles for the electrical pulse to reach the physical card
    mov r0, #150
    bl delay

    pop {pc}