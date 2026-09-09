# Zero-OS — Kernel Track

A second, independent boot image alongside the hex-monitor editor
in this project. `boot.asm` / `editor.asm` are untouched and still
work standalone — this is a different track: an actual OS kernel
instead of a hex monitor.

## Files

| File | Purpose |
|---|---|
| `kernel_layout.inc` | Shared memory/disk-address constants for this track |
| `kernel_boot.asm` | Stage 1 — 512-byte boot sector: stack, load kernel, jump |
| `kernel.asm` | Stage 2 — kernel entry point (currently a tested-by-hand stub) |
| `build_kernel.sh` | Assembles both into a bootable `kernel.img` |

## Status right now

Stage 1 loads Stage 2 from disk into memory at `0x1000:0000`
(physical 64 KiB) using the same INT 13h LBA-extension approach as
`boot.asm`, then jumps to it. Stage 2 re-points DS/ES to its own
segment (it isn't at segment 0 like `editor.asm` was, so this step
is required before it can read its own strings), prints a
confirmation line, and halts. That full chain — boot, load, jump,
run — is the part that's easy to get subtly wrong, so it's worth
having solid before adding anything on top of it.

## Verification note

Same situation as the hex-monitor project: no `nasm` or network
access in this sandbox, so I traced the byte layout by hand rather
than assembling it here — `kernel_boot.asm`'s actual instructions
and data come to roughly 300 of the 510 usable bytes, comfortably
under the limit. `build_kernel.sh` double-checks this at build time
regardless. If `nasm` reports an error on your machine, paste it
back and I'll fix it directly.

## Status

- ✅ **A20 line** — checks whether it's already on, tries the BIOS
  call (`INT 15h, AX=2401h`), falls back to the keyboard-controller
  method if that doesn't work, and verifies the *actual* result via
  a memory-aliasing test rather than trusting either call.
- ✅ **GDT + protected mode** — flat null/code/data descriptors,
  `LGDT`, `CR0.PE` set, far jump into 32-bit code.
- ✅ **Driver 1/3: VGA graphics** — mode 13h (320×200, 256 colors)
  is set via BIOS `int 10h` while still in real mode (the last BIOS
  call this code makes), and the 32-bit entry point draws 8 color
  bars straight into the framebuffer at `0xA0000` to prove it's live.
- ✅ **IDT + remapped PIC, interrupts on.** CPU exceptions (0-31)
  fill the screen red and halt. IRQ0 (timer) and IRQ1 (keyboard)
  each blink a small marker square - proof the interrupt plumbing
  actually works, not the real drivers yet (see Next milestone).

**Bug fix along the way:** `kernel_layout.inc` originally loaded
the kernel at segment `0x1000` (physical 64 KiB) instead of segment
`0`. That's fine in real mode, but once protected mode's GDT uses a
flat, base-0 model, a jump to a label only lands correctly if that
label's assembled address already equals its true linear address -
true automatically at segment 0, not otherwise. The far jump into
`pm_entry` would have landed on the wrong address. Fixed by moving
back to segment 0 (matching the original hex-monitor project),
offset `0x8000` instead.

## Next milestone

Drivers 2/3 and 3/3, for real this time: decode keyboard scancodes
into actual key events (`irq1_handler` currently just reads and
discards them), and reprogram the PIT away from its default
~18.2 Hz into a rate a game loop can actually use. Once both exist,
a basic game loop (clear → draw → read input → update → repeat) is
the next real milestone — see "Longer-term roadmap toward games"
below.

## Longer-term roadmap toward games

1. Protected-mode switch (above)
2. Minimal 32-bit kernel: VGA graphics (mode 13h — 320×200, 256
   colors — is the easiest starting point), a keyboard driver off
   IRQ1, and the PIT timer for consistent frame pacing
3. A basic game loop: clear screen → draw → read input → update
   state → repeat
4. Prove the loop on something simple first — Pong, Snake, or
   Breakout are the classic first bare-metal games for good reason
5. Sports games are a great goal, but they're a big step up from
   step 4 (multiple entities, collision, scoring rules, animation,
   usually AI opponents) — a realistic follow-on once step 4 is
   solid, not a good place to start

## Same real-hardware caveats as the hex-monitor project

- Legacy BIOS/CSM only — no CSM means it won't run on that hardware
  at all, only in QEMU or a VM with EFI disabled.
- `dd`ing `kernel.img` to a real device overwrites the first
  sectors of whatever `/dev/sdX` is — confirm the device with
  `lsblk` first. QEMU is the safe way to test, every time.
