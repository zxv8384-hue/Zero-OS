; ============================================================
; boot.asm — Stage 1 bootloader (must assemble to exactly 512 bytes)
;
; A real boot sector is far too small (510 usable bytes) to hold
; an editor + assembler + disk I/O. So Stage 1 does exactly one
; job: use INT 13h LBA extensions to load Stage 2 from disk into
; RAM, then jump to it. Stage 2 is unconstrained by the 512-byte
; limit and holds all the real logic.
;
; NOTE: this is a legacy-BIOS (MBR) boot sector. It will run in
; QEMU's default SeaBIOS, or on real hardware booted in Legacy/
; CSM mode. Pure UEFI boot (no CSM) will NOT execute this — UEFI
; only understands PE/COFF executables via its own boot services,
; not INT 0x10/0x13/0x16 real-mode BIOS calls. Most modern laptops
; have dropped CSM entirely, so test in QEMU first.
; ============================================================
[BITS 16]
[ORG 0x7C00]
%include "layout.inc"

start:
    jmp 0x0000:main           ; normalize CS:IP to 0000:xxxx —
                               ; some BIOSes enter at 07C0:0000 instead,
                               ; which would break every ORG-relative label

main:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00             ; stack grows down from here, away from our code
    sti

    mov [boot_drive], dl       ; BIOS passes the boot drive number in DL

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

    ; Load Stage 2 using extended read (function 0x42) via a DAP
    mov word [dap_count], STAGE2_SECTORS
    mov word [dap_off],   STAGE2_OFF
    mov word [dap_seg],   STAGE2_SEG
    mov dword [dap_lba_lo], 1          ; stage 2 starts right after the boot sector (LBA 1)
    mov dword [dap_lba_hi], 0
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    mov dl, [boot_drive]       ; keep the drive number live in DL for stage 2
    jmp STAGE2_SEG:STAGE2_OFF

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

; Disk Address Packet, reused for the stage-2 load
dap:          db 0x10, 0
dap_count:    dw 0
dap_off:      dw 0
dap_seg:      dw 0
dap_lba_lo:   dd 0
dap_lba_hi:   dd 0

msg_loading:  db "Stage 1: loading editor...", 0x0D, 0x0A, 0
msg_no_ext:   db "BIOS has no LBA disk extensions - halted.", 0x0D, 0x0A, 0
msg_disk_err: db "Disk error loading stage 2 - halted.", 0x0D, 0x0A, 0

times 510-($-$$) db 0
dw 0xAA55
