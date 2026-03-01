ENTRY(_start)

SECTIONS
{
    /* The Raspberry Pi 1 B GPU loads kernel.img to 0x8000 */
    . = 0x8000;
    
    .text :
    {
        /* Keep our boot code at the very beginning */
        KEEP(*(.text.boot))

        /* Process1 code — bracketed by symbols for runtime memcpy */
        . = ALIGN(4);
        _process1_start = .;
        KEEP(*(.text.process1))
        _process1_end = .;

        *(.text .text.*)
    }

    .rodata :
    {
        *(.rodata .rodata.*)
    }

    .data :
    {
        *(.data .data.*)
    }

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }
}
