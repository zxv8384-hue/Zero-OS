; ============================================================
; kernel_boot.asm — Stage 1 bootloader for the "Zero-OS" kernel
; track (must assemble to exactly 512 bytes).
;
; Sibling to boot.asm/editor.asm, not a replacement — the hex-
; monitor pair still works standalone and is untouched. This is
; a second, independent boot image: the start of an actual OS
; kernel instead of a hex monitor.
;
; This stage does exactly three things:
;   1. Set up a stack in low memory
;   2. Load the stage-2 kernel from disk into higher memory
;   3. Jump to it (still in real mode)
; A20, the GDT, and the actual switch to protected mode are
; deliberately NOT here — that's kernel.asm's job, next.
; ============================================================
[BITS 16]
[ORG 0x7C00]
%include "kernel_layout.inc"

start:
    jmp 0x0000:main             ; normalize CS:IP - some BIOSes enter at 07C0:0000,
                                 ; which would break every ORG-relative label

main:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00              ; stack in low memory, grows down away from this code
    sti

    mov [boot_drive], dl        ; BIOS passes the boot drive number in DL

    mov si, msg_loading
    call print_string

    ; Confirm INT 13h LBA extensions are present (function 0x41)
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc no_ext
    cmp bx, 0xAA55
    jne no_ext

    ; Load the stage-2 kernel using extended read (function 0x42) via a DAP
    mov word [dap_count], KERNEL_SECTORS
    mov word [dap_off],   KERNEL_OFF
    mov word [dap_seg],   KERNEL_SEG
    mov dword [dap_lba_lo], 1            ; kernel starts right after the boot sector (LBA 1)
    mov dword [dap_lba_hi], 0
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    mov si, msg_jumping
    call print_string

    mov dl, [boot_drive]        ; keep the drive number live in DL for the kernel
    jmp KERNEL_SEG:KERNEL_OFF   ; still real mode - kernel takes it from here

no_ext:
    mov si, msg_no_ext
    call print_string
    jmp halt

disk_error:
    mov si, msg_disk_err
    call print_string

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

boot_drive:   db 0

; Disk Address Packet for the stage-2 load
dap:          db 0x10, 0
dap_count:    dw 0
dap_off:      dw 0
dap_seg:      dw 0
dap_lba_lo:   dd 0
dap_lba_hi:   dd 0

msg_loading:  db "Stage 1: loading kernel...", 0x0D, 0x0A, 0
msg_jumping:  db "Stage 1: jumping to kernel.", 0x0D, 0x0A, 0
msg_no_ext:   db "BIOS has no LBA disk extensions - halted.", 0x0D, 0x0A, 0
msg_disk_err: db "Disk error loading kernel - halted.", 0x0D, 0x0A, 0

times 510-($-$$) db 0
dw 0xAA55
