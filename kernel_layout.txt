; ============================================================
; kernel_layout.inc — shared memory & disk layout for the
; kernel-track bootloader (kernel_boot.asm / kernel.asm).
;
; Kept separate from the hex-monitor editor's layout.inc on
; purpose: these are two independent boot images that happen to
; share the same INT 13h plumbing, not one project.
; ============================================================

; --- where the stage-2 kernel is loaded in RAM ---
KERNEL_SEG      equ 0x1000          ; segment 0x1000 -> physical 0x10000 (64 KiB)
KERNEL_OFF      equ 0x0000
KERNEL_SECTORS  equ 32              ; 16 KiB reserved for now - raise this as the
                                     ; kernel grows (lots of room before the
                                     ; 0xA0000 video-memory hole at 640 KiB)
