ARMGNU ?= arm-none-eabi

# Build flags for Raspberry Pi 1 B (ARM1176JZF-S processor, ARMv6 architecture)
COPS = -Wall -O2 -nostdlib -nostartfiles -ffreestanding -mcpu=arm1176jzf-s
ASMOPS = -I. -mcpu=arm1176jzf-s

# Directories
BUILD_DIR = build
SRC_DIR = src

# Find all assembly and C source files recursively under src/
ASM_FILES = $(shell find $(SRC_DIR) -name '*.S')
C_FILES = $(shell find $(SRC_DIR) -name '*.c')

# Generate object file paths, preserving directory structure under build/
OBJ_FILES  = $(patsubst $(SRC_DIR)/%.S, $(BUILD_DIR)/%_s.o, $(ASM_FILES))
OBJ_FILES += $(patsubst $(SRC_DIR)/%.c, $(BUILD_DIR)/%_c.o, $(C_FILES))

# Default target
all: kernel.img

# Clean target
clean:
	rm -rf $(BUILD_DIR) *.elf *.img

# Compile C files
$(BUILD_DIR)/%_c.o: $(SRC_DIR)/%.c
	@mkdir -p $(@D)
	$(ARMGNU)-gcc $(COPS) -c $< -o $@

# Compile assembly files
$(BUILD_DIR)/%_s.o: $(SRC_DIR)/%.S
	@mkdir -p $(@D)
	$(ARMGNU)-gcc $(ASMOPS) -c $< -o $@

# Link the kernel
kernel.elf: linker.ld $(OBJ_FILES)
	$(ARMGNU)-ld -T linker.ld -o kernel.elf $(OBJ_FILES)

# Create the final binary image
kernel.img: kernel.elf
	$(ARMGNU)-objcopy kernel.elf -O binary kernel.img
