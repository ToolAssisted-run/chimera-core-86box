; probe.asm - the gate's own boot floppy for the 86Box core.
;
; A boot sector that needs nothing but a PC BIOS: it shows on the screen
; and keeps in memory what the gate asks about.
;
;   0000:7E00  word   ticks seen (the BIOS timer, INT 1Ah)
;   0000:7E02  word   keys read (INT 16h)
;   0000:7E04  word   the last key read: scan code (high), character (low)
;   0000:7E06  4 byte "PRB1", so a test can find the block
;   0000:7E0A  word   bytes read from COM1 (a serial mouse sends 3 a move)
;   0000:7E0C  word   the sum of those bytes
;   0000:7E0E  byte   the game port (0x201) as last read: the buttons are
;                     bits 4-7, 0 while held
;
; Line 0 of the screen: "86BOX PROBE T=xxxx K=xxxx L=xxxx M=xxxx S=xxxx",
; in hex.
; 8088 code only. Written for these tests; free to distribute.
        cpu 8086
        bits 16
        org 0x7c00

start:
        cli
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7c00
        sti
        mov ax, 0x0003          ; 80x25 text
        int 0x10
        mov word [0x7e00], 0
        mov word [0x7e02], 0
        mov word [0x7e04], 0
        mov word [0x7e06], 'PR'  ; word moves: an 8088 has no 32-bit ones
        mov word [0x7e08], 'B1'
        mov word [0x7e0a], 0
        mov word [0x7e0c], 0
        mov dx, 0x3fc           ; COM1: DTR, RTS and OUT2 on - a serial
        mov al, 0x0b            ; mouse takes its power from DTR and RTS
        out dx, al
        xor ah, ah              ; the timer now
        int 0x1a
        mov [last], dx

main:
        xor ah, ah
        int 0x1a
        cmp dx, [last]
        je .keys
        mov [last], dx
        inc word [0x7e00]
.keys:
        mov dx, 0x3fd           ; a byte from COM1 waiting?
        in al, dx
        test al, 1
        jz .nomouse
        mov dx, 0x3f8
        in al, dx
        inc word [0x7e0a]
        xor ah, ah
        add [0x7e0c], ax
        jmp .keys
.nomouse:
        mov dx, 0x201           ; the game port's buttons
        in al, dx
        mov [0x7e0e], al
        mov ah, 0x01            ; a key waiting?
        int 0x16
        jz .show
        xor ah, ah
        int 0x16
        mov [0x7e04], ax
        inc word [0x7e02]
.show:
        mov ah, 0x02            ; cursor to 0,0
        xor bh, bh
        xor dx, dx
        int 0x10
        mov si, title
        call puts
        mov ax, [0x7e00]
        call puthex
        mov si, keys
        call puts
        mov ax, [0x7e02]
        call puthex
        mov si, lastk
        call puts
        mov ax, [0x7e04]
        call puthex
        mov si, mouse
        call puts
        mov ax, [0x7e0a]
        call puthex
        mov si, msum
        call puts
        mov ax, [0x7e0c]
        call puthex
        hlt                     ; until the next interrupt
        jmp main

puts:                           ; ds:si, zero-terminated
        lodsb
        or al, al
        jz .done
        mov ah, 0x0e
        xor bx, bx
        int 0x10
        jmp puts
.done:
        ret

puthex:                         ; ax as four hex digits (8088 code: a
        mov dx, ax              ; rotate by more than one needs cl)
        mov di, 4
.digit:
        mov cl, 4
        rol dx, cl
        mov ax, dx
        push dx
        and al, 0x0f
        add al, '0'
        cmp al, '9'
        jbe .out
        add al, 'A' - '9' - 1
.out:
        mov ah, 0x0e
        xor bx, bx
        int 0x10
        pop dx
        dec di
        jnz .digit
        ret

title:  db '86BOX PROBE T=', 0
keys:   db ' K=', 0
lastk:  db ' L=', 0
mouse:  db ' M=', 0
msum:   db ' S=', 0
last:   dw 0

        times 510 - ($ - $$) db 0
        dw 0xaa55
