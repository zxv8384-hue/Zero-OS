#!/bin/bash
# Build the Zero-OS kernel-track bootloader + stage-2 stub into kernel.img.
# Sibling to build.sh (the hex-monitor editor build) - doesn't touch it.
set -e

nasm -f bin kernel_boot.asm -o kernel_boot.bin
nasm -f bin kernel.asm      -o kernel.bin

BOOT_SIZE=$(stat -c%s kernel_boot.bin)
KERN_SIZE=$(stat -c%s kernel.bin)

if [ "$BOOT_SIZE" -ne 512 ]; then
    echo "ERROR: kernel_boot.bin is $BOOT_SIZE bytes, must be exactly 512." >&2
    exit 1
fi
echo "kernel_boot.bin: $BOOT_SIZE bytes (OK)"
echo "kernel.bin:       $KERN_SIZE bytes"

cat kernel_boot.bin kernel.bin > kernel.img
truncate -s 1474560 kernel.img

echo "Built kernel.img ($(stat -c%s kernel.img) bytes)"
echo ""
echo "Test it:"
echo "  qemu-system-x86_64 -drive format=raw,file=kernel.img"
