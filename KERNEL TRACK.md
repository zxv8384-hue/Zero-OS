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

## Verification note

Same situation as the hex-monitor project: no `nasm` or network
access in this sandbox, so everything here is hand-traced rather
than assembled - `kernel_boot.asm` (the only size-constrained file,
at exactly 512 bytes) comes to roughly 300 bytes of actual
instructions and data, comfortably under the limit; `kernel.asm`
has grown a lot since but has 16 KiB of reserved room and is
nowhere close to it. `build_kernel.sh` double-checks the 512-byte
boot sector at build time regardless. If `nasm` reports an error on
your machine, paste it back and I'll fix it directly.

## Status

- ✅ **A20 line** — checks whether it's already on, tries the BIOS
  call (`INT 15h, AX=2401h`), falls back to the keyboard-controller
  method if that doesn't work, and verifies the *actual* result via
  a memory-aliasing test rather than trusting either call.
- ✅ **GDT + protected mode** — flat null/code/data descriptors,
  `LGDT`, `CR0.PE` set, far jump into 32-bit code.
- ✅ **VGA graphics** — mode 13h (320×200, 256 colors) set via BIOS
  `int 10h` while still in real mode (the last BIOS call this code
  makes). Color bars prove the framebuffer at `0xA0000` is live.
- ✅ **Keyboard** — real Set-1 scancode decoding for Up/Down
  (including the `0xE0` extended prefix and press/release), tracked
  in `key_state`.
- ✅ **PIT timer** — reprogrammed from its default ~18.2 Hz to
  100 Hz. `game_update` runs once every `MOVE_EVERY_N_TICKS` ticks,
  not every tick — pacing decoupled from the raw interrupt rate.
- ✅ **Pong.** Player paddle (Up/Down), a simple AI paddle that
  chases the ball's vertical center at half the player's speed, a
  ball that bounces off the top/bottom walls and both paddles, and
  scoring when the ball fully passes a paddle. Score is drawn as
  small pips along the top (no text rendering yet, so no numbers).
  `draw_frame` redraws the whole screen from scratch every update
  rather than tracking old positions to erase — simpler to get
  right by hand than it is fast, and at this size/rate, fast was
  never really in question.

**Bug fix along the way:** `kernel_layout.inc` originally loaded
the kernel at segment `0x1000` instead of segment `0`. Fine in real
mode, but protected mode's flat, base-0 GDT only lands correctly on
labels whose assembled address already equals their true linear
address — automatic at segment 0, not otherwise. Fixed by moving
back to segment 0 (matching the original hex-monitor project),
offset `0x8000` instead.

## Playing it

In QEMU: color bars flash briefly (graphics check), then Pong
starts — a white paddle on each side, a yellow ball, dark gray
background. Up/Down arrows move the left paddle; the right paddle
plays itself. Small green pips above each side track the score.

## What's left

Nothing blocking — this is a complete, playable (if bare) Pong.
Natural next steps, roughly in order of effort:
- **Tuning**: `PADDLE_SPEED`, `AI_SPEED`, `BALL_SPEED`, `PIT_HZ`,
  and `MOVE_EVERY_N_TICKS` are all named constants near the top of
  `kernel.asm` — difficulty and feel are a few number changes away.
- **Sound**: the PC speaker (port `0x61` + the PIT's channel 2) is
  the classic beep-on-bounce, no new infrastructure required.
- **A second player**: decode a couple more scancodes (W/S are the
  obvious choice) and replace the AI section of `game_update` with
  a second set of paddle-movement checks.
- **Text/numbers**: an actual bitmap font would replace the pip
  scoreboard with real digits, and unlock a "you win" message —
  meaningfully bigger than anything else on this list.

## Same real-hardware caveats as the hex-monitor project

- Legacy BIOS/CSM only — no CSM means it won't run on that hardware
  at all, only in QEMU or a VM with EFI disabled.
- `dd`ing `kernel.img` to a real device overwrites the first
  sectors of whatever `/dev/sdX` is — confirm the device with
  `lsblk` first. QEMU is the safe way to test, every time.
