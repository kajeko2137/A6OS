// UART0 Initialization for BCM2835 (Raspberry Pi 1 B)

// Constants for BCM2835 peripheral base
.equ PERIPHERAL_BASE, 0x20000000
.equ GPIO_BASE,       (PERIPHERAL_BASE + 0x200000)
.equ GPFSEL1,         (GPIO_BASE + 0x04)
.equ GPPUD,           (GPIO_BASE + 0x94)
.equ GPPUDCLK0,       (GPIO_BASE + 0x98)

.equ UART0_BASE,      (PERIPHERAL_BASE + 0x201000)
.equ UART0_CR,        (UART0_BASE + 0x30)
.equ UART0_ICR,       (UART0_BASE + 0x44)
.equ UART0_IBRD,      (UART0_BASE + 0x24)
.equ UART0_FBRD,      (UART0_BASE + 0x28)
.equ UART0_LCRH,      (UART0_BASE + 0x2C)

// Small delay loop
// Expects count in r0
delay:
    subs r0, r0, #1
    bne delay
    bx lr

// Initialize UART0
// Configures GPIO 14/15 for ALT0, sets 115200 baud, 8N1, enables FIFOs
.globl uart_init
uart_init:
    push {lr}

    // 1. Disable UART0
    ldr r0, =UART0_CR
    mov r1, #0
    str r1, [r0]

    // 2. Configure GPIO 14 (TXD) and 15 (RXD) to Alternate Function 0
    ldr r0, =GPFSEL1
    ldr r1, [r0]
    // Clear bits 12-14 (GPIO 14) and 15-17 (GPIO 15)
    ldr r2, =~((7 << 12) | (7 << 15))
    and r1, r1, r2
    // Set to ALT0 (binary 100)
    ldr r2, =((4 << 12) | (4 << 15))
    orr r1, r1, r2
    str r1, [r0]

    // 3. Disable pull-up/pull-down on pins 14 and 15
    ldr r0, =GPPUD
    mov r1, #0
    str r1, [r0]
    mov r0, #150
    bl delay

    ldr r0, =GPPUDCLK0
    mov r1, #((1 << 14) | (1 << 15))
    str r1, [r0]
    mov r0, #150
    bl delay

    ldr r0, =GPPUDCLK0
    mov r1, #0
    str r1, [r0]

    // 4. Clear pending interrupts
    ldr r0, =UART0_ICR
    ldr r1, =0x7FF
    str r1, [r0]

    // 5. Set baud rate to 115200 (3MHz clock: IBRD=1, FBRD=40)
    ldr r0, =UART0_IBRD
    mov r1, #1
    str r1, [r0]
    ldr r0, =UART0_FBRD
    mov r1, #40
    str r1, [r0]

    // 6. 8-bit word length, enable FIFOs
    ldr r0, =UART0_LCRH
    mov r1, #((3 << 5) | (1 << 4))
    str r1, [r0]

    // 7. Re-enable UART0 (UART + TX + RX)
    ldr r0, =UART0_CR
    ldr r1, =((1 << 0) | (1 << 8) | (1 << 9))
    str r1, [r0]

    pop {pc}
