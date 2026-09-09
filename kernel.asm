; ============================================================
; kernel.asm — Stage 2 kernel entry point.
; Loaded by kernel_boot.asm at KERNEL_SEG:KERNEL_OFF, real mode.
;
; NOTE: KERNEL_SEG/KERNEL_OFF moved to 0x0000:0x8000 (was
; 0x1000:0x0000). With a flat, base-0 GDT, any address this code
; jumps to in 32-bit mode has to equal its ORG-computed value
; directly - no segment multiplication left to lean on. Segment 0
; makes that automatic; a non-zero segment doesn't, and the far
; jump into pm_entry a few steps below would have landed on the
; wrong address. Caught this while wiring up the IDT, below.
;
; Full boot -> protected-mode chain, done:
;   1. A20 line enabled (BIOS method, keyboard-controller fallback,
;      result actually verified by testing memory)
;   2. Flat GDT built: null, code, and data descriptors
;   3. CR0's PE bit set, far jump into 32-bit code at pm_entry
;   4. Driver 1/3: VGA graphics, mode 13h, color-bar test pattern
;   5. IDT + remapped PIC, interrupts enabled. CPU exceptions fill
;      the screen red and halt. IRQ0 (timer) and IRQ1 (keyboard)
;      each blink a small marker square - proof both fire and get
;      acknowledged correctly, not real drivers yet.
;
; Still ahead: decoding keyboard scancodes into actual keys, and
; reprogramming the PIT to a useful tick rate instead of its
; default ~18.2 Hz. Then a real game loop. See KERNEL_TRACK.md.
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

tick_color: db 0x01                     ; toggled by irq0_handler each timer tick

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

    ; --- Driver plumbing: IDT + remapped PIC, then enable interrupts ---
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

; IRQ0 (timer). Toggles a small 8x8 marker square in the top-left
; corner each tick - the simplest possible proof the IDT/PIC setup
; actually works, since ticks start firing continuously the moment
; interrupts are enabled, at the PIT's default ~18.2 Hz.
irq0_handler:
    pusha
    xor byte [tick_color], 0x0F
    mov edi, 0xA0000
    mov al, [tick_color]
    xor edx, edx                  ; row = 0..7
.tick_row:
    mov ecx, 8
    rep stosb
    add edi, 320 - 8
    inc edx
    cmp edx, 8
    jl .tick_row

    mov al, 0x20                  ; EOI to master PIC
    out 0x20, al
    popa
    iret

; IRQ1 (keyboard). Reads and discards the scancode for now - no
; scancode-to-key decoding yet, that's the real keyboard driver,
; still to come. This just proves the interrupt fires and gets
; acknowledged safely, via a second marker square next to the
; timer's, so a keypress is visibly distinguishable from a tick.
irq1_handler:
    pusha
    in al, 0x60                   ; must read the scancode, or the keyboard
                                   ; controller won't send another one
    mov edi, 0xA0000 + 16         ; a second marker, just right of the tick one
    mov al, 0x0E                  ; fixed color - a keypress just needs to be visible
    xor edx, edx
.key_row:
    mov ecx, 8
    rep stosb
    add edi, 320 - 8
    inc edx
    cmp edx, 8
    jl .key_row

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

times (KERNEL_SECTORS*512)-($-$$) db 0
