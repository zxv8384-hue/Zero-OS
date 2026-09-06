# Bare-Metal Hex-Monitor Editor

A two-stage, zero-OS x86 program: it boots straight into a text editor
that can save what you type to disk, and can compile-and-run hex bytes
you type as real machine code — no operating system, no compiler, all
running directly on top of BIOS interrupts.

## Files

| File | Purpose |
|---|---|
| `layout.inc` | Shared memory/disk-address constants — single source of truth for both stages |
| `boot.asm` | Stage 1 — 512-byte boot sector, loads Stage 2 from disk and jumps to it |
| `editor.asm` | Stage 2 — the actual editor, hex monitor, and save/load logic |
| `build.sh` | Assembles both stages into a bootable `disk.img` |

## Why two stages

A boot sector only has 510 usable bytes. That's nowhere near enough
for an editor plus a save routine plus a hex-to-bytes parser — the
`editor_v2.asm` sketch this is based on only got as far as writing a
single hardcoded `0xC3` byte because a real implementation doesn't
fit in the boot sector at all. So Stage 1 does one thing: read Stage 2
off disk into RAM and jump to it. Stage 2 (loaded at `0000:8000`) has
no size limit worth worrying about — it's reserved 8 KiB and currently
uses a small fraction of that.

Disk access uses INT 13h **LBA extensions** (functions 0x41/0x42/0x43)
rather than old CHS geometry (cylinder/head/sector) calls — CHS
requires guessing the emulator or drive's exact geometry and is a
classic source of "works on my machine" bootloader bugs. LBA sidesteps
that entirely and is supported by essentially every BIOS made since
the mid-1990s.

## Controls

- Type — insert characters, echoed to the screen
- **Enter** — newline
- **Backspace** — delete the last character
- **F1** — save the buffer to disk (survives a reboot)
- **F2** — treat the buffer as hex byte-pairs, assemble them into
  raw machine code in RAM, and run it
- **F3** — reload the buffer from disk

F2 is a *hex monitor*, not a full mnemonic assembler — you type raw
opcode bytes, the same way early microcomputers like the Apple I were
programmed before assemblers existed on the machine itself. For
example, typing:

```
B0 41 B4 0E CD 10 C3
```

means: `MOV AL,0x41` / `MOV AH,0x0E` / `INT 0x10` (BIOS print
teletype) / `RET` — i.e. it prints the letter `A`. Whitespace and
line breaks between byte pairs are ignored. If you forget the
trailing `C3` (`RET`), the editor appends one for you automatically
so control always comes back instead of running into adjacent memory.

There is no memory protection at this level — a bad byte sequence can
hang or reset the machine. That's expected behavior for a hex
monitor, and nothing is permanently changed unless you press F1.

## Build and test

```bash
chmod +x build.sh
./build.sh
qemu-system-x86_64 -drive format=raw,file=disk.img
```

QEMU is strongly recommended for all testing — it's instant to reset
and can't damage anything.

## ⚠️ Before touching a real disk

- `dd` to a real device (`/dev/sdX`) will overwrite the first ~22
  sectors of whatever that device is — confirm the exact device path
  first (`lsblk`), since the wrong letter targets the wrong drive.
- **This only works on legacy BIOS / CSM boot.** It's a classic MBR
  boot sector using real-mode `INT 0x10/0x13/0x16` BIOS calls. Most
  laptops made in the last few years have **removed CSM entirely** and
  are UEFI-only, which will not execute this code at all — UEFI loads
  PE/COFF executables through its own boot services, not BIOS
  interrupts. If your laptop has no "Legacy Boot" / "CSM" option in
  firmware setup, this will only ever run in QEMU (or a VM configured
  for legacy BIOS, e.g. VirtualBox/VMware with EFI disabled), not on
  that hardware directly.

## Verification note

I don't have `nasm` or network access in this sandbox, so I traced
the encoding and control flow by hand rather than assembling it here.
`build.sh` sanity-checks that `boot.bin` comes out to exactly 512
bytes. If `nasm` reports an error on your machine, paste it back and
I'll fix it directly.

## Natural next step

The real limitation right now is that F2 only understands raw hex
bytes, not mnemonics. A small next step would be a proper text
parser in Stage 2 — reading tokens like `MOV AL, 65`, matching a
mnemonic table, and emitting the right opcode/ModRM/immediate bytes
instead of requiring you to already know the hex. That's a
meaningfully bigger routine (real parsing + a lookup table instead of
one hex_nibble helper), but the disk/RAM plumbing here doesn't change
at all — it would slot into `do_run` in place of the current
byte-pair parser.
