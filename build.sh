#!/bin/bash
# Build the two-stage bare-metal hex-monitor editor into disk.img.
set -e

nasm -f bin boot.asm   -o boot.bin
nasm -f bin editor.asm -o editor.bin

BOOT_SIZE=$(stat -c%s boot.bin)
EDIT_SIZE=$(stat -c%s editor.bin)

if [ "$BOOT_SIZE" -ne 512 ]; then
    echo "ERROR: boot.bin is $BOOT_SIZE bytes, must be exactly 512." >&2
    exit 1
fi
echo "boot.bin:   $BOOT_SIZE bytes (OK)"
echo "editor.bin: $EDIT_SIZE bytes"

cat boot.bin editor.bin > disk.img
# Pad to a conventional 1.44MB floppy-sized image — BIOS/QEMU handle
# this size totally predictably, and it's far bigger than the ~22
# sectors we actually use (stage2 + save header + saved text).
truncate -s 1474560 disk.img

echo "Built disk.img ($(stat -c%s disk.img) bytes)"
echo ""
echo "Test it (safe, no real disk involved):"
echo "  qemu-system-x86_64 -drive format=raw,file=disk.img"
echo ""
echo "Write it to a REAL drive only if you're certain of the target:"
echo "  sudo dd if=disk.img of=/dev/sdX bs=512 conv=notrunc"
echo "  (dd overwrites AT LEAST the first ~22 sectors of whatever /dev/sdX"
echo "   is — double, triple check that device path first)"
