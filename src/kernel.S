.section ".text.boot"
.globl _start

// Program Entry Point
_start:
    // Setup the stack pointer.
    // The kernel is loaded at 0x8000, so we use the memory below it as our stack.
    mov sp, #0x8000

    // Initialize UART
    bl uart_init

    // Send the welcome message
    ldr r0, =welcome_msg
    bl uart_puts
    

    // Halt the CPU in an infinite loop
halt:
    b halt

.section ".rodata"
welcome_msg:
    .asciz "Welcome to A6OS!\r\n"
