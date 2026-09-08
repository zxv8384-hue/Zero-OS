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

## Next milestone (marked in `kernel.asm`)

1. Enable the A20 line — without it, protected mode can't reliably
   address memory past 1 MiB.
2. Build a GDT — at minimum a null descriptor, one code descriptor,
   one data descriptor.
3. Set CR0's PE bit and far-jump into a 32-bit code segment.

Do these one at a time and re-test in QEMU after each — a broken
A20/GDT/PM switch is much easier to debug in isolation than mixed
in with everything else.

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
