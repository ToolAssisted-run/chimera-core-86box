; mbr.asm - the master boot record of the test scripts' hard disk image
; (make-hdd.py). 8088 code: it moves itself out of the way, finds the active
; partition in its table and starts that partition's boot sector, as the
; boot code of a DOS FDISK does. The BIOS hands over the drive in DL, and
; it is handed on unchanged.
	cpu	8086
	org	0x600
start:
	cli
	xor	ax, ax
	mov	ss, ax
	mov	sp, 0x7c00
	mov	ds, ax
	mov	es, ax
	sti
	cld
	mov	si, 0x7c00
	mov	di, 0x600
	mov	cx, 256
	rep	movsw
	jmp	0:moved
moved:
	mov	si, table
	mov	cx, 4
.find:	cmp	byte [si], 0x80
	je	.found
	add	si, 16
	loop	.find
	mov	si, msg_none
	jmp	fail
.found:	mov	di, 5			; tries
.read:	mov	bx, 0x7c00
	mov	dh, [si + 1]		; head
	mov	cx, [si + 2]		; sector, cylinder
	mov	ax, 0x0201
	push	di
	int	0x13
	pop	di
	jnc	.read_ok
	xor	ax, ax
	int	0x13
	dec	di
	jnz	.read
	mov	si, msg_read
	jmp	fail
.read_ok:
	cmp	word [0x7dfe], 0xaa55
	je	.go
	mov	si, msg_sign
	jmp	fail
.go:	jmp	0:0x7c00		; DS:SI is the partition's entry
fail:	lodsb
	or	al, al
	jz	.stop
	mov	ah, 0x0e
	mov	bx, 7
	int	0x10
	jmp	fail
.stop:	int	0x18
	jmp	.stop

msg_none:	db	"No active partition", 0
msg_read:	db	"Cannot read the boot sector", 0
msg_sign:	db	"The boot sector has no signature", 0

	times	0x1be - ($ - $$) db 0
table:	times	64 db 0
	dw	0xaa55
