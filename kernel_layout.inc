; ============================================================
; kernel_layout.inc — shared memory & disk layout for the
; kernel-track bootloader (kernel_boot.asm / kernel.asm).
;
; Kept separate from the hex-monitor editor's layout.inc on
; purpose: these are two independent boot images that happen to
; share the same INT 13h plumbing, not one project.
; ============================================================

; --- where the stage-2 kernel is loaded in RAM ---
; Segment 0 is deliberate, not the original 0x1000 - see the NOTE
; at the top of kernel.asm for why a non-zero segment breaks once
; protected mode's flat (base-0) GDT is in the picture.
KERNEL_SEG      equ 0x0000
KERNEL_OFF      equ 0x8000          ; physical 0x8000 (32 KiB)
KERNEL_SECTORS  equ 32              ; 16 KiB reserved for now - raise this as the
                                     ; kernel grows (room up to the 0xA0000
                                     ; video-memory hole at 640 KiB)
