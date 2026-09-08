; ============================================================
; kernel.asm — Stage 2 kernel entry point (still 16-bit real
; mode for now). Loaded by kernel_boot.asm at KERNEL_SEG:KERNEL_OFF.
;
; This is a deliberate stub, not a placeholder you forgot to
; fill in: it proves the boot -> load -> jump chain works end
; to end before any new complexity gets piled on top. The next
; milestone is marked below, in order:
;   1. Enable the A20 line (so protected mode can address >1 MiB)
;   2. Build a GDT: null descriptor, code descriptor, data descriptor
;   3. Set CR0's PE bit and far-jump into a 32-bit code segment
; Do these one at a time and re-test in QEMU after each - a
; broken A20/GDT/PM switch is much easier to debug in isolation
; than mixed in with everything else.
; ============================================================
[BITS 16]
[ORG 0x0000]                    ; matches KERNEL_OFF in kernel_layout.inc
%include "kernel_layout.inc"

kernel_start:
    mov ax, cs                  ; stage 1 left DS/ES pointed at segment 0; this
    mov ds, ax                  ; code now runs at KERNEL_SEG, so DS/ES have to
    mov es, ax                  ; be re-pointed here before touching any label below
    mov [boot_drive_k], dl      ; stage 1 leaves the boot drive in DL - save it,
                                 ; protected-mode disk access will need it later

    mov si, msg_hello
    call print_string

    ; ---------------------------------------------------------
    ; NEXT MILESTONE STARTS HERE: A20 -> GDT -> CR0.PE -> far jump
    ; ---------------------------------------------------------

    jmp halt

halt:
    cli
    hlt
    jmp halt

print_string:
    mov ah, 0x0E
.loop:
    lodsb
    or al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    ret

boot_drive_k: db 0
msg_hello:    db 0x0D, 0x0A, "Stage 2 kernel alive - protected mode goes here next.", 0x0D, 0x0A, 0

times (KERNEL_SECTORS*512)-($-$$) db 0
