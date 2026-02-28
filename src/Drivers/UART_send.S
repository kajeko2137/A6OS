// UART0 Send functions for BCM2835 (Raspberry Pi 1 B)

.equ PERIPHERAL_BASE, 0x20000000
.equ UART0_BASE,      (PERIPHERAL_BASE + 0x201000)
.equ UART0_DR,        (UART0_BASE + 0x00)
.equ UART0_FR,        (UART0_BASE + 0x18)

// Send a single character
// Expects character in r0
.globl uart_send
uart_send:
    // Load FR address
    ldr r1, =UART0_FR
    
1:  // Wait while Transmit FIFO is full (bit 5)
    ldr r2, [r1]
    tst r2, #(1 << 5)
    bne 1b

    // Write character to data register
    ldr r1, =UART0_DR
    str r0, [r1]

    // Cinematic "Typewriter" Hardware Delay
    // Completely prevents Pico USB bridge overflow and avoids stack usage.
    // 0x100000 iterations = ~12ms delay per character at 250MHz.
@     mov r3, #0x100000 
@ 2:  
@     subs r3, r3, #1
@     bne 2b

    bx lr               // Return directly (leaf function, no pop required)



// Send a null-terminated string
// Expects pointer to string in r0
.globl uart_puts
uart_puts:
    push {r4, lr}
    mov r4, r0
1:
    ldrb r0, [r4], #1   // Load the next byte and increment the pointer
    cmp r0, #0          // Check if it's the null terminator
    beq 2f              // If it is, exit the loop
    bl uart_send        // Otherwise, send the character
    b 1b                // Loop back for the next character
2:
    pop {r4, pc}        // Restore registers and return to kernel.S


// Print a 32-bit value as an 8-digit hex string (e.g. "0000C000")
// Expects value in r0
.globl uart_print_hex
uart_print_hex:
    push {r4, r5, lr}
    mov r4, r0              // r4 = value to print
    mov r5, #8              // r5 = nibble counter (8 hex digits)

1:
    // Extract the top nibble (bits 31-28)
    lsr r0, r4, #28
    and r0, r0, #0xF

    // Convert nibble to ASCII
    cmp r0, #10
    addlt r0, r0, #'0'     // 0-9 → '0'-'9'
    addge r0, r0, #('A' - 10) // 10-15 → 'A'-'F'

    bl uart_send

    // Shift value left by 4 to bring the next nibble to the top
    lsl r4, r4, #4
    subs r5, r5, #1
    bne 1b

    pop {r4, r5, pc}