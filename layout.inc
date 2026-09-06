; ============================================================
; layout.inc — shared memory & disk layout for boot.asm/editor.asm
; This is the single source of truth for both files — if you
; resize anything, change it here only.
; ============================================================

; --- where Stage 2 lives in RAM ---
STAGE2_SEG      equ 0x0000
STAGE2_OFF      equ 0x8000
STAGE2_SECTORS  equ 16              ; 8 KiB reserved for stage 2 code/data

; --- RAM layout used by stage 2 ---
TEXT_BUFFER     equ 0x1000          ; typed source (hex text) lives here
TEXT_MAX        equ 2048            ; max typed characters
EXEC_RAM        equ 0x3000          ; assembled machine code lands + runs here
EXEC_MAX        equ 512             ; max compiled bytes

; --- disk layout (LBA sectors, 0-indexed; LBA 0 = boot sector) ---
HDR_LBA         equ 1 + STAGE2_SECTORS   ; 1 sector: 2-byte saved-length header
DATA_LBA        equ HDR_LBA + 1          ; saved text starts here
DATA_SECTORS    equ (TEXT_MAX + 511) / 512   ; sectors reserved for saved text
