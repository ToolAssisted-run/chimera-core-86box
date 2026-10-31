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
;   0000:7E10  word   the first word of the floppy's sector 2 as last read
;   0000:7E12  word   the BIOS's status (AX) after that read
;   0000:7E14  word   the BIOS's status (AX) after the write at start
;   0000:7E16  byte   an XT-IDE card at 300h, driven directly (no BIOS of
;                     its own needed): the drive's status after the read of
;                     its sector 2 (50h when all went well, FFh with no card)
;   0000:7E18  word   the first word of that sector as read
;   0000:7E1A  byte   the drive's status after "HD" was written there at start
;   0000:7E1C  byte   the CD-ROM drive (ATAPI, the card's second drive): its
;                     status after READ(10) of sector 16 (00h or FFh: no drive)
;   0000:7E1E  6 byte the start of that sector: 01h "CD001" on an ISO 9660 disc
;   0000:7E24  byte   the drive's status after PLAY AUDIO of track 2
;   0000:7E25  byte   the drive's status after READ TOC
;   0000:7E26  4 byte track 2's first sector, from the table of contents
;                     (big-endian, as the drive gives it)
;
; At start, after the hard disk, it asks the CD-ROM drive for its table of
; contents, reads sector 16 and plays 5 seconds of track 2 (an audio track
; on the gate's disc). Each command is tried up to four times: a drive
; answers the first command after a disc goes in with "unit attention".
;
; At start it writes "WR" and the timer's count to sector 2 of the floppy
; (head 0, track 0) and reads the sector back; it reads it again after every
; key, so a test can ask after a state was loaded whether the written sector
; is still the machine's.
;
; At start it also plays one held note on an AdLib's FM chip (ports
; 0x388/0x389): with an AdLib in the machine the sound has it, without one
; the writes go nowhere.
;
; Line 0 of the screen: "86BOX PROBE T=xxxx K=xxxx L=xxxx M=xxxx S=xxxx",
; in hex.
; 8088 code only. Written for these tests; free to distribute.
        cpu 8086
        bits 16

; Sector 1 loads the program (sectors 3 to 9 of track 0) to 0000:9000 and
; runs it; sector 2 is the sector the program writes and reads.
        section boot start=0 vstart=0x7c00
        cli
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7c00
        sti
.load:  mov ax, 0x0207          ; read 7 sectors
        mov bx, 0x9000
        mov cx, 0x0003          ; track 0, from sector 3
        xor dh, dh              ; head 0; dl is the boot drive
        int 0x13
        jc .load
        jmp 0x0000:0x9000
        times 510 - ($ - $$) db 0
        dw 0xaa55
        times 512 db 0          ; sector 2

        section main start=1024 vstart=0x9000

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
        mov si, opl             ; the note: register, value, ..., 0
.opl:
        lodsw
        or al, al
        jz .opldone
        mov dx, 0x388
        out dx, al
        mov al, ah
        inc dx
        out dx, al
        jmp .opl
.opldone:
        xor ah, ah              ; the timer now
        int 0x1a
        mov [last], dx
        mov word [0x8000], 'WR' ; sector 2: "WR", the timer's low word
        mov [0x8002], dx
        mov ax, 0x0301          ; write one sector
        mov bx, 0x8000
        mov cx, 0x0002          ; track 0, sector 2
        xor dx, dx              ; head 0, drive A:
        int 0x13
        mov [0x7e14], ax
        mov word [0x8000], 'HD' ; the hard disk's sector 2 likewise
        mov al, 0x30            ; WRITE SECTORS
        call ide_command
        jc .nowrite
        mov si, 0x8000
        mov cx, 256
.wword: lodsw
        mov dx, 0x308           ; rev 1: the high byte first, at +8,
        xchg al, ah
        out dx, al
        xchg al, ah
        mov dx, 0x300           ; then the low byte, which writes the word
        out dx, al
        loop .wword
        call ide_wait
.nowrite:
        mov dx, 0x307
        in al, dx
        mov [0x7e1a], al
        call cd_test
        call readback

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
        call readback
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

readback:                       ; sector 2 into 0000:8200
        mov ax, 0x0201
        mov bx, 0x8200
        mov cx, 0x0002
        xor dx, dx
        int 0x13
        mov [0x7e12], ax
        mov ax, [0x8200]
        mov [0x7e10], ax
        mov word [0x8200], 0
        mov al, 0x20            ; and the hard disk's: READ SECTORS
        call ide_command
        jc .noread
        mov di, 0x8200
        mov cx, 256
.rword: mov dx, 0x300           ; the low byte reads the word,
        in al, dx
        mov dx, 0x308           ; the high byte waits at +8
        mov ah, al
        in al, dx
        xchg al, ah
        stosw
        loop .rword
        call ide_wait
.noread:
        mov dx, 0x307
        in al, dx
        mov [0x7e16], al
        mov ax, [0x8200]
        mov [0x7e18], ax
        ret

; One sector, number 2 of cylinder 0, head 0, of the master drive at 300h:
; the command in al. Carry set when the drive never became ready (no card).
ide_command:
        push ax
        call ide_wait
        jc .fail
        mov dx, 0x306           ; master, head 0
        mov al, 0xa0
        out dx, al
        call ide_wait
        jc .fail
        mov dx, 0x302           ; one sector
        mov al, 1
        out dx, al
        inc dx                  ; sector 2
        mov al, 2
        out dx, al
        inc dx                  ; cylinder 0
        xor al, al
        out dx, al
        inc dx
        out dx, al
        mov dx, 0x307
        pop ax
        out dx, al
        mov cx, 0xffff          ; until the drive asks for the data
.drq:   in al, dx
        test al, 0x80
        jnz .drqn
        test al, 0x08
        jnz .ok
.drqn:  loop .drq
        stc
        ret
.ok:    clc
        ret
.fail:  pop ax
        stc
        ret

; The CD-ROM drive: the table of contents, sector 16, then 5 s of track 2.
cd_test:
        cld
        xor ax, ax
        mov di, 0x7e1c          ; the block's CD part, 7E1C to 7E29
        mov cx, 7
        rep stosw
        mov di, 0x8400          ; the buffer: 0000:8400 to 8C00
        mov cx, 1024
        rep stosw
        mov byte [0x7e1c], 0xff
        mov byte [0x7e24], 0xff
        mov byte [0x7e25], 0xff
        mov si, pk_toc
        call atapi_retry
        mov [0x7e25], al
        mov ax, [0x8400 + 16]   ; track 2's descriptor: 4 + 8, its address at +4
        mov [0x7e26], ax
        mov [pk_play + 2], ax
        mov ax, [0x8400 + 18]
        mov [0x7e28], ax
        mov [pk_play + 4], ax
        mov si, pk_read
        call atapi_retry
        mov [0x7e1c], al
        mov si, 0x8400
        mov di, 0x7e1e
        mov cx, 3
        rep movsw
        mov si, pk_play
        call atapi_retry
        mov [0x7e24], al
        ret

; The packet at si, up to four times while the drive answers with an error.
; al: the drive's status at the end (FFh when it never answered).
atapi_retry:
        mov bp, 4
.again: push bp
        mov di, 0x8400
        call atapi_packet
        pop bp
        jc .out
        test al, 0x01
        jz .out
        dec bp
        jnz .again
.out:   ret

; One ATAPI command: PACKET (A0h) to the slave at 300h, the 12 bytes at si,
; then whatever data the drive sends, into es:di. al: the status at the end.
atapi_packet:
        push si
        call ide_wait
        jc .fail
        mov dx, 0x306           ; the slave
        mov al, 0xb0
        out dx, al
        call ide_wait
        jc .fail
        mov dx, 0x301           ; no DMA
        xor al, al
        out dx, al
        mov dx, 0x304           ; at most 2048 bytes at a time
        out dx, al
        inc dx
        mov al, 0x08
        out dx, al
        mov dx, 0x307
        mov al, 0xa0
        out dx, al
        call atapi_wait
        jc .fail
        test al, 0x01
        jnz .done
        test al, 0x08
        jz .done
        pop si
        push si
        mov cx, 6               ; the packet, a word at a time
.pk:    lodsw
        mov dx, 0x308
        xchg al, ah
        out dx, al
        xchg al, ah
        mov dx, 0x300
        out dx, al
        loop .pk
.data:  call atapi_wait
        jc .fail
        test al, 0x01
        jnz .done
        test al, 0x08
        jz .done                ; no more data: the command is over
        mov dx, 0x304           ; how many bytes this time
        in al, dx
        mov cl, al
        inc dx
        in al, dx
        mov ch, al
        inc cx
        shr cx, 1
        cmp di, 0x8c00          ; never past the buffer
        jae .done
.rd:    mov dx, 0x300
        in al, dx
        mov dx, 0x308
        mov ah, al
        in al, dx
        xchg al, ah
        stosw
        loop .rd
        jmp .data
.done:  pop si
        clc
        ret
.fail:  pop si
        mov al, 0xff
        stc
        ret

; until the drive is not busy, a longer wait than ide_wait's (a CD drive
; seeks); al: its status; carry set if it never answered
atapi_wait:
        mov bx, 32
.o:     mov dx, 0x307
        mov cx, 0xffff
.w:     in al, dx
        cmp al, 0xff
        je .gone
        test al, 0x80
        jz .ok
        loop .w
        dec bx
        jnz .o
.gone:  stc
        ret
.ok:    clc
        ret

; until the drive is not busy; carry set if it stays busy (or is not there)
ide_wait:
        mov dx, 0x307
        mov cx, 0xffff
.w:     in al, dx
        cmp al, 0xff
        je .gone
        test al, 0x80
        jz .done
        loop .w
.gone:  stc
        ret
.done:  clc
        ret

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

opl:    db 0x20, 0x01, 0x23, 0x01, 0x40, 0x10, 0x43, 0x00
        db 0x60, 0xf0, 0x63, 0xf0, 0x80, 0x77, 0x83, 0x77
        db 0xa0, 0x98, 0xb0, 0x31, 0, 0
title:  db '86BOX PROBE T=', 0
keys:   db ' K=', 0
lastk:  db ' L=', 0
mouse:  db ' M=', 0
msum:   db ' S=', 0
last:   dw 0
pk_toc:  db 0x43, 0, 0, 0, 0, 0, 1, 0x01, 0x00, 0, 0, 0      ; READ TOC, sectors, from track 1
pk_read: db 0x28, 0, 0, 0, 0, 16, 0, 0, 1, 0, 0, 0          ; READ(10), sector 16
pk_play: db 0x45, 0, 0, 0, 0, 0, 0, 0x01, 0x77, 0, 0, 0     ; PLAY AUDIO(10), 375 sectors (5 s)

        times 3584 - ($ - $$) db 0
