; ============================================================
; kernel.asm — Stage 2 kernel entry point.
; Loaded by kernel_boot.asm at KERNEL_SEG:KERNEL_OFF, real mode.
;
; NOTE: KERNEL_SEG:KERNEL_OFF is 0x0000:0x8000, not segment 0x1000
; - see kernel_layout.inc. A flat, base-0 GDT only lands correctly
; on labels whose ORG-computed address is already the true linear
; address, which is automatic at segment 0 and nowhere else.
;
; Full boot -> protected-mode chain, done:
;   1. A20 line enabled (BIOS method, keyboard-controller fallback,
;      verified by actually testing memory, not trusting the call)
;   2. Flat GDT built: null, code, and data descriptors
;   3. CR0's PE bit set, far jump into 32-bit code at pm_entry
;   4. Paging: one page directory, 4 MiB pages (PSE), identity-
;      mapped across the full 4 GiB - virtual == physical
;      everywhere, so nothing else here needed to change for it
;   5. VGA graphics, mode 13h - color bars prove the framebuffer
;      works, then draw_frame takes over for everything after
;   6. Keyboard: real Set-1 scancode decoding (press, release, the
;      0xE0 extended prefix) for Up/Down, in key_state
;   7. PIT timer, reprogrammed from ~18.2 Hz to PIT_HZ. tick_count
;      runs continuously; move_tick paces game_update separately
;      from the raw interrupt rate
;
; PONG. game_update (called every MOVE_EVERY_N_TICKS ticks) is the
; real game loop: move the player paddle from key_state, chase it
; with a simple AI paddle, move the ball, resolve paddle/wall
; collisions and scoring, redraw via draw_frame. draw_frame redraws
; everything from scratch each call instead of tracking old
; positions to erase - simpler to get right by hand than it is
; fast, and at this resolution and tick rate, fast was never really
; in question. No on-screen numbers yet (no text rendering) - score
; is a row of small pips per side instead. CPU exceptions still
; fill the screen red and halt, unchanged from before.
;
; DISK I/O: a native ATA PIO driver (primary channel, ports
; 0x1F0-0x1F7 / 0x3F6 - the classic IDE-compatibility ports Hudson
; FCH's SATA controller exposes when the firmware's set to IDE/
; Legacy rather than AHCI), LBA28, master drive only. BIOS int 13h
; stopped being usable the moment PE=1, same as int 10h - this is
; the only way to touch the disk from here on. Demonstrated with
; something real: the high score is saved to a dedicated sector
; whenever it's beaten, loaded back at boot, and shown as a third
; row of pips along the bottom of the screen.
; ============================================================
[BITS 16]
[ORG 0x8000]                    ; matches KERNEL_OFF in kernel_layout.inc
%include "kernel_layout.inc"

kernel_start:
    mov [boot_drive_k], dl      ; stage 1 leaves the boot drive in DL - save it,
                                 ; protected-mode disk access will need it later

    mov si, msg_hello
    call print_string

    ; ---------------------------------------------------------
    ; Step 1: enable the A20 line
    ; ---------------------------------------------------------
    call check_a20
    cmp ax, 1
    je .a20_done                ; already on - true by default on most QEMU builds

    call enable_a20_bios        ; try the easy way first
    call check_a20
    cmp ax, 1
    je .a20_done

    call enable_a20_kbc         ; BIOS call unsupported or didn't work - fall back
    call check_a20
    cmp ax, 1
    je .a20_done

    mov si, msg_a20_fail
    call print_string
    jmp halt                    ; nothing past this point is safe without A20

.a20_done:
    mov si, msg_a20_ok
    call print_string

    ; ---------------------------------------------------------
    ; Steps 2+3: build the GDT, then flip into protected mode
    ; ---------------------------------------------------------
    mov si, msg_pm_entering
    call print_string

    ; Driver #1: switch to VGA mode 13h (320x200, 256 colors) while
    ; a BIOS call still works - int 10h stops functioning the
    ; instant PE=1, so this has to happen here, not in pm_entry.
    mov ax, 0x0013
    int 0x10

    cli                           ; no interrupts until a real IDT exists
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEL:pm_entry         ; far jump: flushes the prefetch queue and loads
                                   ; CS with a 32-bit selector - the actual moment
                                   ; execution becomes 32-bit

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

; Returns AX=1 if the A20 line is enabled, AX=0 if it's still masked.
; Standard trick: 0000:0500 and FFFF:0510 are the same physical byte
; (0x100500) only when A20 is disabled and the segment:offset wraps.
; Write different values through each alias and see if they collide.
check_a20:
    pushf
    push ds
    push es
    push si
    push di
    cli

    xor ax, ax
    mov es, ax
    mov di, 0x0500

    not ax
    mov ds, ax
    mov si, 0x0510

    mov al, [es:di]
    push ax
    mov al, [ds:si]
    push ax

    mov byte [es:di], 0x00
    mov byte [ds:si], 0xFF
    cmp byte [es:di], 0xFF

    pop ax
    mov [ds:si], al
    pop ax
    mov [es:di], al

    mov ax, 0
    je .done
    mov ax, 1
.done:
    pop di
    pop si
    pop es
    pop ds
    popf
    ret

; Try the BIOS's own A20 support (INT 15h, AX=2401h) - one call,
; and works on QEMU/SeaBIOS and virtually every real BIOS since
; the 90s. check_a20 above is what actually confirms it worked.
enable_a20_bios:
    mov ax, 0x2401
    int 0x15
    ret

; Fallback: the old-school method, toggling A20 through the
; keyboard controller's output port. Fussier than the BIOS call,
; but works on hardware where INT 15h/2401h doesn't.
enable_a20_kbc:
    cli
    call kbc_wait1
    mov al, 0xAD                ; disable keyboard interface
    out 0x64, al

    call kbc_wait1
    mov al, 0xD0                ; command: read controller output port
    out 0x64, al

    call kbc_wait2
    in al, 0x60
    push ax

    call kbc_wait1
    mov al, 0xD1                ; command: write controller output port
    out 0x64, al

    call kbc_wait1
    pop ax
    or al, 2                    ; set the A20 gate bit, leave the rest alone
    out 0x60, al

    call kbc_wait1
    mov al, 0xAE                ; re-enable keyboard interface
    out 0x64, al

    call kbc_wait1
    sti
    ret

kbc_wait1:                      ; wait until input buffer empty (safe to write)
    in al, 0x64
    test al, 2
    jnz kbc_wait1
    ret

kbc_wait2:                      ; wait until output buffer full (safe to read)
    in al, 0x64
    test al, 1
    jz kbc_wait2
    ret

boot_drive_k: db 0
msg_hello:    db 0x0D, 0x0A, "Stage 2 kernel alive - protected mode goes here next.", 0x0D, 0x0A, 0
msg_a20_ok:   db "[A20 enabled]", 0x0D, 0x0A, 0
msg_a20_fail: db "[A20 FAILED - halted, nothing past this point is safe]", 0x0D, 0x0A, 0
msg_pm_entering: db 0x0D, 0x0A, "Entering protected mode...", 0x0D, 0x0A, 0

; --- Flat GDT: null, code, and data descriptors, 4 GiB each ---
gdt_start:
gdt_null:
    dd 0x0
    dd 0x0

gdt_code:
    dw 0xFFFF                    ; limit 0:15
    dw 0x0                       ; base 0:15
    db 0x0                       ; base 16:23
    db 10011010b                 ; access: present, ring 0, code, executable, readable
    db 11001111b                 ; flags: 4 KiB granularity + 32-bit, limit 16:19
    db 0x0                       ; base 24:31

gdt_data:
    dw 0xFFFF                    ; limit 0:15
    dw 0x0                       ; base 0:15
    db 0x0                       ; base 16:23
    db 10010010b                 ; access: present, ring 0, data, writable
    db 11001111b                 ; flags: 4 KiB granularity + 32-bit, limit 16:19
    db 0x0                       ; base 24:31
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1          ; GDT size minus 1, per LGDT's convention
    dd (KERNEL_SEG << 4) + gdt_start    ; linear address of the GDT

CODE_SEL equ gdt_code - gdt_start       ; 0x08
DATA_SEL equ gdt_data - gdt_start       ; 0x10

; --- IDT: 256 gates, 8 bytes each. Reserved zeroed; setup_idt only
; --- explicitly fills 0-0x2F (see setup_idt below) - anything else
; --- is left "not present" on purpose (see setup_idt's comment).
idt: times 256*8 db 0

idt_descriptor:
    dw (256*8) - 1                      ; IDT size minus 1, per LIDT's convention
    dd (KERNEL_SEG << 4) + idt          ; linear address of the IDT

; --- tunables ---
PIT_HZ              equ 100             ; timer ticks per second
PIT_DIVISOR         equ 1193182 / PIT_HZ
MOVE_EVERY_N_TICKS  equ 3               ; game_update runs once per this many ticks
BG_COLOR            equ 0x08            ; dark gray

PADDLE_W     equ 4
PADDLE_H     equ 32
PADDLE_SPEED equ 2                      ; player paddle, pixels per update
AI_SPEED     equ 1                      ; AI paddle - slower on purpose, so it's beatable
PADDLE_COLOR equ 0x0F                   ; white
LEFT_X       equ 8                      ; player paddle's fixed x
RIGHT_X      equ 320 - 8 - PADDLE_W     ; AI paddle's fixed x

BALL_SIZE    equ 4
BALL_SPEED   equ 2
BALL_COLOR   equ 0x0E                   ; yellow

PIP_SIZE  equ 4                         ; score pips - no text rendering yet, so
PIP_COLOR equ 0x0A                      ; score is a row of small squares instead
PIP_MAX   equ 10                        ; stop adding pips past this, just to be safe
HIGH_SCORE_PIP_COLOR equ 0x0C           ; a third, differently-colored pip row

; --- primary ATA channel, legacy/compatibility I/O ports - the
; --- mode Hudson FCH's SATA controller exposes when firmware is
; --- set to IDE/Legacy rather than AHCI
ATA_DATA       equ 0x1F0
ATA_ERROR      equ 0x1F1
ATA_SECCOUNT   equ 0x1F2
ATA_LBA_LOW    equ 0x1F3
ATA_LBA_MID    equ 0x1F4
ATA_LBA_HIGH   equ 0x1F5
ATA_DRIVE_HEAD equ 0x1F6
ATA_COMMAND    equ 0x1F7
ATA_STATUS     equ 0x1F7

SAVE_MAGIC equ 0x504F4E47               ; marks a sector as "really our save data",
                                         ; not just whatever happened to be on disk

key_state:  db 0        ; bit0=up, bit1=down (only up/down matter to Pong)
ext_flag:   db 0        ; set for one byte after a 0xE0 extended-scancode prefix
move_tick:  dd 0        ; ticks elapsed since game_update last ran
tick_count: dd 0        ; total timer ticks since interrupts were enabled

left_y:  dd (200 - PADDLE_H) / 2        ; player paddle, vertically centered
right_y: dd (200 - PADDLE_H) / 2        ; AI paddle, vertically centered

ball_x:  dd (320 - BALL_SIZE) / 2       ; centered
ball_y:  dd (200 - BALL_SIZE) / 2
ball_dx: dd BALL_SPEED
ball_dy: dd 1

player_score: dd 0
ai_score:     dd 0
high_score:   dd 0

align 4
sector_buf: times 512 db 0      ; scratch buffer for one disk sector at a time

; --- shared parameters for draw_rect, set by its caller each time ---
draw_x:     dd 0
draw_y:     dd 0
draw_w:     dd 0
draw_h:     dd 0
draw_color: db 0

; ---------------------------------------------------------
; 32-bit protected-mode code starts here
; ---------------------------------------------------------
[BITS 32]
pm_entry:
    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000              ; fresh 32-bit stack, well clear of our own code
    cld                            ; guarantee forward direction for every string
                                    ; instruction below (stosb/stosd/insw/outsw) -
                                    ; DF defaults to 0 anyway, but don't rely on it

    ; Paging, on early and identity-mapped, so everything below runs
    ; under it - if this were set up wrong, nothing past this line
    ; would work at all, rather than something subtle breaking later.
    call setup_paging

    ; Load the saved high score before the first frame draws, so it
    ; shows correctly from the very first screen instead of popping
    ; in later. Leaves high_score at its initialized 0 if there's no
    ; valid save yet - see load_high_score.
    call load_high_score

    ; Prove mode 13h's framebuffer is actually live: draw 8 vertical
    ; color bars across the full 320x200 screen. EDI just keeps
    ; advancing linearly through all 64000 bytes (320*200) - since
    ; 8 bars * 40px exactly equals one 320px row, the same 8-color
    ; pattern repeats on every row with no per-row math needed.
    mov edi, 0xA0000
    xor edx, edx                  ; row = 0..199
.row:
    xor ebx, ebx                  ; bar = 0..7
.bar:
    mov eax, ebx
    inc eax                       ; colors 1-8 (skip 0 = black, so bars show up)
    mov ecx, 40                   ; bar width: 320 / 8 bars
    rep stosb
    inc ebx
    cmp ebx, 8
    jl .bar

    inc edx
    cmp edx, 200
    jl .row

    ; The color bars above already proved the graphics driver works.
    ; draw_frame takes over from here: clears to background and
    ; draws both paddles, the ball, and the (currently 0-0) score.
    call draw_frame

    ; --- Driver plumbing: PIT rate, IDT + remapped PIC, then go ---
    call init_pit
    call remap_pic
    call setup_idt
    lidt [idt_descriptor]
    sti

.idle:                            ; interrupts do the work now - just wait for one
    hlt
    jmp .idle

; Any CPU exception (0-31) lands here. We don't try to identify
; which one or recover - just make it obvious and stop, since
; there's nowhere sensible to continue to yet.
exception_handler:
    mov edi, 0xA0000
    mov eax, 0x04040404          ; solid red, 4 pixels per write
    mov ecx, (320*200)/4
    rep stosd
    cli
    hlt
    jmp $

; IRQ0 (timer, reprogrammed to PIT_HZ by init_pit). Counts total
; ticks, and runs one game_update every MOVE_EVERY_N_TICKS ticks -
; decoupling "how often the timer fires" from "how often the game
; actually updates" is the whole point of tracking ticks at all.
irq0_handler:
    pusha
    inc dword [tick_count]

    inc dword [move_tick]
    cmp dword [move_tick], MOVE_EVERY_N_TICKS
    jl .skip_move
    mov dword [move_tick], 0
    call game_update
.skip_move:

    mov al, 0x20                  ; EOI to master PIC
    out 0x20, al
    popa
    iret

; IRQ1 (keyboard). Decodes Set-1 scancodes for Up/Down only - Pong
; only needs vertical movement, so left/right are deliberately not
; decoded. Both are "extended" scancodes: a 0xE0 prefix byte, then
; the real code, high bit set on release (Up is 0xE0 0x48 pressed,
; 0xE0 0xC8 released; Down is 0xE0 0x50 / 0xE0 0xD0).
; Updates bits in key_state; game_update (called from irq0_handler)
; is the only thing that reads it.
irq1_handler:
    pusha
    in al, 0x60

    cmp al, 0xE0
    jne .check_byte
    mov byte [ext_flag], 1
    jmp .ack

.check_byte:
    cmp byte [ext_flag], 0
    je .ack                       ; not an Up/Down byte - ignore it
    mov byte [ext_flag], 0

    mov ah, al
    and ah, 0x80                  ; ah = 0x80 on release, 0x00 on press
    and al, 0x7F                  ; al = the base scancode either way

    mov cl, 0
    cmp al, 0x48
    je .have_bit
    mov cl, 1
    cmp al, 0x50
    je .have_bit
    jmp .ack                      ; some other extended key - ignore it

.have_bit:
    mov bl, 1
    shl bl, cl                    ; bl = the key_state bit for this direction
    cmp ah, 0
    jne .clear_bit
    or [key_state], bl
    jmp .ack
.clear_bit:
    not bl
    and [key_state], bl

.ack:
    mov al, 0x20                  ; EOI to master PIC
    out 0x20, al
    popa
    iret

; Everything else on either PIC (IRQ2-15) - acknowledge and ignore.
; IRQ8-15 technically only need the slave EOI'd too, but EOI'ing
; both unconditionally is harmless and saves tracking which PIC
; this stub doesn't otherwise care about.
irq_generic_handler:
    pusha
    mov al, 0x20
    out 0xA0, al
    out 0x20, al
    popa
    iret

; One full frame of Pong, called every MOVE_EVERY_N_TICKS ticks:
; move the player paddle from input, chase it with the AI paddle,
; move the ball, resolve wall/paddle collisions and scoring, then
; redraw everything via draw_frame.
game_update:
    ; --- player paddle: up/down from key_state, clamped ---
    mov al, [key_state]
    test al, 0x01
    jz .not_p_up
    sub dword [left_y], PADDLE_SPEED
    cmp dword [left_y], 0
    jge .not_p_up
    mov dword [left_y], 0
.not_p_up:
    test al, 0x02
    jz .not_p_down
    add dword [left_y], PADDLE_SPEED
    cmp dword [left_y], 200 - PADDLE_H
    jle .not_p_down
    mov dword [left_y], 200 - PADDLE_H
.not_p_down:

    ; --- AI paddle: chase the ball's center, slower than the player ---
    mov eax, [ball_y]
    add eax, BALL_SIZE / 2
    mov ebx, [right_y]
    add ebx, PADDLE_H / 2
    cmp eax, ebx
    je .ai_done
    jl .ai_up
    add dword [right_y], AI_SPEED
    jmp .ai_clamp
.ai_up:
    sub dword [right_y], AI_SPEED
.ai_clamp:
    cmp dword [right_y], 0
    jge .ai_min_ok
    mov dword [right_y], 0
.ai_min_ok:
    cmp dword [right_y], 200 - PADDLE_H
    jle .ai_done
    mov dword [right_y], 200 - PADDLE_H
.ai_done:

    ; --- move the ball ---
    mov eax, [ball_dx]
    add [ball_x], eax
    mov eax, [ball_dy]
    add [ball_y], eax

    ; --- bounce off top/bottom walls ---
    cmp dword [ball_y], 0
    jg .not_top
    mov dword [ball_y], 0
    neg dword [ball_dy]
.not_top:
    cmp dword [ball_y], 200 - BALL_SIZE
    jl .not_bottom
    mov dword [ball_y], 200 - BALL_SIZE
    neg dword [ball_dy]
.not_bottom:

    ; --- ball vs left (player) paddle: standard AABB overlap test,
    ; --- all 4 checks must pass or it's not a hit ---
    mov eax, [ball_x]
    cmp eax, LEFT_X + PADDLE_W
    jge .no_left_hit
    mov eax, [ball_x]
    add eax, BALL_SIZE
    cmp eax, LEFT_X
    jle .no_left_hit
    mov eax, [ball_y]
    mov ebx, [left_y]
    add ebx, PADDLE_H
    cmp eax, ebx
    jge .no_left_hit
    mov eax, [ball_y]
    add eax, BALL_SIZE
    cmp eax, [left_y]
    jle .no_left_hit
    mov dword [ball_dx], BALL_SPEED
    mov dword [ball_x], LEFT_X + PADDLE_W   ; nudge clear of the paddle so this
.no_left_hit:                                ; can't re-trigger next frame

    ; --- ball vs right (AI) paddle - same test, mirrored ---
    mov eax, [ball_x]
    add eax, BALL_SIZE
    cmp eax, RIGHT_X
    jle .no_right_hit
    mov eax, [ball_x]
    cmp eax, RIGHT_X + PADDLE_W
    jge .no_right_hit
    mov eax, [ball_y]
    mov ebx, [right_y]
    add ebx, PADDLE_H
    cmp eax, ebx
    jge .no_right_hit
    mov eax, [ball_y]
    add eax, BALL_SIZE
    cmp eax, [right_y]
    jle .no_right_hit
    mov dword [ball_dx], -BALL_SPEED
    mov dword [ball_x], RIGHT_X - BALL_SIZE
.no_right_hit:

    ; --- scoring: did the ball get all the way past a paddle? ---
    cmp dword [ball_x], 0
    jge .not_ai_score
    inc dword [ai_score]
    call reset_ball
    jmp .score_done
.not_ai_score:
    cmp dword [ball_x], 320
    jle .score_done
    inc dword [player_score]
    call reset_ball

    mov eax, [player_score]
    cmp eax, [high_score]
    jle .score_done
    mov [high_score], eax
    call save_high_score
.score_done:

    call draw_frame
    ret

; Resets the ball to center after a point, with a small variation
; in serve direction taken from tick_count's low bits - a cheap
; stand-in for randomness that's good enough for this.
reset_ball:
    mov dword [ball_x], (320 - BALL_SIZE) / 2
    mov dword [ball_y], (200 - BALL_SIZE) / 2

    mov eax, [tick_count]
    test eax, 1
    jz .dx_pos
    mov dword [ball_dx], -BALL_SPEED
    jmp .dx_done
.dx_pos:
    mov dword [ball_dx], BALL_SPEED
.dx_done:
    test eax, 2
    jz .dy_pos
    mov dword [ball_dy], -1
    jmp .dy_done
.dy_pos:
    mov dword [ball_dy], 1
.dy_done:
    ret

; Clears to background, then draws both paddles, the ball, and the
; score pips - the whole visible game state, redrawn from scratch.
draw_frame:
    mov edi, 0xA0000
    mov eax, BG_COLOR | (BG_COLOR << 8) | (BG_COLOR << 16) | (BG_COLOR << 24)
    mov ecx, (320*200)/4
    rep stosd

    mov dword [draw_x], LEFT_X
    mov eax, [left_y]
    mov [draw_y], eax
    mov dword [draw_w], PADDLE_W
    mov dword [draw_h], PADDLE_H
    mov byte [draw_color], PADDLE_COLOR
    call draw_rect

    mov dword [draw_x], RIGHT_X
    mov eax, [right_y]
    mov [draw_y], eax
    mov dword [draw_w], PADDLE_W
    mov dword [draw_h], PADDLE_H
    mov byte [draw_color], PADDLE_COLOR
    call draw_rect

    mov eax, [ball_x]
    mov [draw_x], eax
    mov eax, [ball_y]
    mov [draw_y], eax
    mov dword [draw_w], BALL_SIZE
    mov dword [draw_h], BALL_SIZE
    mov byte [draw_color], BALL_COLOR
    call draw_rect

    call draw_score
    ret

; Draws up to PIP_MAX small squares near the top for each side's
; score - the simplest possible scoreboard without any text
; rendering, which this project doesn't have yet.
draw_score:
    mov dword [draw_y], 4
    mov dword [draw_w], PIP_SIZE
    mov dword [draw_h], PIP_SIZE
    mov byte [draw_color], PIP_COLOR

    mov ecx, [player_score]
    cmp ecx, PIP_MAX
    jle .p_count_ok
    mov ecx, PIP_MAX
.p_count_ok:
    xor edx, edx
.p_loop:
    cmp edx, ecx
    jge .p_done
    mov eax, edx
    imul eax, PIP_SIZE + 2
    add eax, 4
    mov [draw_x], eax
    call draw_rect
    inc edx
    jmp .p_loop
.p_done:

    mov ecx, [ai_score]
    cmp ecx, PIP_MAX
    jle .a_count_ok
    mov ecx, PIP_MAX
.a_count_ok:
    xor edx, edx
.a_loop:
    cmp edx, ecx
    jge .a_done
    mov eax, edx
    imul eax, PIP_SIZE + 2
    neg eax
    add eax, 316
    mov [draw_x], eax
    call draw_rect
    inc edx
    jmp .a_loop
.a_done:

    ; --- high score, bottom of the screen - a different color and
    ; --- position from the live player/AI score above, since this
    ; --- one persists across reboots (via the ATA driver) rather
    ; --- than resetting when the kernel does. The clearest possible
    ; --- proof load_high_score actually restored something real.
    mov dword [draw_y], 200 - PIP_SIZE - 4
    mov dword [draw_w], PIP_SIZE
    mov dword [draw_h], PIP_SIZE
    mov byte [draw_color], HIGH_SCORE_PIP_COLOR

    mov ecx, [high_score]
    cmp ecx, PIP_MAX
    jle .h_count_ok
    mov ecx, PIP_MAX
.h_count_ok:
    xor edx, edx
.h_loop:
    cmp edx, ecx
    jge .h_done
    mov eax, edx
    imul eax, PIP_SIZE + 2
    add eax, 4
    mov [draw_x], eax
    call draw_rect
    inc edx
    jmp .h_loop
.h_done:
    ret

; Draws a draw_w x draw_h rectangle at (draw_x, draw_y) in
; draw_color. Every shape in this game - both paddles, the ball,
; every score pip - goes through this one routine, so the actual
; pixel-writing logic exists exactly once.
draw_rect:
    push eax
    push ecx
    push edx
    push edi
    push esi

    mov edi, [draw_y]
    imul edi, 320
    add edi, [draw_x]
    add edi, 0xA0000

    mov dl, [draw_color]
    xor esi, esi                  ; row = 0..draw_h-1
.rect_row:
    mov al, dl
    mov ecx, [draw_w]
    rep stosb
    mov ecx, 320
    sub ecx, [draw_w]
    add edi, ecx
    inc esi
    cmp esi, [draw_h]
    jl .rect_row

    pop esi
    pop edi
    pop edx
    pop ecx
    pop eax
    ret

; Writes IDT entry EAX to point at handler EBX, using CODE_SEL and
; a 32-bit interrupt gate (present, ring 0).
set_idt_gate:
    push edi
    mov edi, eax
    shl edi, 3                             ; each gate is 8 bytes: edi = vector*8
    add edi, idt + (KERNEL_SEG << 4)        ; idt's true linear address

    mov [edi], bx                           ; offset 0:15
    mov word [edi+2], CODE_SEL              ; selector
    mov byte [edi+4], 0                     ; reserved
    mov byte [edi+5], 0x8E                  ; present, ring 0, 32-bit interrupt gate
    shr ebx, 16
    mov [edi+6], bx                         ; offset 16:31

    pop edi
    ret

; Fills the IDT: vectors 0-31 -> exception_handler (CPU faults),
; vector 0x20 -> irq0_handler (timer), vector 0x21 -> irq1_handler
; (keyboard), vectors 0x22-0x2F -> irq_generic_handler (everything
; else). Vectors above 0x2F are left zeroed/not-present on purpose
; - nothing should ever use them, and if something does, that's
; itself a #GP that exception_handler will catch.
setup_idt:
    push ebx
    push ecx

    xor ecx, ecx
.exc_loop:
    mov eax, ecx
    mov ebx, exception_handler + (KERNEL_SEG << 4)
    call set_idt_gate
    inc ecx
    cmp ecx, 32
    jl .exc_loop

    mov eax, 0x20
    mov ebx, irq0_handler + (KERNEL_SEG << 4)
    call set_idt_gate

    mov eax, 0x21
    mov ebx, irq1_handler + (KERNEL_SEG << 4)
    call set_idt_gate

    mov ecx, 0x22
.irq_loop:
    mov eax, ecx
    mov ebx, irq_generic_handler + (KERNEL_SEG << 4)
    call set_idt_gate
    inc ecx
    cmp ecx, 0x30
    jl .irq_loop

    pop ecx
    pop ebx
    ret

; Remaps the two 8259 PICs so IRQs 0-15 land on interrupt vectors
; 0x20-0x2F instead of their power-on default of 0x08-0x0F (which
; overlaps CPU exception vectors - the whole reason this remap is
; mandatory before enabling interrupts in protected mode).
remap_pic:
    mov al, 0x11                  ; ICW1: start init sequence, expect ICW4
    out 0x20, al
    call io_wait
    out 0xA0, al
    call io_wait

    mov al, 0x20                  ; ICW2: master PIC vector offset = 0x20
    out 0x21, al
    call io_wait
    mov al, 0x28                  ; ICW2: slave PIC vector offset = 0x28
    out 0xA1, al
    call io_wait

    mov al, 0x04                  ; ICW3: tell master a slave sits on IRQ2
    out 0x21, al
    call io_wait
    mov al, 0x02                  ; ICW3: tell slave its cascade identity
    out 0xA1, al
    call io_wait

    mov al, 0x01                  ; ICW4: 8086 mode
    out 0x21, al
    call io_wait
    out 0xA1, al
    call io_wait

    xor al, al                    ; unmask every IRQ line on both PICs - safe,
    out 0x21, al                  ; since every vector 0x20-0x2F now has at
    call io_wait                  ; least the generic handler behind it
    out 0xA1, al
    ret

; A tiny delay for older hardware, where the PIC needs a moment
; between successive out instructions - writing to an unused port
; is the traditional way to burn a few cycles safely.
io_wait:
    out 0x80, al
    ret

; Reprograms PIT channel 0 (the one wired to IRQ0) from its default
; ~18.2 Hz to PIT_HZ, using mode 3 (square wave) and lobyte/hibyte
; access so the 16-bit divisor goes out as two separate writes.
init_pit:
    mov al, 0x36                  ; channel 0, lobyte/hibyte, mode 3, binary
    out 0x43, al
    mov ax, PIT_DIVISOR
    out 0x40, al                  ; divisor low byte
    mov al, ah
    out 0x40, al                  ; divisor high byte
    ret

; --- ATA PIO driver (primary channel, LBA28, master drive only -
; --- this kernel only ever talks to one drive, so there's no drive-
; --- switching logic to get wrong). Two low-level pieces
; --- (ata_read_sector / ata_write_sector) plus two callers
; --- (load_high_score / save_high_score) built on top of them.

; Polls ATA_STATUS until BSY (bit 7) clears, giving up after a
; large but finite number of tries instead of hanging forever if no
; drive ever answers. Returns: CF clear = ready, CF set = timeout.
ata_wait_bsy_clear:
    push eax
    push ecx
    push edx
    mov edx, ATA_STATUS           ; >0xFF, so this has to go through dx -
    mov ecx, 0x100000             ; "in al, ATA_STATUS" directly isn't legal
.poll:
    in al, dx
    test al, 0x80                 ; BSY
    jz .ready
    dec ecx
    jnz .poll
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ready:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; Polls ATA_STATUS until DRQ (bit 3) sets, meaning the drive is
; ready to move data - or bails out immediately if ERR (bit 0) sets,
; since DRQ isn't coming after an error. Same timeout/return
; convention as ata_wait_bsy_clear.
ata_wait_drq:
    push eax
    push ecx
    push edx
    mov edx, ATA_STATUS
    mov ecx, 0x100000
.poll:
    in al, dx
    test al, 0x01                 ; ERR
    jnz .fail
    test al, 0x08                 ; DRQ
    jnz .ready
    dec ecx
    jnz .poll
.fail:
    pop edx
    pop ecx
    pop eax
    stc
    ret
.ready:
    pop edx
    pop ecx
    pop eax
    clc
    ret

; Reads 1 sector (512 bytes) from LBA EAX into the buffer at EDI.
; Returns: CF clear on success (buffer filled, EDI advanced past
; it), CF set on error/timeout (buffer untouched). Clobbers
; EAX/EBX/ECX/EDX either way. REP INSW is safe to run with
; interrupts enabled - the CPU can service an interrupt mid-transfer
; and correctly resumes the string instruction afterward - so there
; is no cli/sti here.
ata_read_sector:
    push ebx
    push ecx
    push edx

    mov ebx, eax                  ; keep the LBA safe - eax gets reused below

    call ata_wait_bsy_clear
    jc .fail

    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xE0                   ; LBA mode, master drive, + LBA bits 24-27
    mov dx, ATA_DRIVE_HEAD
    out dx, al

    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al

    mov al, bl
    mov dx, ATA_LBA_LOW
    out dx, al

    mov eax, ebx
    shr eax, 8
    mov dx, ATA_LBA_MID
    out dx, al

    mov eax, ebx
    shr eax, 16
    mov dx, ATA_LBA_HIGH
    out dx, al

    mov dx, ATA_COMMAND
    mov al, 0x20                  ; READ SECTORS (with retry)
    out dx, al

    call ata_wait_drq
    jc .fail

    mov dx, ATA_DATA
    mov ecx, 256                  ; 256 words = 512 bytes
    rep insw

    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; Writes 1 sector (512 bytes) from the buffer at ESI to LBA EAX,
; then flushes the drive's write cache and waits for that to finish
; too - skipping the flush is a classic way to "successfully" write
; data that a power cut moments later makes vanish. Returns: CF
; clear on success, CF set on error/timeout. Clobbers EAX/EBX/ECX/EDX.
ata_write_sector:
    push ebx
    push ecx
    push edx

    mov ebx, eax

    call ata_wait_bsy_clear
    jc .fail

    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    mov dx, ATA_DRIVE_HEAD
    out dx, al

    mov dx, ATA_SECCOUNT
    mov al, 1
    out dx, al

    mov al, bl
    mov dx, ATA_LBA_LOW
    out dx, al

    mov eax, ebx
    shr eax, 8
    mov dx, ATA_LBA_MID
    out dx, al

    mov eax, ebx
    shr eax, 16
    mov dx, ATA_LBA_HIGH
    out dx, al

    mov dx, ATA_COMMAND
    mov al, 0x30                  ; WRITE SECTORS (with retry)
    out dx, al

    call ata_wait_drq
    jc .fail

    mov dx, ATA_DATA
    mov ecx, 256
    rep outsw

    call ata_wait_bsy_clear       ; wait for the write itself to land
    jc .fail

    mov dx, ATA_COMMAND
    mov al, 0xE7                  ; CACHE FLUSH
    out dx, al
    call ata_wait_bsy_clear
    jc .fail

    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

; Loads the saved high score from SAVE_LBA. If that sector doesn't
; start with SAVE_MAGIC - first boot ever, or a disk that's never
; had this written - high_score is left at its initialized 0
; instead of trusting whatever garbage was actually on the sector.
load_high_score:
    push eax
    push edi

    mov eax, SAVE_LBA
    mov edi, sector_buf + (KERNEL_SEG << 4)
    call ata_read_sector
    jc .done                       ; read failed - keep high_score at 0

    mov eax, [sector_buf]
    cmp eax, SAVE_MAGIC
    jne .done                      ; no valid save here yet

    mov eax, [sector_buf + 4]
    mov [high_score], eax
.done:
    pop edi
    pop eax
    ret

; Writes the current high_score to SAVE_LBA, preceded by SAVE_MAGIC
; so load_high_score can tell a real save apart from blank disk
; space next boot.
save_high_score:
    push eax
    push esi

    mov dword [sector_buf], SAVE_MAGIC
    mov eax, [high_score]
    mov [sector_buf + 4], eax

    mov eax, SAVE_LBA
    mov esi, sector_buf + (KERNEL_SEG << 4)
    call ata_write_sector

    pop esi
    pop eax
    ret

; --- Paging: one page directory, 4 MiB pages (PSE), identity-
; --- mapped across the full 4 GiB - virtual == physical everywhere,
; --- so nothing else in this kernel needs to change to keep
; --- working under it. Needs its own 4 KiB alignment, hence "align"
; --- below; the padding that takes is why KERNEL_SECTORS is 48
; --- instead of 32 now (see kernel_layout.inc).
align 4096
page_directory: times 1024 dd 0

; Fills page_directory with 1024 identity-mapped 4 MiB entries,
; enables PSE (CR4), points CR3 at the directory, then sets CR0's
; PG bit. Because the mapping is identity, every address this
; kernel already uses keeps meaning the same thing - the actual
; proof this worked is that everything after it (color bars, Pong)
; keeps running exactly as before, instead of the machine resetting
; the moment CR0.PG is set.
setup_paging:
    push eax
    push ecx
    push edi

    mov edi, page_directory + (KERNEL_SEG << 4)
    xor ecx, ecx
.pde_loop:
    mov eax, ecx
    shl eax, 22                   ; ecx * 4 MiB = this entry's identity base
    or eax, 0x83                  ; present, writable, page size = 4 MiB
    mov [edi], eax
    add edi, 4
    inc ecx
    cmp ecx, 1024
    jl .pde_loop

    mov eax, cr4
    or eax, 0x10                  ; CR4.PSE - permit 4 MiB pages
    mov cr4, eax

    mov eax, page_directory + (KERNEL_SEG << 4)
    mov cr3, eax

    mov eax, cr0
    or eax, 0x80000000            ; CR0.PG - enable paging
    mov cr0, eax

    pop edi
    pop ecx
    pop eax
    ret

times (KERNEL_SECTORS*512)-($-$$) db 0
