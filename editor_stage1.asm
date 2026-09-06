; ============================================================
; editor.asm — Stage 2: bare-metal hex-monitor editor
;
; Loaded at 0000:8000 by boot.asm. Not size-constrained like the
; boot sector — padded at the end to STAGE2_SECTORS*512 bytes so
; the disk image layout always matches what boot.asm expects.
;
; Controls:
;   type chars    - insert into the buffer, echoed to screen
;   Enter         - newline
;   Backspace     - delete last character
;   F1            - save buffer to disk (persists across reboot)
;   F2            - assemble buffer as hex byte pairs and RUN them
;   F3            - load buffer back from disk
;
; F2 is a hex monitor, not a full assembler: type raw machine
; code as hex byte pairs (e.g. "B0 41 B4 0E CD 10 C3" pokes AL=0x41,
; AH=0x0E, calls INT 10h to print 'A', then returns) — same idea
; as the Apple 1 / early microcomputer monitor programs. Whitespace
; and CR/LF between pairs are ignored. It auto-appends a RET (0xC3)
; after whatever you typed, so a program that forgets to return
; still hands control back to the editor instead of running off
; into memory. There's no memory protection here — bad bytes can
; hang or reset the machine. That's normal for a hex monitor;
; nothing is permanently changed unless you press F1.
; ============================================================
[BITS 16]
[ORG 0x8000]
%include "layout.inc"

stage2_start:
    mov [boot_drive_s2], dl     ; capture the drive number before anything else touches DL

    mov ax, 0x0003
    int 0x10                    ; text mode, clears the screen

    call reset_buffer
    mov si, banner
    call print_string

editor_loop:
    mov ah, 0x00
    int 0x16                    ; block until a key is pressed; AL=ascii, AH=scan code

    cmp ah, 0x3B
    je do_save                  ; F1
    cmp ah, 0x3C
    je do_run                   ; F2
    cmp ah, 0x3D
    je do_load                  ; F3

    cmp al, 0x0D
    je do_enter
    cmp al, 0x08
    je do_backspace
    cmp al, 32
    jl editor_loop               ; ignore other control keys

    mov bx, [buf_len]
    cmp bx, TEXT_MAX-1
    jge editor_loop
    mov di, TEXT_BUFFER
    add di, bx
    mov [di], al
    inc word [buf_len]
    mov ah, 0x0E
    int 0x10
    jmp editor_loop

do_enter:
    mov bx, [buf_len]
    cmp bx, TEXT_MAX-2
    jge editor_loop
    mov di, TEXT_BUFFER
    add di, bx
    mov byte [di], 0x0D
    mov byte [di+1], 0x0A
    add word [buf_len], 2
    mov ah, 0x0E
    mov al, 0x0D
    int 0x10
    mov al, 0x0A
    int 0x10
    jmp editor_loop

do_backspace:
    mov bx, [buf_len]
    or bx, bx
    jz editor_loop
    dec bx
    mov [buf_len], bx
    mov di, TEXT_BUFFER
    add di, bx
    mov byte [di], 0
    mov ah, 0x0E
    mov al, 0x08
    int 0x10
    mov al, ' '
    int 0x10
    mov al, 0x08
    int 0x10
    jmp editor_loop

reset_buffer:
    mov word [buf_len], 0
    ret

; ---------- F1: save TEXT_BUFFER to disk ----------
; Writes a 1-sector length header, then the buffer contents,
; so a later load knows exactly how many bytes are valid.
do_save:
    pusha
    mov ax, [buf_len]
    mov [hdr_buf], ax

    mov word [dap_count], 1
    mov word [dap_off], hdr_buf
    mov word [dap_seg], 0
    mov dword [dap_lba_lo], HDR_LBA
    mov dword [dap_lba_hi], 0
    mov si, dap
    mov ah, 0x43
    xor al, al                   ; no verify-after-write
    mov dl, [boot_drive_s2]
    int 0x13
    jc .err

    mov ax, [buf_len]
    or ax, ax
    jz .done                     ; empty buffer: header alone is enough

    mov cx, ax
    add cx, 511
    shr cx, 9                    ; sectors = ceil(len / 512)
    mov word [dap_count], cx
    mov word [dap_off], TEXT_BUFFER
    mov word [dap_seg], 0
    mov dword [dap_lba_lo], DATA_LBA
    mov dword [dap_lba_hi], 0
    mov si, dap
    mov ah, 0x43
    xor al, al
    mov dl, [boot_drive_s2]
    int 0x13
    jc .err

.done:
    popa
    mov si, msg_saved
    call print_string
    jmp editor_loop
.err:
    popa
    mov si, msg_save_err
    call print_string
    jmp editor_loop

; ---------- F3: load TEXT_BUFFER back from disk ----------
do_load:
    pusha
    mov word [dap_count], 1
    mov word [dap_off], hdr_buf
    mov word [dap_seg], 0
    mov dword [dap_lba_lo], HDR_LBA
    mov dword [dap_lba_hi], 0
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive_s2]
    int 0x13
    jc .err

    mov ax, [hdr_buf]
    cmp ax, TEXT_MAX
    ja .err                      ; garbage/never-saved header -> bail cleanly
    mov [buf_len], ax
    or ax, ax
    jz .skip_data

    mov cx, ax
    add cx, 511
    shr cx, 9
    mov word [dap_count], cx
    mov word [dap_off], TEXT_BUFFER
    mov word [dap_seg], 0
    mov dword [dap_lba_lo], DATA_LBA
    mov dword [dap_lba_hi], 0
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive_s2]
    int 0x13
    jc .err

.skip_data:
    popa
    mov ax, 0x0003
    int 0x10
    mov si, banner
    call print_string
    mov si, TEXT_BUFFER
    mov cx, [buf_len]
    mov ah, 0x0E
.echo:
    jcxz .echodone
    lodsb
    int 0x10
    dec cx
    jmp .echo
.echodone:
    mov si, msg_loaded
    call print_string
    jmp editor_loop
.err:
    popa
    mov si, msg_load_err
    call print_string
    jmp editor_loop

; ---------- F2: assemble TEXT_BUFFER as hex byte-pairs & run ----------
do_run:
    pusha
    mov si, TEXT_BUFFER
    mov di, EXEC_RAM
    mov cx, [buf_len]

.parse_loop:
    jcxz .parse_done
    lodsb
    dec cx
    cmp al, ' '
    je .parse_loop
    cmp al, 0x0D
    je .parse_loop
    cmp al, 0x0A
    je .parse_loop

    call hex_nibble               ; first digit of the pair
    jc .parse_loop                ; not hex -> skip it (lenient parser)
    mov ah, al                    ; stash high nibble

    jcxz .parse_done               ; need a second digit to complete the byte
    lodsb
    dec cx
    call hex_nibble
    jc .parse_loop                 ; second char wasn't hex -> drop this byte, keep going

    mov bl, ah
    shl bl, 4
    or  bl, al
    cmp di, EXEC_RAM+EXEC_MAX-1     ; leave room for the auto RET below
    jae .parse_done
    mov [di], bl
    inc di
    jmp .parse_loop

.parse_done:
    mov [compiled_end], di
    popa
    mov di, [compiled_end]
    cmp di, EXEC_RAM
    je .nothing
    mov byte [di], 0xC3            ; guarantee a return even if you forgot one
    call EXEC_RAM
    mov si, msg_ran
    call print_string
    jmp editor_loop
.nothing:
    mov si, msg_nothing
    call print_string
    jmp editor_loop

; Convert one ASCII hex char in AL to a 0-15 value in AL.
; Sets carry if AL wasn't a hex digit (0-9, A-F, a-f).
hex_nibble:
    cmp al, '0'
    jb .invalid
    cmp al, '9'
    jbe .digit
    and al, 0xDF                   ; fold lowercase a-f to uppercase A-F
    cmp al, 'A'
    jb .invalid
    cmp al, 'F'
    ja .invalid
    sub al, 'A' - 10
    clc
    ret
.digit:
    sub al, '0'
    clc
    ret
.invalid:
    stc
    ret

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

buf_len:        dw 0
compiled_end:   dw 0
boot_drive_s2:  db 0
hdr_buf:        dw 0

dap:            db 0x10, 0
dap_count:      dw 0
dap_off:        dw 0
dap_seg:        dw 0
dap_lba_lo:     dd 0
dap_lba_hi:     dd 0

banner:      db "--- Bare-Metal Hex-Monitor Editor ---", 0x0D, 0x0A
             db "F1 Save   F2 Assemble+Run   F3 Load", 0x0D, 0x0A, 0x0D, 0x0A, 0
msg_saved:      db 0x0D, 0x0A, "[saved]", 0x0D, 0x0A, 0
msg_save_err:   db 0x0D, 0x0A, "[save failed]", 0x0D, 0x0A, 0
msg_loaded:     db 0x0D, 0x0A, "[loaded]", 0x0D, 0x0A, 0
msg_load_err:   db 0x0D, 0x0A, "[load failed - nothing saved yet?]", 0x0D, 0x0A, 0
msg_ran:        db 0x0D, 0x0A, "[ran]", 0x0D, 0x0A, 0
msg_nothing:    db 0x0D, 0x0A, "[buffer empty, nothing to run]", 0x0D, 0x0A, 0

times (STAGE2_SECTORS*512)-($-$$) db 0
