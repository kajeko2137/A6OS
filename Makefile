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
all: kernel.img A6OS.img

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

# Download missing boot files
bootcode.bin start.elf:
	./fetch_boot_files.sh

# Create the full partitioned SD card disk image
A6OS.img: kernel.img bootcode.bin start.elf config.txt
	@echo "Creating SD card image (A6OS.img)..."
	@dd if=/dev/zero of=$(BUILD_DIR)/boot.img bs=1M count=64 status=none
	@/sbin/mkfs.fat -F 32 -h 2048 $(BUILD_DIR)/boot.img > /dev/null
	@mcopy -i $(BUILD_DIR)/boot.img bootcode.bin start.elf config.txt kernel.img ::/
	@dd if=/dev/zero of=$@ bs=1M count=128 status=none
	@/sbin/parted -s $@ mklabel msdos
	@/sbin/parted -s $@ mkpart primary fat32 1MiB 65MiB
	@/sbin/parted -s $@ set 1 boot on
	@/sbin/parted -s $@ set 1 lba on
	@dd if=$(BUILD_DIR)/boot.img of=$@ bs=1M seek=1 conv=notrunc status=none
	@echo "Successfully generated $@"
