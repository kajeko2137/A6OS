ENTRY(_start)

SECTIONS
{
    /* The Raspberry Pi 1 B GPU loads kernel.img to 0x8000 */
    . = 0x8000;
    
    .text :
    {
        /* Keep our boot code at the very beginning */
        KEEP(*(.text.boot))
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
