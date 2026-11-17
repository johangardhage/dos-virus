#!/usr/bin/env bash
#
# run-tests.sh — test harness for the virus demos (virus01 .. virus10).
#
# Usage:
#   tools/run-tests.sh                 # build-check all demos + run every behavioral test
#   tools/run-tests.sh virus01 ...     # only the named demos
#   tools/run-tests.sh path/to/x.asm   # an arbitrary source (profiled by basename if known)
#   tools/run-tests.sh --dosbox [...]  # run behavioral tests on DOSBox instead of QEMU
#                                      # (faster, but DOSBox's built-in DOS is not a real
#                                      # INT 21h chain, so the tunneler demos can't run)
#
# Every demo is BUILD-checked (assemble + link to a COM dropper). Demos that
# have a behavioral test are additionally exercised on the real MS-DOS kernel
# booted under QEMU (the default runner). Resident / EXE / MBR behavioral tests
# are filled in demo by demo; until then those demos are build-checked only.
#
# Safety: a virus only ever runs on a disposable mktemp drive containing nothing
# but the test files. The DOS tools drive (TASM) is mounted ONLY while
# assembling, never while a virus executes, so a virus can never reach real
# files. The MBR demo (virus10) is destructive and will be run only against a
# throwaway disk image, never real media.
#
# Behavioral tests run by default on the real MS-DOS kernel booted from DOS_IMAGE
# under QEMU -- authentic, and fully boxed in a throwaway disk image with no host
# filesystem access. --dosbox instead runs them on a live-mounted DOSBox drive
# (faster to boot, but DOSBox's built-in DOS is not a real INT 21h chain, so the
# INT 01h tunneler demos -- virus06-09 -- are build-checked only there). Builds
# always use DOSBox+TASM.
#
# Env: DOS_TOOLS_DRIVE (default ~/DOSBox, must hold TASM\BIN), DOSBOX (default
# dosbox-staging); QEMU (default qemu-system-i386), DOS_IMAGE (default
# $DOS_TOOLS_DRIVE/MSDOS.IMG), QEMU_BOOT_TIMEOUT (default 40s). Needs mtools.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOS_TOOLS_DRIVE="${DOS_TOOLS_DRIVE:-$HOME/DOSBox}"
DOSBOX="${DOSBOX:-dosbox-staging}"
RUNNER="${RUNNER:-qemu}"              # qemu (default) | dosbox  (--dosbox opts out)
QEMU="${QEMU:-qemu-system-i386}"
DOS_IMAGE="${DOS_IMAGE:-$DOS_TOOLS_DRIVE/MSDOS.IMG}"   # bootable MS-DOS image for --qemu
QEMU_BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-40}"
IMG_OFF=0                             # first-partition byte offset (set in the qemu pre-flight)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/virustest.XXXXXX")"
LOG="$WORK/dosbox.log"
trap 'rm -rf "$WORK"' EXIT
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

ALL_DEMOS="virus01 virus02 virus03 virus04 virus05 virus06 virus07 virus08 virus09 virus10"

# profile: "<type> <resident> <infects-on> <test>"
#   type: com | exe | comexe | mbr      test: name of test_ impl, or "-" (build-check only)
demo_profile() {
	case "$1" in
	virus01) echo "com    no  tree-scan      virus01" ;;
	virus02) echo "exe    no  parent-scan    virus02" ;;
	virus03) echo "com    yes execute        virus03" ;;
	virus04) echo "exe    yes execute        virus04" ;;
	virus05) echo "comexe yes execute        virus05" ;;
	virus06) echo "com    yes execute,findfirst virus06" ;;
	virus07) echo "comexe yes execute        virus07"   ;;
	virus08) echo "com    yes execute,close   virus08"  ;;
	virus09) echo "com    yes execute,close   virus09"  ;;
	virus10) echo "mbr    no  mbr-overwrite   virus10"  ;;
	*)       echo "?      ?   ?               -"       ;;
	esac
}

# ---- small helpers ---------------------------------------------------------

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m'  "$1"; }

fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }
bytehex() { xxd -s"$2" -l"${3:-1}" -p "$1" 2>/dev/null; }   # bytehex <file> <offset> [len]

TIMEOUT=""
if   command -v timeout  >/dev/null 2>&1; then TIMEOUT="timeout 90"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 90"
fi

dbox() { # run DOSBox head-less with the given shell commands, then exit
	local cargs=() c
	for c in "$@"; do cargs+=(-c "$c"); done
	$TIMEOUT "$DOSBOX" --noprimaryconf "${cargs[@]}" >>"$LOG" 2>&1
}

# run_in <dir> <dos-command>...
# Run the DOS commands with <dir> as the C: drive; results are left in <dir>.
# Backend is $RUNNER: "dosbox" mounts <dir> live; "qemu" boots the real MS-DOS
# kernel (DOS_IMAGE) with <dir>'s files injected, then reads the results back.
run_in() {
	local dir="$1"; shift
	if [ "$RUNNER" = qemu ]; then
		qemu_run "$dir" "$@"
	else
		local cargs=("mount c $dir" "c:") c
		for c in "$@"; do cargs+=("$c"); done
		cargs+=("exit")
		dbox "${cargs[@]}"
	fi
}

# qemu_run <dir> <dos-command>...
# Boot DOS_IMAGE under QEMU on a throwaway copy, with <dir>'s files injected onto
# C:\ and an AUTOEXEC.BAT that runs the commands then writes C:\QDONE.TXT.
# The booted guest has no host filesystem access, so the virus is fully boxed
# in the disposable image. Results (grown/created files) are copied back to <dir>.
# Host-side FAT access uses mtools (fast, no DOSBox launch); IMG_OFF is the first
# partition's byte offset, computed once in the pre-flight below.
qemu_run() {
	local dir="$1"; shift
	local sess="$WORK/session.img" c
	cp "$DOS_IMAGE" "$sess"
	{ printf '@ECHO OFF\r\nC:\r\nCD \\\r\n'
	  for c in "$@"; do printf '%s\r\n' "$c"; done
	  printf 'ECHO DONE>C:\\QDONE.TXT\r\n'
	} > "$dir/AUTOEXEC.BAT"
	# inject <dir>'s files onto C:\ with mtools (no DOSBox, no boot)
	mcopy -i "$sess@@$IMG_OFF" -mo "$dir"/* ::/ 2>/dev/null   # -m: keep mtimes (timestamp infection marks)
	# boot the real kernel under QEMU; poll the image for the completion marker
	"$QEMU" -machine pc -m 16 -drive file="$sess",format=raw,if=ide,cache=writethrough \
		-display none -nodefaults -boot c >>"$LOG" 2>&1 &
	local qp=$! i n=$((QEMU_BOOT_TIMEOUT * 10))
	for ((i = 0; i < n; i++)); do
		mdir -i "$sess@@$IMG_OFF" ::/QDONE.TXT >/dev/null 2>&1 && break
		sleep 0.1
	done
	# marker seen => all prior writes are already flushed (cache=writethrough),
	# so a hard kill is safe and avoids a graceful-shutdown wait.
	kill -9 "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
	# copy the test files/outputs in C:\ back into <dir> so the caller sees the
	# results; skip the boot/system files and the completion marker (re-injecting
	# those would clobber the boot image or make the next run's marker spuriously
	# appear before the guest has run).
	rm -rf "$WORK/_out"; mkdir -p "$WORK/_out"
	mcopy -i "$sess@@$IMG_OFF" -m "::/*" "$WORK/_out/" 2>/dev/null   # -m: keep mtimes (timestamp infection marks)
	for c in "$WORK/_out"/*; do
		[ -f "$c" ] || continue
		case "$(basename "$c")" in
			IO.SYS|MSDOS.SYS|COMMAND.COM|DRVSPACE.BIN|DBLSPACE.BIN|WINA20.386|CONFIG.SYS|AUTOEXEC.BAT|QDONE.TXT) continue ;;
		esac
		cp -pf "$c" "$dir/"   # -p: keep mtime (timestamp infection marks survive the round-trip)
	done
	rm -f "$sess" "$dir/AUTOEXEC.BAT"
}

# qemu_boot <image> <marker>
# Boot <image> under QEMU and wait until the guest writes ::/<marker> into its
# FAT partition, then kill QEMU. Returns 0 if the marker appeared, 1 on timeout.
# Unlike qemu_run it injects/extracts nothing -- the caller sets up the image
# (used by the virus10 MBR test, which boots a disk it has already infected).
qemu_boot() {
	local img="$1" marker="$2" i
	"$QEMU" -machine pc -m 16 -drive file="$img",format=raw,if=ide,cache=writethrough \
		-display none -nodefaults -boot c >>"$LOG" 2>&1 &
	local qp=$! n=$((QEMU_BOOT_TIMEOUT * 10)) found=1
	for ((i = 0; i < n; i++)); do
		mdir -i "$img@@$IMG_OFF" "::/$marker" >/dev/null 2>&1 && { found=0; break; }
		sleep 0.1
	done
	kill -9 "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
	return "$found"
}

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(green PASS)" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(red FAIL)"  "$1"; }
note() { printf '  %s %s\n' "$(dim '····')" "$1"; }

# A tiny harmless COM that prints "<marker>$" then exits via INT 20h. The 3
# trailing INT 20h/NOP bytes are a trap: a correct infection jmp lands in the
# appended virus, so a jmp that lands in the host's own tail hits INT 20h and
# exits silently -- catching an entry-stub that let the restore clobber the body.
# Optional 3rd arg pads the file with trailing 0x90 (NOP) bytes to at least <min>
# bytes (some demos skip COM files smaller than VirusSize).
make_com_host() {
	printf '\xB4\x09\xBA\x09\x01\xCD\x21\xCD\x20%s$\xCD\x20\x90' "$2" > "$1"
	local min="${3:-0}" cur
	cur="$(fsize "$1")"
	if [ "$cur" -lt "$min" ]; then
		dd if=/dev/zero bs=1 count=$((min - cur)) 2>/dev/null | LC_ALL=C tr '\0' '\220' >> "$1"
	fi
	touch -t 202601010000.00 "$1"   # fixed mtime (seconds=00) so a random creation
}                                   # second never looks like a timestamp infection mark

# A minimal valid MZ .EXE (32-byte header + 20-byte code) that prints "<marker>$"
# then exits via 4C00h. The marker must be 5 chars so the 52-byte layout stays
# fixed. Optional 3rd arg pads the file with trailing 0x90 (NOP) bytes to
# <total_size> and updates e_cblp/e_cp accordingly. Checksum field (0x12) is 0.
make_exe_host() {
	local total="${3:-52}"
	local cblp=$((total % 512)) cp=$(((total + 511) / 512))
	printf '\x4D\x5A' > "$1"
	printf "\\x$(printf '%02x' $((cblp & 255)))\\x$(printf '%02x' $((cblp >> 8)))" >> "$1"
	printf "\\x$(printf '%02x' $((cp & 255)))\\x$(printf '%02x' $((cp >> 8)))" >> "$1"
	printf '\x00\x00\x02\x00\x10\x00\xFF\xFF\x40\x00\x00\x01\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x0E\x1F\xB4\x09\xBA\x0E\x00\xCD\x21\xB8\x00\x4C\xCD\x21%s$' "$2" >> "$1"
	if [ "$total" -gt 52 ]; then
		dd if=/dev/zero bs=1 count=$((total - 52)) 2>/dev/null | LC_ALL=C tr '\0' '\220' >> "$1"
	fi
	touch -t 202601010000.00 "$1"
}

# A 70-byte COM that writes 6 bytes to C:\PROBE.BIN: the current INT 21h vector
# (offset, segment) followed by the result of the virus resident-check (INT 21h
# with AX=7979h -> AX). Hand-assembled; equivalent to:
#   mov ax,3521h / int 21h / mov [Voff],bx / mov [Vseg],es   ; get INT 21h vector
#   mov ax,7979h / int 21h / mov [Rax],ax                    ; ask "are you resident?"
#   <create C:\PROBE.BIN, write the 6 bytes, close, exit 4C00h>
# Used to prove the tunneler installs UNDER the DOS entry: a vector hook changes
# the vector to the TSR; a tunnel leaves it pointing at DOS yet still intercepts.
make_probe() { printf '\xB8\x21\x35\xCD\x21\x89\x1E\x40\x01\x8C\x06\x42\x01\xB8\x79\x79\xCD\x21\xA3\x44\x01\xB4\x3C\x31\xC9\xBA\x33\x01\xCD\x21\x8B\xD8\xB4\x40\xB9\x06\x00\xBA\x40\x01\xCD\x21\xB4\x3E\xCD\x21\xB8\x00\x4C\xCD\x21\x43\x3A\x5C\x50\x52\x4F\x42\x45\x2E\x42\x49\x4E\x00\x00\x00\x00\x00\x00\x00' > "$1"; }

# A 22-byte COM that opens HOST.COM (INT 21h/3D00h) then exits via 4C00h WITHOUT
# closing. DOS auto-closes the handle on process exit, which bypasses a resident
# 3Eh close hook -- so a virus that disinfects on open and re-infects on close
# leaves the file DISINFECTED on disk. Used to observe virus08's open-stealth:
#   mov ax,3D00h / mov dx,fn / int 21h / mov ax,4C00h / int 21h / fn db "HOST.COM",0
make_opener() { printf '\xB8\x00\x3D\xBA\x0D\x01\xCD\x21\xB8\x00\x4C\xCD\x21HOST.COM\x00' > "$1"; }

# A 29-byte COM that opens HOST.COM via extended open (INT 21h/6C00h, DX=1) then
# exits via 4C00h WITHOUT closing, verifying virus08's 6C00h disinfection path:
#   mov ax,6C00h / xor bx,bx / xor cx,cx / mov dx,1 / mov si,fn / int 21h / exit
make_ext_opener() { printf '\xB8\x00\x6C\x31\xDB\x31\xC9\xBA\x01\x00\xBE\x14\x01\xCD\x21\xB8\x00\x4C\xCD\x21HOST.COM\x00' > "$1"; }

# A 51-byte COM that attempts to open missing "NOFILE.COM" (3D00h), then checks
# whether handle 2 (STDERR) is still open via IOCTL (4400h/BX=2) and prints
# "OK" or "BAD". Catches resident open hooks that omit `jc` after 3D00h and
# close handle 2 (DOS error code 2 = File Not Found).
make_open_missing() { printf '\xB8\x00\x3D\xBA\x21\x01\xCD\x21\xB8\x00\x44\xBB\x02\x00\xCD\x21\xBA\x2C\x01\x73\x03\xBA\x2F\x01\xB4\x09\xCD\x21\xB8\x00\x4C\xCD\x21NOFILE.COM\x00OK$BAD$' > "$1"; }

# A 75-byte COM that shrinks its MCB, attempts to EXEC missing "NOFILE.COM"
# (4B00h), then checks whether handle 2 (STDERR) is still open via IOCTL
# (4400h/BX=2) and prints "OK" or "BAD". Catches 4B00h hooks that omit `jc`
# after 3D00h/3D02h and close handle 2 (or hang reading from CON).
make_exec_missing() { printf '\xB4\x4A\xBB\x00\x01\xCD\x21\xB8\x00\x4B\xBA\x2B\x01\xBB\x3D\x01\xCD\x21\xB8\x00\x44\xBB\x02\x00\xCD\x21\xBA\x36\x01\x73\x03\xBA\x39\x01\xB4\x09\xCD\x21\xB8\x00\x4C\xCD\x21NOFILE.COM\x00OK$BAD$\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$1"; }

# A tiny COM that calls FindFirst (INT 21h/4Eh) on <target> and writes the 4-byte
# DTA filesize (PSP:009Ah) to STAT.BIN. Used to verify 4Eh filesize stealth.
make_stat4e() { printf '\xB4\x4E\x31\xC9\xBA\x32\x01\xCD\x21\x72\x19\xB4\x3C\x31\xC9\xBA\x29\x01\xCD\x21\x89\xC3\xB4\x40\xB9\x04\x00\xBA\x9A\x00\xCD\x21\xB4\x3E\xCD\x21\xB8\x00\x4C\xCD\x21STAT.BIN\x00%s\x00' "$2" > "$1"; }

# Read a 32-bit little-endian unsigned int from a 4-byte binary file
le32() {
	local h; h="$(bytehex "$1" 0 4 | tr -d '\n')"
	[ "${#h}" -eq 8 ] && echo $(( 16#${h:6:2}*16777216 + 16#${h:4:2}*65536 + 16#${h:2:2}*256 + 16#${h:0:2} )) || echo -1
}

# Extract the decimal size reported by MS-DOS DIR for "<stem> <ext>" (stripping commas)
dir_size() {
	grep -iE "^$2[[:space:]]+$3[[:space:]]+" "$1" 2>/dev/null | head -1 | awk '{gsub(/,/, "", $3); print $3}'
}

# Compute a clean EXE host size >= 52 such that (size + grow) is an exact multiple of 512
aligned_exe_size() {
	local s=$(( (512 - ($1 % 512)) % 512 ))
	[ "$s" -lt 52 ] && s=$((s + 512))
	echo "$s"
}

# Format a 16-bit integer as 4-char little-endian hex (for MZ header comparison)
le16hex() { printf '%02x%02x' $(($1 & 255)) $(($1 >> 8)); }

# ---- build -----------------------------------------------------------------

# build_virus <asm> <outdir>  -> leaves V.COM + V.LST in <outdir>; returns 1 on failure
build_virus() {
	local src="$1" out="$2"
	[ -f "$src" ] || return 1
	mkdir -p "$out"; cp "$src" "$out/V.ASM"
	dbox "mount c $DOS_TOOLS_DRIVE" "mount d $out" "path c:\\TASM\\BIN" "d:" \
	     "tasm /w1/m/t d:\\V.ASM d:\\V d:\\V" "tlink /t d:\\V,d:\\V" "exit"
	[ -f "$out/V.COM" ]
}

# sym_from_lst <lst> <symbol>  -> decimal offset of <symbol> in DGROUP/_TEXT, or -1
sym_from_lst() {
	local hex
	hex="$(grep -iE "^$2[[:space:]]" "$1" | grep -oiE "(DGROUP|_TEXT):[0-9A-Fa-f]+" | head -1 | sed 's/.*://')"
	[ -n "$hex" ] && echo $((16#$hex)) || echo -1
}

# VirusSize (bytes that infection appends) from the listing -- the COM file may
# be larger (e.g. a dropper carrying an entry stub before the virus body).
virussize_from_lst() {
	local hex; hex="$(grep -iE "VirusSize[[:space:]]+equ" "$1" | grep -oiE "=[0-9A-Fa-f]+" | head -1 | tr -d '=')"
	if [ -n "$hex" ]; then echo $((16#$hex)); return; fi
	# fall back to EndVirus-BeginVirus from the LST symbol offsets if VirusSize equ is absent.
	local ob oe
	ob="$(grep -iE "^BEGINVIRUS[[:space:]]" "$1" | grep -oiE "DGROUP:[0-9A-Fa-f]+" | head -1 | sed 's/.*://')"
	oe="$(grep -iE "^ENDVIRUS[[:space:]]"   "$1" | grep -oiE "DGROUP:[0-9A-Fa-f]+" | head -1 | sed 's/.*://')"
	{ [ -n "$ob" ] && [ -n "$oe" ]; } && echo $(( 16#$oe - 16#$ob )) || echo 0
}

# ---- behavioral tests (one function per demo; added demo by demo) ----------

# virus01: non-resident COM infector -- run dropper, confirm infected host runs,
# replicates gen1->gen2, self-recognises, and entry lands on the clean prologue.
test_virus01() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus01: could not read VirusSize"; return; }

	# T1 — an infected host still runs
	local S="$WORK/virus01/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK"
	local H0; H0="$(fsize "$S/HOST.COM")"
	run_in "$S" "V.COM" "HOST.COM > RESULT.TXT"
	local H1 OUT FB; H1="$(fsize "$S/HOST.COM")"
	OUT="$(tr -d '\r\n' < "$S/RESULT.TXT" 2>/dev/null)"; FB="$(bytehex "$S/HOST.COM" 0)"
	[ "$H1" = "$((H0+GROW))" ] && ok "T1 host grew by $GROW ($H0->$H1)"      || bad "T1 host $H0->$H1 (want +$GROW)"
	[ "$FB" = "e9" ]          && ok "T1 host entry patched to E9 jmp"         || bad "T1 first byte 0x$FB (want e9)"
	[ "$OUT" = "HOSTOK" ]     && ok "T1 infected host printed its payload"    || bad "T1 output '$OUT' (want HOSTOK)"
	local DISP ENTRY EB; DISP="$(bytehex "$S/HOST.COM" 1 2)"; DISP="${DISP:-0000}"
	ENTRY=$(( 3 + 16#${DISP:2:2}*256 + 16#${DISP:0:2} )); EB="$(bytehex "$S/HOST.COM" "$ENTRY")"
	[ "$EB" = "50" ]          && ok "T1 entry lands on clean push ax (off $ENTRY)" || bad "T1 entry byte 0x$EB at $ENTRY (want 50)"

	# T2 — a gen-1 infected host infects a fresh host
	S="$WORK/virus01/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA"
	run_in "$S" "V.COM"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC"; local C0; C0="$(fsize "$S/C.COM")"
	run_in "$S" "A.COM > OUTA.TXT"
	local C1 OUTA; C1="$(fsize "$S/C.COM")"; OUTA="$(tr -d '\r\n' < "$S/OUTA.TXT" 2>/dev/null)"
	[ "$OUTA" = "AAAAA" ]      && ok "T2 gen-1 host ran its payload"           || bad "T2 gen-1 output '$OUTA' (want AAAAA)"
	[ "$C1" = "$((C0+GROW))" ] && ok "T2 fresh host infected by gen-1 ($C0->$C1)" || bad "T2 fresh host $C0->$C1 (want +$GROW)"

	# T3 — an already-infected file is not infected twice
	S="$WORK/virus01/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/D.COM" "DDDDD"; local D0; D0="$(fsize "$S/D.COM")"
	run_in "$S" "V.COM"; local D1; D1="$(fsize "$S/D.COM")"
	run_in "$S" "V.COM"; local D2; D2="$(fsize "$S/D.COM")"
	[ "$D1" = "$((D0+GROW))" ] && ok "T3 infected once ($D0->$D1)"             || bad "T3 first run $D1 (want $((D0+GROW)))"
	[ "$D2" = "$D1" ]          && ok "T3 second run did not re-infect ($D2)"    || bad "T3 re-infected $D1->$D2"

	# T4 — COM max-size guard: a COM too large to stay under 64 KB is skipped
	S="$WORK/virus01/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; local B0=$((65535 - GROW + 32))
	make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT"
	local B1 BOUT; B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	[ "$B1" = "$B0" ]       && ok "T4 oversized COM skipped ($B0 bytes)"        || bad "T4 oversized COM grew ($B0->$B1)"
	[ "$BOUT" = "BIGOK" ]   && ok "T4 oversized COM still runs cleanly"         || bad "T4 oversized COM output '$BOUT' (want BIGOK)"

	# T5 — subdirectory traversal: infects COM files inside subdirectories
	S="$WORK/virus01/t5"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/DEEP.COM" "DEEPOK"; local P0; P0="$(fsize "$S/DEEP.COM")"
	run_in "$S" "MD SUB" "COPY DEEP.COM SUB\\DEEP.COM >NUL" "DEL DEEP.COM" "V.COM" "SUB\\DEEP.COM > OUTP.TXT" "COPY SUB\\DEEP.COM AFTER.COM >NUL"
	local P1 POUT; P1="$(fsize "$S/AFTER.COM" 2>/dev/null || echo 0)"; POUT="$(tr -d '\r\n' < "$S/OUTP.TXT" 2>/dev/null)"
	[ "$P1" = "$((P0+GROW))" ] && ok "T5 subdirectory COM infected ($P0->$P1)"  || bad "T5 subdirectory COM $P0->$P1 (want +$GROW)"
	[ "$POUT" = "DEEPOK" ]     && ok "T5 infected subdirectory COM ran payload" || bad "T5 subdirectory COM output '$POUT' (want DEEPOK)"
}

# virus02: non-resident EXE infector -- appends the virus, repoints CS:IP/SS:SP,
# and marks the EXE checksum field (0x12) with 'JG'. Run dropper, confirm the
# infected EXE still runs, replicates, and self-recognises.
test_virus02() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus02: could not read VirusSize"; return; }

	local S="$WORK/virus02/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exe_host "$S/HOST.EXE" "EXEOK"
	run_in "$S" "HOST.EXE > C.TXT"   # control: host must run before infection
	[ "$(tr -d '\r\n' < "$S/C.TXT" 2>/dev/null)" = "EXEOK" ] \
		&& ok "control uninfected EXE runs" || { bad "control EXE does not run (bad test host)"; return; }

	local H0; H0="$(fsize "$S/HOST.EXE")"
	run_in "$S" "V.COM" "HOST.EXE > R.TXT"
	local H1 OUT CS; H1="$(fsize "$S/HOST.EXE")"
	OUT="$(tr -d '\r\n' < "$S/R.TXT" 2>/dev/null)"; CS="$(bytehex "$S/HOST.EXE" 18 2)"
	[ "$H1" = "$((H0+GROW))" ] && ok "T1 EXE grew by $GROW ($H0->$H1)"  || bad "T1 EXE $H0->$H1 (want +$GROW)"
	[ "$CS" = "474a" ]         && ok "T1 checksum field marked 'JG'"    || bad "T1 checksum @0x12 0x$CS (want 474a='JG')"
	if [ "$OUT" = "EXEOK" ]; then
		ok "T1 infected EXE still runs its payload"
		S="$WORK/virus02/t2"; mkdir -p "$S"
		cp "$com" "$S/V.COM"; make_exe_host "$S/A.EXE" "AAAAA"
		run_in "$S" "V.COM"; rm -f "$S/V.COM"
		make_exe_host "$S/C.EXE" "CCCCC"; local C0; C0="$(fsize "$S/C.EXE")"
		run_in "$S" "A.EXE > OA.TXT"; local C1; C1="$(fsize "$S/C.EXE")"
		[ "$(tr -d '\r\n' < "$S/OA.TXT" 2>/dev/null)" = "AAAAA" ] && ok "T2 gen-1 EXE ran its payload" || bad "T2 gen-1 EXE output mismatch"
		[ "$C1" = "$((C0+GROW))" ] && ok "T2 fresh EXE infected by gen-1 ($C0->$C1)" || bad "T2 fresh EXE $C0->$C1 (want +$GROW)"
		S="$WORK/virus02/t3"; mkdir -p "$S"
		cp "$com" "$S/V.COM"; make_exe_host "$S/D.EXE" "DDDDD"; local D0; D0="$(fsize "$S/D.EXE")"
		run_in "$S" "V.COM"; local D1; D1="$(fsize "$S/D.EXE")"
		run_in "$S" "V.COM"; local D2; D2="$(fsize "$S/D.EXE")"
		[ "$D1" = "$((D0+GROW))" ] && ok "T3 infected once ($D0->$D1)" || bad "T3 first run $D1 (want $((D0+GROW)))"
		[ "$D2" = "$D1" ]          && ok "T3 no re-infection ($D2)"    || bad "T3 re-infected $D1->$D2"

		# T4 — read-only EXE: clears attribute before open, infects, and still runs
		S="$WORK/virus02/t4"; mkdir -p "$S"
		cp "$com" "$S/V.COM"; make_exe_host "$S/RO.EXE" "ROOKX"; local R0; R0="$(fsize "$S/RO.EXE")"
		run_in "$S" "ATTRIB +R RO.EXE" "V.COM" "RO.EXE > ROUT.TXT"
		local R1 ROUT; R1="$(fsize "$S/RO.EXE")"; ROUT="$(tr -d '\r\n' < "$S/ROUT.TXT" 2>/dev/null)"
		[ "$R1" = "$((R0+GROW))" ] && ok "T4 read-only EXE infected ($R0->$R1)" || bad "T4 read-only EXE $R0->$R1 (want +$GROW)"
		[ "$ROUT" = "ROOKX" ]      && ok "T4 infected read-only EXE ran"       || bad "T4 read-only EXE output '$ROUT' (want ROOKX)"

		# T5 — exact 512-byte multiple: e_cblp=0 and e_cp=filesize/512 (not +1)
		S="$WORK/virus02/t5"; mkdir -p "$S"
		local A0; A0="$(aligned_exe_size "$GROW")"
		cp "$com" "$S/V.COM"; make_exe_host "$S/ALN.EXE" "ALNOK" "$A0"
		run_in "$S" "V.COM" "ALN.EXE > AOUT.TXT"
		local A1 CBLP CP EXP_CP; A1="$(fsize "$S/ALN.EXE")"
		CBLP="$(bytehex "$S/ALN.EXE" 2 2)"; CP="$(bytehex "$S/ALN.EXE" 4 2)"
		EXP_CP="$(le16hex $((A1 / 512)))"
		[ "$A1" = "$((A0+GROW))" ] && [ "$CBLP" = "0000" ] && [ "$CP" = "$EXP_CP" ] \
			&& ok "T5 exact 512-byte multiple page count (cblp=0000 cp=$CP)" \
			|| bad "T5 exact 512-byte multiple header cblp=$CBLP cp=$CP (want 0000/$EXP_CP for $A1 bytes)"

		# T6 — parent-directory traversal: running in SUB infects PARENT.EXE in root and restores CWD
		S="$WORK/virus02/t6"; mkdir -p "$S"
		cp "$com" "$S/V.COM"; make_exe_host "$S/PARENT.EXE" "PAROK"; local P0; P0="$(fsize "$S/PARENT.EXE")"
		run_in "$S" "MD SUB" "COPY V.COM SUB\\V.COM >NUL" "DEL V.COM" "CD SUB" "V.COM" "CD > \\CWD.TXT" "CD \\" "PARENT.EXE > POUT.TXT"
		local P1 POUT CWD; P1="$(fsize "$S/PARENT.EXE")"
		POUT="$(tr -d '\r\n' < "$S/POUT.TXT" 2>/dev/null)"
		CWD="$(tr -d '\r\n' < "$S/CWD.TXT" 2>/dev/null)"
		[ "$P1" = "$((P0+GROW))" ] && ok "T6 parent-dir EXE infected ($P0->$P1)" || bad "T6 parent-dir EXE $P0->$P1 (want +$GROW)"
		[ "$POUT" = "PAROK" ]      && ok "T6 infected parent-dir EXE ran"       || bad "T6 parent-dir EXE output '$POUT' (want PAROK)"
		[ "$CWD" = 'C:\SUB' ]      && ok "T6 starting directory restored ($CWD)" || bad "T6 CWD '$CWD' (want C:\\SUB)"
	else
		bad "T1 infected EXE does not run (output '$OUT' -- hangs/crashes)"
		note "skipping replication/self-recognition (infected EXE is non-functional)"
	fi
}

# virus03: resident COM infector on execute (4B00h) -- goes TSR, hooks INT 21h,
# infects COM files (>= VirusSize) on execution, marks byte 3 with '@', and
# runs the infected host cleanly.
test_virus03() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus03: could not read VirusSize"; return; }
	local PAD=$((GROW + 64))

	# T1 — dropper goes resident, infects HOST.COM on execute, and infected HOST.COM still runs
	local S="$WORK/virus03/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK" "$PAD"
	local H0; H0="$(fsize "$S/HOST.COM")"
	run_in "$S" "V.COM" "HOST.COM > R1.TXT" "HOST.COM > R2.TXT"
	local H1 OUT1 OUT2 FB MARK; H1="$(fsize "$S/HOST.COM")"
	OUT1="$(tr -d '\r\n' < "$S/R1.TXT" 2>/dev/null)"
	OUT2="$(tr -d '\r\n' < "$S/R2.TXT" 2>/dev/null)"
	FB="$(bytehex "$S/HOST.COM" 0)"; MARK="$(bytehex "$S/HOST.COM" 3)"
	[ "$H1" = "$((H0+GROW))" ] && ok "T1 host grew by $GROW on execute ($H0->$H1)" || bad "T1 host $H0->$H1 (want +$GROW)"
	[ "$FB" = "e9" ]          && ok "T1 host entry patched to E9 jmp"              || bad "T1 first byte 0x$FB (want e9)"
	[ "$MARK" = "40" ]        && ok "T1 infection marker '@' at byte 3"            || bad "T1 byte 3 0x$MARK (want 40='@')"
	[ "$OUT1" = "HOSTOK" ]    && ok "T1 host printed payload during infection run" || bad "T1 run-1 output '$OUT1' (want HOSTOK)"
	[ "$OUT2" = "HOSTOK" ]    && ok "T1 infected host printed payload on 2nd run"  || bad "T1 run-2 output '$OUT2' (want HOSTOK)"

	# T2 — in a fresh boot (not yet resident), gen-1 infected A.COM goes resident and infects C.COM on execute
	S="$WORK/virus03/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA" "$PAD"
	run_in "$S" "V.COM" "A.COM > NUL"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC" "$PAD"; local C0; C0="$(fsize "$S/C.COM")"
	run_in "$S" "A.COM > OUTA.TXT" "C.COM > OUTC.TXT"
	local C1 OUTA OUTC; C1="$(fsize "$S/C.COM")"
	OUTA="$(tr -d '\r\n' < "$S/OUTA.TXT" 2>/dev/null)"
	OUTC="$(tr -d '\r\n' < "$S/OUTC.TXT" 2>/dev/null)"
	[ "$OUTA" = "AAAAA" ]      && ok "T2 gen-1 host ran its payload in fresh boot" || bad "T2 gen-1 output '$OUTA' (want AAAAA)"
	[ "$C1" = "$((C0+GROW))" ] && ok "T2 fresh host infected by gen-1 TSR ($C0->$C1)" || bad "T2 fresh host $C0->$C1 (want +$GROW)"
	[ "$OUTC" = "CCCCC" ]      && ok "T2 newly infected host ran its payload"      || bad "T2 C.COM output '$OUTC' (want CCCCC)"

	# T3 — executing an already-infected file again does not re-infect it
	S="$WORK/virus03/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/D.COM" "DDDDD" "$PAD"; local D0; D0="$(fsize "$S/D.COM")"
	run_in "$S" "V.COM" "D.COM > NUL"; local D1; D1="$(fsize "$S/D.COM")"
	run_in "$S" "V.COM" "D.COM > NUL"; local D2; D2="$(fsize "$S/D.COM")"
	[ "$D1" = "$((D0+GROW))" ] && ok "T3 infected once ($D0->$D1)"                || bad "T3 first run $D1 (want $((D0+GROW)))"
	[ "$D2" = "$D1" ]          && ok "T3 second run did not re-infect ($D2)"       || bad "T3 re-infected $D1->$D2"

	# T4 — failed open on missing 4B00h exec must not close STDERR (handle 2)
	S="$WORK/virus03/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exec_missing "$S/CHKEXEC.COM"
	run_in "$S" "V.COM" "CHKEXEC.COM > CHK.TXT"
	local CHK; CHK="$(tr -d '\r\n' < "$S/CHK.TXT" 2>/dev/null)"
	[ "$CHK" = "OK" ] && ok "T4 missing-file exec preserves STDERR handle"         || bad "T4 missing-file exec result '$CHK' (want OK)"

	# T5 — COM max-size guard: oversized COM is skipped on execute
	S="$WORK/virus03/t5"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; local B0=$((65535 - GROW + 32))
	make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT"
	local B1 BOUT; B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	[ "$B1" = "$B0" ]     && ok "T5 oversized COM skipped ($B0 bytes)"             || bad "T5 oversized COM grew ($B0->$B1)"
	[ "$BOUT" = "BIGOK" ] && ok "T5 oversized COM still runs cleanly"              || bad "T5 oversized COM output '$BOUT' (want BIGOK)"
}

# virus04: resident EXE infector on execute (4B00h) -- goes TSR, hooks INT 21h,
# infects EXE files on execution, marks EXE checksum field (0x12) with 'JG', and
# runs the infected EXE cleanly.
test_virus04() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus04: could not read VirusSize"; return; }

	# T1 — dropper goes resident, infects HOST.EXE on execute, and infected HOST.EXE still runs
	local S="$WORK/virus04/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exe_host "$S/HOST.EXE" "EXEOK"
	local H0; H0="$(fsize "$S/HOST.EXE")"
	run_in "$S" "V.COM" "HOST.EXE > R1.TXT" "HOST.EXE > R2.TXT"
	local H1 OUT1 OUT2 CS; H1="$(fsize "$S/HOST.EXE")"
	OUT1="$(tr -d '\r\n' < "$S/R1.TXT" 2>/dev/null)"
	OUT2="$(tr -d '\r\n' < "$S/R2.TXT" 2>/dev/null)"
	CS="$(bytehex "$S/HOST.EXE" 18 2)"
	[ "$H1" = "$((H0+GROW))" ] && ok "T1 EXE grew by $GROW on execute ($H0->$H1)"  || bad "T1 EXE $H0->$H1 (want +$GROW)"
	[ "$CS" = "474a" ]         && ok "T1 checksum field marked 'JG'"               || bad "T1 checksum @0x12 0x$CS (want 474a='JG')"
	[ "$OUT1" = "EXEOK" ]      && ok "T1 EXE printed payload during infection run" || bad "T1 run-1 output '$OUT1' (want EXEOK)"
	[ "$OUT2" = "EXEOK" ]      && ok "T1 infected EXE printed payload on 2nd run"  || bad "T1 run-2 output '$OUT2' (want EXEOK)"

	# T2 — in a fresh boot (not yet resident), gen-1 infected A.EXE goes resident and infects C.EXE on execute
	S="$WORK/virus04/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exe_host "$S/A.EXE" "AAAAA"
	run_in "$S" "V.COM" "A.EXE > NUL"; rm -f "$S/V.COM"
	make_exe_host "$S/C.EXE" "CCCCC"; local C0; C0="$(fsize "$S/C.EXE")"
	run_in "$S" "A.EXE > OUTA.TXT" "C.EXE > OUTC.TXT"
	local C1 OUTA OUTC; C1="$(fsize "$S/C.EXE")"
	OUTA="$(tr -d '\r\n' < "$S/OUTA.TXT" 2>/dev/null)"
	OUTC="$(tr -d '\r\n' < "$S/OUTC.TXT" 2>/dev/null)"
	[ "$OUTA" = "AAAAA" ]      && ok "T2 gen-1 EXE ran its payload in fresh boot"  || bad "T2 gen-1 output '$OUTA' (want AAAAA)"
	[ "$C1" = "$((C0+GROW))" ] && ok "T2 fresh EXE infected by gen-1 TSR ($C0->$C1)" || bad "T2 fresh EXE $C0->$C1 (want +$GROW)"
	[ "$OUTC" = "CCCCC" ]      && ok "T2 newly infected EXE ran its payload"       || bad "T2 C.EXE output '$OUTC' (want CCCCC)"

	# T3 — executing an already-infected EXE again does not re-infect it
	S="$WORK/virus04/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exe_host "$S/D.EXE" "DDDDD"; local D0; D0="$(fsize "$S/D.EXE")"
	run_in "$S" "V.COM" "D.EXE > NUL"; local D1; D1="$(fsize "$S/D.EXE")"
	run_in "$S" "V.COM" "D.EXE > NUL"; local D2; D2="$(fsize "$S/D.EXE")"
	[ "$D1" = "$((D0+GROW))" ] && ok "T3 infected once ($D0->$D1)"                 || bad "T3 first run $D1 (want $((D0+GROW)))"
	[ "$D2" = "$D1" ]          && ok "T3 second run did not re-infect ($D2)"        || bad "T3 re-infected $D1->$D2"

	# T4 — failed open on missing 4B00h exec must not close STDERR (handle 2)
	S="$WORK/virus04/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exec_missing "$S/CHKEXEC.COM"
	run_in "$S" "V.COM" "CHKEXEC.COM > CHK.TXT"
	local CHK; CHK="$(tr -d '\r\n' < "$S/CHK.TXT" 2>/dev/null)"
	[ "$CHK" = "OK" ] && ok "T4 missing-file exec preserves STDERR handle"          || bad "T4 missing-file exec result '$CHK' (want OK)"

	# T5 — exact 512-byte multiple: e_cblp=0 and e_cp=filesize/512 (not +1)
	S="$WORK/virus04/t5"; mkdir -p "$S"
	local A0; A0="$(aligned_exe_size "$GROW")"
	cp "$com" "$S/V.COM"; make_exe_host "$S/ALN.EXE" "ALNOK" "$A0"
	run_in "$S" "V.COM" "ALN.EXE > AOUT.TXT"
	local A1 CBLP CP EXP_CP; A1="$(fsize "$S/ALN.EXE")"
	CBLP="$(bytehex "$S/ALN.EXE" 2 2)"; CP="$(bytehex "$S/ALN.EXE" 4 2)"
	EXP_CP="$(le16hex $((A1 / 512)))"
	[ "$A1" = "$((A0+GROW))" ] && [ "$CBLP" = "0000" ] && [ "$CP" = "$EXP_CP" ] \
		&& ok "T5 exact 512-byte multiple page count (cblp=0000 cp=$CP)" \
		|| bad "T5 exact 512-byte multiple header cblp=$CBLP cp=$CP (want 0000/$EXP_CP for $A1 bytes)"
}

# virus05: resident COM+EXE infector on execute (4B00h) -- goes TSR, hooks INT 21h,
# infects both COM and EXE files on execution, marks EXE checksum field (0x12) with 'JG',
# and runs infected COM and EXE hosts cleanly.
test_virus05() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus05: could not read VirusSize"; return; }

	# T1 — dropper goes resident, infects both HOST.COM and HOST.EXE on execute, and both still run
	local S="$WORK/virus05/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"
	make_com_host "$S/HOST.COM" "COMOK"; local C0; C0="$(fsize "$S/HOST.COM")"
	make_exe_host "$S/HOST.EXE" "EXEOK"; local E0; E0="$(fsize "$S/HOST.EXE")"
	run_in "$S" "V.COM" "HOST.COM > C1.TXT" "HOST.COM > C2.TXT" "HOST.EXE > E1.TXT" "HOST.EXE > E2.TXT"
	local C1 E1 COUT1 COUT2 EOUT1 EOUT2 FB CS
	C1="$(fsize "$S/HOST.COM")"; E1="$(fsize "$S/HOST.EXE")"
	COUT1="$(tr -d '\r\n' < "$S/C1.TXT" 2>/dev/null)"; COUT2="$(tr -d '\r\n' < "$S/C2.TXT" 2>/dev/null)"
	EOUT1="$(tr -d '\r\n' < "$S/E1.TXT" 2>/dev/null)"; EOUT2="$(tr -d '\r\n' < "$S/E2.TXT" 2>/dev/null)"
	FB="$(bytehex "$S/HOST.COM" 0)"; CS="$(bytehex "$S/HOST.EXE" 18 2)"
	[ "$C1" = "$((C0+GROW))" ] && ok "T1 COM grew by $GROW on execute ($C0->$C1)"  || bad "T1 COM $C0->$C1 (want +$GROW)"
	[ "$FB" = "e9" ]           && ok "T1 COM entry patched to E9 jmp"              || bad "T1 COM first byte 0x$FB (want e9)"
	[ "$COUT1" = "COMOK" ]     && ok "T1 COM printed payload during infection run" || bad "T1 COM run-1 '$COUT1' (want COMOK)"
	[ "$COUT2" = "COMOK" ]     && ok "T1 infected COM printed payload on 2nd run"  || bad "T1 COM run-2 '$COUT2' (want COMOK)"
	[ "$E1" = "$((E0+GROW))" ] && ok "T1 EXE grew by $GROW on execute ($E0->$E1)"  || bad "T1 EXE $E0->$E1 (want +$GROW)"
	[ "$CS" = "474a" ]         && ok "T1 EXE checksum field marked 'JG'"           || bad "T1 EXE checksum @0x12 0x$CS (want 474a='JG')"
	[ "$EOUT1" = "EXEOK" ]     && ok "T1 EXE printed payload during infection run" || bad "T1 EXE run-1 '$EOUT1' (want EXEOK)"
	[ "$EOUT2" = "EXEOK" ]     && ok "T1 infected EXE printed payload on 2nd run"  || bad "T1 EXE run-2 '$EOUT2' (want EXEOK)"

	# T2 — in a fresh boot, gen-1 infected A.COM goes resident and infects both C.COM and C.EXE
	S="$WORK/virus05/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA"
	run_in "$S" "V.COM" "A.COM > NUL"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC"; local CC0; CC0="$(fsize "$S/C.COM")"
	make_exe_host "$S/C.EXE" "EEEEE"; local CE0; CE0="$(fsize "$S/C.EXE")"
	run_in "$S" "A.COM > OA.TXT" "C.COM > OC.TXT" "C.EXE > OE.TXT"
	local CC1 CE1; CC1="$(fsize "$S/C.COM")"; CE1="$(fsize "$S/C.EXE")"
	[ "$(tr -d '\r\n' < "$S/OA.TXT" 2>/dev/null)" = "AAAAA" ] && ok "T2 gen-1 COM ran its payload in fresh boot" || bad "T2 gen-1 COM output mismatch"
	[ "$CC1" = "$((CC0+GROW))" ] && ok "T2 fresh COM infected by gen-1 TSR ($CC0->$CC1)" || bad "T2 fresh COM $CC0->$CC1 (want +$GROW)"
	[ "$CE1" = "$((CE0+GROW))" ] && ok "T2 fresh EXE infected by gen-1 TSR ($CE0->$CE1)" || bad "T2 fresh EXE $CE0->$CE1 (want +$GROW)"

	# T3 — executing already-infected COM and EXE again does not re-infect them
	S="$WORK/virus05/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"
	make_com_host "$S/D.COM" "DDDDD"; local DC0; DC0="$(fsize "$S/D.COM")"
	make_exe_host "$S/D.EXE" "DDDDD"; local DE0; DE0="$(fsize "$S/D.EXE")"
	run_in "$S" "V.COM" "D.COM > NUL" "D.EXE > NUL"
	local DC1 DE1; DC1="$(fsize "$S/D.COM")"; DE1="$(fsize "$S/D.EXE")"
	run_in "$S" "V.COM" "D.COM > NUL" "D.EXE > NUL"
	local DC2 DE2; DC2="$(fsize "$S/D.COM")"; DE2="$(fsize "$S/D.EXE")"
	[ "$DC2" = "$DC1" ] && [ "$DC1" = "$((DC0+GROW))" ] && ok "T3 COM not re-infected ($DC0->$DC1->$DC2)" || bad "T3 COM $DC0->$DC1->$DC2"
	[ "$DE2" = "$DE1" ] && [ "$DE1" = "$((DE0+GROW))" ] && ok "T3 EXE not re-infected ($DE0->$DE1->$DE2)" || bad "T3 EXE $DE0->$DE1->$DE2"

	# T4 — failed open on missing 4B00h exec must not close STDERR (handle 2)
	S="$WORK/virus05/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exec_missing "$S/CHKEXEC.COM"
	run_in "$S" "V.COM" "CHKEXEC.COM > CHK.TXT"
	local CHK; CHK="$(tr -d '\r\n' < "$S/CHK.TXT" 2>/dev/null)"
	[ "$CHK" = "OK" ] && ok "T4 missing-file exec preserves STDERR handle"          || bad "T4 missing-file exec result '$CHK' (want OK)"

	# T5 — COM max-size guard + exact 512-byte multiple EXE page count
	S="$WORK/virus05/t5"; mkdir -p "$S"
	local B0=$((65535 - GROW + 32)) A0; A0="$(aligned_exe_size "$GROW")"
	cp "$com" "$S/V.COM"
	make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	make_exe_host "$S/ALN.EXE" "ALNOK" "$A0"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT" "ALN.EXE > AOUT.TXT"
	local B1 BOUT A1 CBLP CP EXP_CP
	B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	A1="$(fsize "$S/ALN.EXE")"; CBLP="$(bytehex "$S/ALN.EXE" 2 2)"; CP="$(bytehex "$S/ALN.EXE" 4 2)"
	EXP_CP="$(le16hex $((A1 / 512)))"
	[ "$B1" = "$B0" ] && [ "$BOUT" = "BIGOK" ] \
		&& ok "T5 oversized COM skipped and ran cleanly ($B0 bytes)" \
		|| bad "T5 oversized COM $B0->$B1 output '$BOUT'"
	[ "$A1" = "$((A0+GROW))" ] && [ "$CBLP" = "0000" ] && [ "$CP" = "$EXP_CP" ] \
		&& ok "T5 exact 512-byte multiple page count (cblp=0000 cp=$CP)" \
		|| bad "T5 exact 512-byte multiple header cblp=$CBLP cp=$CP (want 0000/$EXP_CP for $A1 bytes)"
}

# virus06: resident COM infector with INT 01h tunneling, execute (4B00h) + FCB
# findfirst/next (11h/12h) infection, and filesize stealth (11h/12h/4Eh/4Fh).
test_virus06() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus06: could not read VirusSize"; return; }
	# The INT 01h tunneler traces the live DOS INT 21h chain, which exists only
	# on the real MS-DOS kernel -- it cannot run on DOSBox's built-in DOS.
	if [ "$RUNNER" != qemu ]; then
		note "virus06: tunneling needs the real MS-DOS kernel -- drop --dosbox to run it"
		return
	fi

	# T1 — dropper goes resident, infects HOST.COM on execute, and infected HOST.COM still runs
	local S="$WORK/virus06/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK"
	local H0; H0="$(fsize "$S/HOST.COM")"
	run_in "$S" "V.COM" "HOST.COM > R1.TXT" "HOST.COM > R2.TXT"
	local H1 OUT1 OUT2 FB MARK; H1="$(fsize "$S/HOST.COM")"
	OUT1="$(tr -d '\r\n' < "$S/R1.TXT" 2>/dev/null)"
	OUT2="$(tr -d '\r\n' < "$S/R2.TXT" 2>/dev/null)"
	FB="$(bytehex "$S/HOST.COM" 0)"; MARK="$(bytehex "$S/HOST.COM" 3)"
	[ "$H1" = "$((H0+GROW))" ] && ok "T1 host grew by $GROW on execute ($H0->$H1)" || bad "T1 host $H0->$H1 (want +$GROW)"
	[ "$FB" = "e9" ]          && ok "T1 host entry patched to E9 jmp"              || bad "T1 first byte 0x$FB (want e9)"
	[ "$MARK" = "40" ]        && ok "T1 infection marker '@' at byte 3"            || bad "T1 byte 3 0x$MARK (want 40='@')"
	[ "$OUT1" = "HOSTOK" ]    && ok "T1 host printed payload during infection run" || bad "T1 run-1 output '$OUT1' (want HOSTOK)"
	[ "$OUT2" = "HOSTOK" ]    && ok "T1 infected host printed payload on 2nd run"  || bad "T1 run-2 output '$OUT2' (want HOSTOK)"

	# T2 — in a fresh boot, gen-1 infected A.COM goes resident and infects C.COM on execute
	S="$WORK/virus06/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA"
	run_in "$S" "V.COM" "A.COM > NUL"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC"; local C0; C0="$(fsize "$S/C.COM")"
	run_in "$S" "A.COM > OUTA.TXT" "C.COM > OUTC.TXT"
	local C1 OUTA OUTC; C1="$(fsize "$S/C.COM")"
	OUTA="$(tr -d '\r\n' < "$S/OUTA.TXT" 2>/dev/null)"
	OUTC="$(tr -d '\r\n' < "$S/OUTC.TXT" 2>/dev/null)"
	[ "$OUTA" = "AAAAA" ]      && ok "T2 gen-1 host ran its payload in fresh boot"  || bad "T2 gen-1 output '$OUTA' (want AAAAA)"
	[ "$C1" = "$((C0+GROW))" ] && ok "T2 fresh host infected by gen-1 TSR ($C0->$C1)" || bad "T2 fresh host $C0->$C1 (want +$GROW)"
	[ "$OUTC" = "CCCCC" ]      && ok "T2 newly infected host ran its payload"       || bad "T2 C.COM output '$OUTC' (want CCCCC)"

	# T3 — executing an already-infected file again does not re-infect it
	S="$WORK/virus06/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/D.COM" "DDDDD"; local D0; D0="$(fsize "$S/D.COM")"
	run_in "$S" "V.COM" "D.COM > NUL"; local D1; D1="$(fsize "$S/D.COM")"
	run_in "$S" "V.COM" "D.COM > NUL"; local D2; D2="$(fsize "$S/D.COM")"
	[ "$D1" = "$((D0+GROW))" ] && ok "T3 infected once ($D0->$D1)"                 || bad "T3 first run $D1 (want $((D0+GROW)))"
	[ "$D2" = "$D1" ]          && ok "T3 second run did not re-infect ($D2)"        || bad "T3 re-infected $D1->$D2"

	# T4 — installs via the TUNNEL, not a vector hook. Probe the INT 21h vector and
	# the resident-check before and after the dropper goes resident, in one boot.
	# A vector hook would repoint the vector at the TSR; the tunnel leaves it on the
	# DOS entry yet still intercepts (it patched an internal DOS far-pointer).
	S="$WORK/virus06/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_probe "$S/PROBE.COM"
	run_in "$S" "PROBE.COM" "COPY PROBE.BIN BEFORE.BIN >NUL" "V.COM" "PROBE.COM" "COPY PROBE.BIN AFTER.BIN >NUL"
	local BV AV BID AID
	BV="$(bytehex "$S/BEFORE.BIN" 0 4)"; AV="$(bytehex "$S/AFTER.BIN" 0 4)"   # INT 21h vector off+seg
	BID="$(bytehex "$S/BEFORE.BIN" 4 2)"; AID="$(bytehex "$S/AFTER.BIN" 4 2)" # 7979h -> AX ('JG'=474a LE)
	[ -n "$BID" ] && [ "$BID" != "474a" ]            && ok "T4 baseline clean: nobody answers 7979h (0x$BID)"       || bad "T4 baseline already intercepting (0x$BID)"
	[ "$AID" = "474a" ]                              && ok "T4 INT 21h intercepted after install (7979h->'JG')"     || bad "T4 not intercepting after install (0x$AID)"
	[ -n "$AV" ] && [ "$BV" = "$AV" ]                && ok "T4 INT 21h vector unchanged (0x$BV) => tunneled"        || bad "T4 vector changed 0x$BV->0x$AV (vector hook, not tunneled)"

	# T5 — failed open on missing 4B00h exec must not close STDERR (handle 2)
	S="$WORK/virus06/t5"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exec_missing "$S/CHKEXEC.COM"
	run_in "$S" "V.COM" "CHKEXEC.COM > CHK.TXT"
	local CHK; CHK="$(tr -d '\r\n' < "$S/CHK.TXT" 2>/dev/null)"
	[ "$CHK" = "OK" ] && ok "T5 missing-file exec preserves STDERR handle"          || bad "T5 missing-file exec result '$CHK' (want OK)"

	# T6 — COM max-size guard + FCB scan must skip non-COM entries (DIR *.TXT must not touch SAME.COM)
	S="$WORK/virus06/t6"; mkdir -p "$S"
	local B0=$((65535 - GROW + 32))
	cp "$com" "$S/V.COM"; make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	printf 'hello\r\n' > "$S/SAME.TXT"; touch -t 202601010000.00 "$S/SAME.TXT"
	make_com_host "$S/SAME.COM" "SAMEX"; local SM0; SM0="$(fsize "$S/SAME.COM")"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT" "DIR *.TXT > NUL"
	local B1 BOUT SM1; B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	SM1="$(fsize "$S/SAME.COM")"
	[ "$B1" = "$B0" ] && [ "$BOUT" = "BIGOK" ] \
		&& ok "T6 oversized COM skipped and ran cleanly ($B0 bytes)" \
		|| bad "T6 oversized COM $B0->$B1 output '$BOUT'"
	[ "$SM1" = "$SM0" ] \
		&& ok "T6 FCB DIR *.TXT ignored non-COM (SAME.COM untouched at $SM0)" \
		|| bad "T6 FCB DIR *.TXT wrongly infected SAME.COM ($SM0->$SM1)"

	# T7 — FCB DIR infection + directory filesize stealth (11h DIR and 4Eh FindFirst)
	S="$WORK/virus06/t7"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/DIRHOST.COM" "DIROK"; local DH0; DH0="$(fsize "$S/DIRHOST.COM")"
	make_com_host "$S/HOST.COM" "HOSTOK"; local SH0; SH0="$(fsize "$S/HOST.COM")"
	make_stat4e "$S/STAT4E.COM" "HOST.COM"
	run_in "$S" "V.COM" "DIR DIRHOST.COM > NUL" "HOST.COM > NUL" "DIR HOST.COM > DIR.TXT" "STAT4E.COM"
	local DH1 SH1 DSIZE S4E
	DH1="$(fsize "$S/DIRHOST.COM")"; SH1="$(fsize "$S/HOST.COM")"
	DSIZE="$(dir_size "$S/DIR.TXT" HOST COM)"; S4E="$(le32 "$S/STAT.BIN")"
	[ "$DH1" = "$((DH0+GROW))" ] && ok "T7 DIR infected unexecuted COM via FCB ($DH0->$DH1)" || bad "T7 DIRHOST.COM $DH0->$DH1 (want +$GROW)"
	[ "$SH1" = "$((SH0+GROW))" ] && [ "$DSIZE" = "$SH0" ] \
		&& ok "T7 FCB DIR stealths infected filesize ($SH1 on disk, DIR shows $DSIZE)" \
		|| bad "T7 FCB DIR showed '$DSIZE' (want $SH0; disk=$SH1)"
	[ "$SH1" = "$((SH0+GROW))" ] && [ "$S4E" = "$SH0" ] \
		&& ok "T7 4Eh FindFirst stealths infected filesize ($SH1 on disk, 4Eh shows $S4E)" \
		|| bad "T7 4Eh FindFirst showed '$S4E' (want $SH0; disk=$SH1)"
}

# virus07: resident COM/EXE infector with INT 01h tunneling, infects on execute
# (4B00h), filesize stealth (11h/12h/4Eh/4Fh), and deletes AV control files.
# Infection is recognised via the DOS timestamp (seconds field), so an infected
# EXE shows a rewritten header (entry CS @ 0x16 moved into the appended virus)
# rather than virus05's 'JG' checksum marker.
test_virus07() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus07: could not read VirusSize"; return; }
	# The INT 01h tunneler needs the real MS-DOS kernel (see virus06).
	if [ "$RUNNER" != qemu ]; then
		note "virus07: tunneling needs the real MS-DOS kernel -- drop --dosbox to run it"
		return
	fi

	# T1 — dropper goes resident, infects HOST.COM and HOST.EXE on execute, both still run
	local S="$WORK/virus07/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"
	make_com_host "$S/HOST.COM" "COMOK"; local C0; C0="$(fsize "$S/HOST.COM")"
	make_exe_host "$S/HOST.EXE" "EXEOK"; local E0; E0="$(fsize "$S/HOST.EXE")"
	run_in "$S" "V.COM" "HOST.COM > C1.TXT" "HOST.COM > C2.TXT" "HOST.EXE > E1.TXT" "HOST.EXE > E2.TXT"
	local C1 E1 COUT1 COUT2 EOUT1 EOUT2 FB ECS
	C1="$(fsize "$S/HOST.COM")"; E1="$(fsize "$S/HOST.EXE")"
	COUT1="$(tr -d '\r\n' < "$S/C1.TXT" 2>/dev/null)"; COUT2="$(tr -d '\r\n' < "$S/C2.TXT" 2>/dev/null)"
	EOUT1="$(tr -d '\r\n' < "$S/E1.TXT" 2>/dev/null)"; EOUT2="$(tr -d '\r\n' < "$S/E2.TXT" 2>/dev/null)"
	FB="$(bytehex "$S/HOST.COM" 0)"; ECS="$(bytehex "$S/HOST.EXE" 22 2)"   # e_cs @ 0x16
	[ "$C1" = "$((C0+GROW))" ] && ok "T1 COM grew by $GROW on execute ($C0->$C1)"      || bad "T1 COM $C0->$C1 (want +$GROW)"
	[ "$FB" = "e9" ]           && ok "T1 COM entry patched to E9 jmp"                  || bad "T1 COM first byte 0x$FB (want e9)"
	[ "$COUT1" = "COMOK" ]     && ok "T1 COM printed payload during infection run"     || bad "T1 COM run-1 '$COUT1' (want COMOK)"
	[ "$COUT2" = "COMOK" ]     && ok "T1 infected COM printed payload on 2nd run"      || bad "T1 COM run-2 '$COUT2' (want COMOK)"
	[ "$E1" = "$((E0+GROW))" ] && ok "T1 EXE grew by $GROW on execute ($E0->$E1)"      || bad "T1 EXE $E0->$E1 (want +$GROW)"
	[ -n "$ECS" ] && [ "$ECS" != "0000" ] && ok "T1 EXE entry CS rewritten to virus (0x$ECS)" || bad "T1 EXE entry CS @0x16 0x$ECS (want !=0000)"
	[ "$EOUT1" = "EXEOK" ]     && ok "T1 EXE printed payload during infection run"     || bad "T1 EXE run-1 '$EOUT1' (want EXEOK)"
	[ "$EOUT2" = "EXEOK" ]     && ok "T1 infected EXE printed payload on 2nd run"      || bad "T1 EXE run-2 '$EOUT2' (want EXEOK)"

	# T2 — fresh boot: gen-1 infected A.COM goes resident and infects fresh C.COM and C.EXE
	S="$WORK/virus07/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA"
	run_in "$S" "V.COM" "A.COM > NUL"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC"; local CC0; CC0="$(fsize "$S/C.COM")"
	make_exe_host "$S/C.EXE" "EEEEE"; local CE0; CE0="$(fsize "$S/C.EXE")"
	run_in "$S" "A.COM > OA.TXT" "C.COM > OC.TXT" "C.EXE > OE.TXT"
	local CC1 CE1; CC1="$(fsize "$S/C.COM")"; CE1="$(fsize "$S/C.EXE")"
	[ "$(tr -d '\r\n' < "$S/OA.TXT" 2>/dev/null)" = "AAAAA" ] && ok "T2 gen-1 COM ran its payload in fresh boot" || bad "T2 gen-1 COM output mismatch"
	[ "$CC1" = "$((CC0+GROW))" ] && ok "T2 fresh COM infected by gen-1 TSR ($CC0->$CC1)" || bad "T2 fresh COM $CC0->$CC1 (want +$GROW)"
	[ "$CE1" = "$((CE0+GROW))" ] && ok "T2 fresh EXE infected by gen-1 TSR ($CE0->$CE1)" || bad "T2 fresh EXE $CE0->$CE1 (want +$GROW)"

	# T3 — executing already-infected COM and EXE again does not re-infect them
	S="$WORK/virus07/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"
	make_com_host "$S/D.COM" "DDDDD"; local DC0; DC0="$(fsize "$S/D.COM")"
	make_exe_host "$S/D.EXE" "DDDDD"; local DE0; DE0="$(fsize "$S/D.EXE")"
	run_in "$S" "V.COM" "D.COM > NUL" "D.EXE > NUL"
	local DC1 DE1; DC1="$(fsize "$S/D.COM")"; DE1="$(fsize "$S/D.EXE")"
	run_in "$S" "V.COM" "D.COM > NUL" "D.EXE > NUL"
	local DC2 DE2; DC2="$(fsize "$S/D.COM")"; DE2="$(fsize "$S/D.EXE")"
	[ "$DC2" = "$DC1" ] && [ "$DC1" = "$((DC0+GROW))" ] && ok "T3 COM not re-infected ($DC0->$DC1->$DC2)" || bad "T3 COM $DC0->$DC1->$DC2"
	[ "$DE2" = "$DE1" ] && [ "$DE1" = "$((DE0+GROW))" ] && ok "T3 EXE not re-infected ($DE0->$DE1->$DE2)" || bad "T3 EXE $DE0->$DE1->$DE2"

	# T4 — installs via the TUNNEL, not a vector hook (see virus06 T4)
	S="$WORK/virus07/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_probe "$S/PROBE.COM"
	run_in "$S" "PROBE.COM" "COPY PROBE.BIN BEFORE.BIN >NUL" "V.COM" "PROBE.COM" "COPY PROBE.BIN AFTER.BIN >NUL"
	local BV AV BID AID
	BV="$(bytehex "$S/BEFORE.BIN" 0 4)"; AV="$(bytehex "$S/AFTER.BIN" 0 4)"
	BID="$(bytehex "$S/BEFORE.BIN" 4 2)"; AID="$(bytehex "$S/AFTER.BIN" 4 2)"
	[ -n "$BID" ] && [ "$BID" != "474a" ]            && ok "T4 baseline clean: nobody answers 7979h (0x$BID)"       || bad "T4 baseline already intercepting (0x$BID)"
	[ "$AID" = "474a" ]                              && ok "T4 INT 21h intercepted after install (7979h->'JG')"     || bad "T4 not intercepting after install (0x$AID)"
	[ -n "$AV" ] && [ "$BV" = "$AV" ]                && ok "T4 INT 21h vector unchanged (0x$BV) => tunneled"        || bad "T4 vector changed 0x$BV->0x$AV (vector hook, not tunneled)"

	# T5 — failed open on missing 4B00h exec must not hang or close STDERR
	S="$WORK/virus07/t5"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exec_missing "$S/CHKEXEC.COM"
	QEMU_BOOT_TIMEOUT=8 run_in "$S" "V.COM" "CHKEXEC.COM > CHK.TXT"
	local CHK; CHK="$(tr -d '\r\n' < "$S/CHK.TXT" 2>/dev/null)"
	[ "$CHK" = "OK" ] && ok "T5 missing-file exec returns cleanly with STDERR intact" || bad "T5 missing-file exec result '$CHK' (want OK; hung or closed handle)"

	# T6 — COM max-size guard + exact 512-byte multiple EXE page count
	S="$WORK/virus07/t6"; mkdir -p "$S"
	local B0=$((65535 - GROW + 32)) A0; A0="$(aligned_exe_size "$GROW")"
	cp "$com" "$S/V.COM"
	make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	make_exe_host "$S/ALN.EXE" "ALNOK" "$A0"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT" "ALN.EXE > AOUT.TXT"
	local B1 BOUT A1 CBLP CP EXP_CP
	B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	A1="$(fsize "$S/ALN.EXE")"; CBLP="$(bytehex "$S/ALN.EXE" 2 2)"; CP="$(bytehex "$S/ALN.EXE" 4 2)"
	EXP_CP="$(le16hex $((A1 / 512)))"
	[ "$B1" = "$B0" ] && [ "$BOUT" = "BIGOK" ] \
		&& ok "T6 oversized COM skipped and ran cleanly ($B0 bytes)" \
		|| bad "T6 oversized COM $B0->$B1 output '$BOUT'"
	[ "$A1" = "$((A0+GROW))" ] && [ "$CBLP" = "0000" ] && [ "$CP" = "$EXP_CP" ] \
		&& ok "T6 exact 512-byte multiple page count (cblp=0000 cp=$CP)" \
		|| bad "T6 exact 512-byte multiple header cblp=$CBLP cp=$CP (want 0000/$EXP_CP for $A1 bytes)"

	# T7 — AV control file deletion + directory filesize stealth (11h DIR and 4Eh)
	S="$WORK/virus07/t7"; mkdir -p "$S"
	cp "$com" "$S/V.COM"
	printf 'av1' > "$S/ANTI-VIR.DAT"; printf 'av2' > "$S/CHKLIST.MS"
	make_com_host "$S/HOST.COM" "COMOK"; local SC0; SC0="$(fsize "$S/HOST.COM")"
	make_exe_host "$S/HOST.EXE" "EXEOK"; local SE0; SE0="$(fsize "$S/HOST.EXE")"
	make_stat4e "$S/STATC.COM" "HOST.COM"; make_stat4e "$S/STATE.COM" "HOST.EXE"
	run_in "$S" "V.COM" \
		"IF EXIST ANTI-VIR.DAT ECHO EXISTS>AV1.TXT" \
		"IF EXIST CHKLIST.MS ECHO EXISTS>AV2.TXT" \
		"HOST.COM > NUL" "HOST.EXE > NUL" \
		"DIR HOST.* > DIR.TXT" \
		"STATC.COM" "COPY STAT.BIN SC.BIN >NUL" \
		"STATE.COM" "COPY STAT.BIN SE.BIN >NUL"
	local DC DE S4C S4E AV1 AV2
	DC="$(dir_size "$S/DIR.TXT" HOST COM)"; DE="$(dir_size "$S/DIR.TXT" HOST EXE)"
	S4C="$(le32 "$S/SC.BIN")"; S4E="$(le32 "$S/SE.BIN")"
	AV1="$(tr -d '\r\n' < "$S/AV1.TXT" 2>/dev/null)"; AV2="$(tr -d '\r\n' < "$S/AV2.TXT" 2>/dev/null)"
	[ "$AV1" != "EXISTS" ] && [ "$AV2" != "EXISTS" ] \
		&& ok "T7 AV control files deleted (ANTI-VIR.DAT, CHKLIST.MS)" \
		|| bad "T7 AV control files still present (AV1='$AV1' AV2='$AV2')"
	[ "$DC" = "$SC0" ] && [ "$DE" = "$SE0" ] \
		&& ok "T7 FCB DIR stealths COM ($DC) and EXE ($DE)" \
		|| bad "T7 FCB DIR showed COM='$DC' EXE='$DE' (want $SC0 / $SE0)"
	[ "$S4C" = "$SC0" ] && [ "$S4E" = "$SE0" ] \
		&& ok "T7 4Eh FindFirst stealths COM ($S4C) and EXE ($S4E)" \
		|| bad "T7 4Eh FindFirst showed COM='$S4C' EXE='$S4E' (want $SC0 / $SE0)"
}

# virus08: resident COM infector with INT 01h tunneling. Infects on execute
# (4B00h) AND close (3Eh), disinfects on open (3Dh/6C00h) for stealth, stealths
# filesize on dir funcs, hooks INT 24h. COM marker: E9 entry + '@' at byte 3.
# Skips files smaller than VirusSize-0x100, so hosts are padded to VirusSize.
test_virus08() {
	local com="$1" lst="$2"
	local GROW; GROW="$(virussize_from_lst "$lst")"
	[ "$GROW" -gt 0 ] || { bad "virus08: could not read VirusSize"; return; }
	# The INT 01h tunneler needs the real MS-DOS kernel (see virus06).
	if [ "$RUNNER" != qemu ]; then
		note "virus08: tunneling needs the real MS-DOS kernel -- drop --dosbox to run it"
		return
	fi
	local MIN="$GROW"   # host >= VirusSize, comfortably past the VirusSize-0x100 floor

	# T1 — dropper resident; HOST.COM infected on EXECUTE (E9 + '@'), still runs, not re-infected
	local S="$WORK/virus08/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK" "$MIN"; local H0; H0="$(fsize "$S/HOST.COM")"
	run_in "$S" "V.COM" "HOST.COM > R1.TXT" "HOST.COM > R2.TXT"
	local H1 FB MK O1 O2; H1="$(fsize "$S/HOST.COM")"
	FB="$(bytehex "$S/HOST.COM" 0)"; MK="$(bytehex "$S/HOST.COM" 3)"
	O1="$(tr -d '\r\n' < "$S/R1.TXT" 2>/dev/null)"; O2="$(tr -d '\r\n' < "$S/R2.TXT" 2>/dev/null)"
	[ "$H1" = "$((H0+GROW))" ] && ok "T1 host grew by $GROW on execute ($H0->$H1)"      || bad "T1 host $H0->$H1 (want +$GROW)"
	[ "$FB" = "e9" ]          && ok "T1 host entry patched to E9 jmp"                   || bad "T1 first byte 0x$FB (want e9)"
	[ "$MK" = "40" ]          && ok "T1 infection marker '@' at byte 3"                 || bad "T1 byte 3 0x$MK (want 40)"
	[ "$O1" = "HOSTOK" ]      && ok "T1 host printed payload during infection run"      || bad "T1 run-1 '$O1' (want HOSTOK)"
	[ "$O2" = "HOSTOK" ]      && ok "T1 infected host still runs, not re-infected ($H1)" || bad "T1 run-2 '$O2' (want HOSTOK)"

	# T2 — infect on CLOSE: copying a clean COM produces an infected copy
	S="$WORK/virus08/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/CLEAN.COM" "CLEANX" "$MIN"; local K0; K0="$(fsize "$S/CLEAN.COM")"
	run_in "$S" "V.COM" "COPY CLEAN.COM MADE.COM >NUL"
	local M1 MFB MMK; M1="$(fsize "$S/MADE.COM")"; MFB="$(bytehex "$S/MADE.COM" 0)"; MMK="$(bytehex "$S/MADE.COM" 3)"
	[ "$M1" = "$((K0+GROW))" ]            && ok "T2 copied COM infected on close ($K0->$M1)"  || bad "T2 MADE.COM $M1 (want $((K0+GROW)))"
	[ "$MFB" = "e9" ] && [ "$MMK" = "40" ] && ok "T2 close-infected copy has E9+'@' markers"   || bad "T2 MADE.COM markers 0x$MFB/0x$MMK (want e9/40)"

	# T3 — disinfect on OPEN: open an infected COM without closing (process exit auto-closes,
	# bypassing the 3Eh re-infect hook), leaving it clean on disk again without double-stealth
	S="$WORK/virus08/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK" "$MIN"; local D0; D0="$(fsize "$S/HOST.COM")"
	make_opener "$S/OPENER.COM"; make_stat4e "$S/STAT4E.COM" "HOST.COM"
	run_in "$S" "V.COM" "HOST.COM > NUL" "OPENER.COM" "DIR HOST.COM > DIR.TXT" "STAT4E.COM"
	local D1 DFB DDS DS4E; D1="$(fsize "$S/HOST.COM")"; DFB="$(bytehex "$S/HOST.COM" 0)"
	DDS="$(dir_size "$S/DIR.TXT" HOST COM)"; DS4E="$(le32 "$S/STAT.BIN")"
	[ "$D1" = "$D0" ] && [ "$DFB" != "e9" ] && ok "T3 infected COM disinfected on 3Dh open ($D0, first 0x$DFB)" || bad "T3 host $D1 first 0x$DFB (want clean $D0)"
	[ "$DDS" = "$D0" ] && [ "$DS4E" = "$D0" ] && ok "T3 disinfected COM not double-stealthed (DIR=$DDS, 4Eh=$DS4E)" || bad "T3 disinfected COM stealth mismatch (DIR='$DDS' 4Eh='$DS4E', want $D0)"

	# T3b — disinfect on EXTENDED OPEN (6C00h): same open-without-close via AX=6C00h/DX=1
	S="$WORK/virus08/t3b"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK" "$MIN"; local E0; E0="$(fsize "$S/HOST.COM")"
	make_ext_opener "$S/EXTOPEN.COM"
	run_in "$S" "V.COM" "HOST.COM > NUL" "EXTOPEN.COM"
	local E1 EFB; E1="$(fsize "$S/HOST.COM")"; EFB="$(bytehex "$S/HOST.COM" 0)"
	[ "$E1" = "$E0" ] && [ "$EFB" != "e9" ] && ok "T3b infected COM disinfected on 6C00h extended open ($E0, first 0x$EFB)" || bad "T3b host $E1 first 0x$EFB (want clean $E0)"

	# T4 — fresh boot: a gen-1 infected host goes resident and infects a fresh COM on execute
	S="$WORK/virus08/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA" "$MIN"
	run_in "$S" "V.COM" "A.COM > NUL"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC" "$MIN"; local C0; C0="$(fsize "$S/C.COM")"
	run_in "$S" "A.COM > OA.TXT" "C.COM > OC.TXT"
	local C1 OA; C1="$(fsize "$S/C.COM")"; OA="$(tr -d '\r\n' < "$S/OA.TXT" 2>/dev/null)"
	[ "$OA" = "AAAAA" ]          && ok "T4 gen-1 host ran its payload in fresh boot"      || bad "T4 gen-1 output '$OA' (want AAAAA)"
	[ "$C1" = "$((C0+GROW))" ]   && ok "T4 fresh COM infected by gen-1 TSR ($C0->$C1)"    || bad "T4 fresh COM $C0->$C1 (want +$GROW)"

	# T5 — installs via the TUNNEL, not a vector hook (see virus06 T4)
	S="$WORK/virus08/t5"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_probe "$S/PROBE.COM"
	run_in "$S" "PROBE.COM" "COPY PROBE.BIN BEFORE.BIN >NUL" "V.COM" "PROBE.COM" "COPY PROBE.BIN AFTER.BIN >NUL"
	local BV AV BID AID
	BV="$(bytehex "$S/BEFORE.BIN" 0 4)"; AV="$(bytehex "$S/AFTER.BIN" 0 4)"
	BID="$(bytehex "$S/BEFORE.BIN" 4 2)"; AID="$(bytehex "$S/AFTER.BIN" 4 2)"
	[ -n "$BID" ] && [ "$BID" != "474a" ]            && ok "T5 baseline clean: nobody answers 7979h (0x$BID)"       || bad "T5 baseline already intercepting (0x$BID)"
	[ "$AID" = "474a" ]                              && ok "T5 INT 21h intercepted after install (7979h->'JG')"     || bad "T5 not intercepting after install (0x$AID)"
	[ -n "$AV" ] && [ "$BV" = "$AV" ]                && ok "T5 INT 21h vector unchanged (0x$BV) => tunneled"        || bad "T5 vector changed 0x$BV->0x$AV (vector hook, not tunneled)"

	# T6 — failed open on missing 3Dh open and 4B00h exec must not close STDERR
	S="$WORK/virus08/t6"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_open_missing "$S/CHKOPEN.COM"; make_exec_missing "$S/CHKEXEC.COM"
	run_in "$S" "V.COM" "CHKOPEN.COM > CHKO.TXT" "CHKEXEC.COM > CHKE.TXT"
	local CHKO CHKE
	CHKO="$(tr -d '\r\n' < "$S/CHKO.TXT" 2>/dev/null)"; CHKE="$(tr -d '\r\n' < "$S/CHKE.TXT" 2>/dev/null)"
	[ "$CHKO" = "OK" ] && ok "T6 missing-file 3Dh open preserves STDERR handle"     || bad "T6 missing-file 3Dh open result '$CHKO' (want OK)"
	[ "$CHKE" = "OK" ] && ok "T6 missing-file 4B00h exec preserves STDERR handle"   || bad "T6 missing-file 4B00h exec result '$CHKE' (want OK)"

	# T7 — COM max-size guard: oversized COM is skipped on execute
	S="$WORK/virus08/t7"; mkdir -p "$S"
	local B0=$((65535 - GROW + 32))
	cp "$com" "$S/V.COM"; make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT"
	local B1 BOUT; B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	[ "$B1" = "$B0" ] && [ "$BOUT" = "BIGOK" ] \
		&& ok "T7 oversized COM skipped and ran cleanly ($B0 bytes)" \
		|| bad "T7 oversized COM $B0->$B1 output '$BOUT'"

	# T8 — directory filesize stealth (11h DIR and 4Eh FindFirst)
	S="$WORK/virus08/t8"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK" "$MIN"; local SH0; SH0="$(fsize "$S/HOST.COM")"
	make_stat4e "$S/STAT4E.COM" "HOST.COM"
	run_in "$S" "V.COM" "HOST.COM > NUL" "DIR HOST.COM > DIR.TXT" "STAT4E.COM"
	local SH1 DSIZE S4E; SH1="$(fsize "$S/HOST.COM")"
	DSIZE="$(dir_size "$S/DIR.TXT" HOST COM)"; S4E="$(le32 "$S/STAT.BIN")"
	[ "$SH1" = "$((SH0+GROW))" ] && [ "$DSIZE" = "$SH0" ] \
		&& ok "T8 FCB DIR stealths infected filesize ($SH1 on disk, DIR shows $DSIZE)" \
		|| bad "T8 FCB DIR showed '$DSIZE' (want $SH0; disk=$SH1)"
	[ "$SH1" = "$((SH0+GROW))" ] && [ "$S4E" = "$SH0" ] \
		&& ok "T8 4Eh FindFirst stealths infected filesize ($SH1 on disk, 4Eh shows $S4E)" \
		|| bad "T8 4Eh FindFirst showed '$S4E' (want $SH0; disk=$SH1)"
}

# virus09: resident COM infector with INT 01h tunneling. Infects on execute
# (4B00h) AND close (3Eh); POLYMORPHIC (variable-length decryptor), so the
# appended body and the total growth differ per infection. COM marker: E9 entry
# + '@' at byte 3 (same recognition as virus08). No size floor, no disinfect.
test_virus09() {
	local com="$1" lst="$2"
	# virus09 is polymorphic: each infection = a fixed body (EndVirus-BeginVirus,
	# read via virussize_from_lst) + a variable-length decryptor, so growth lands
	# in [BODY, BODY+512) and differs per infection.
	local BODY; BODY="$(virussize_from_lst "$lst")"
	[ "$BODY" -gt 0 ] || { bad "virus09: could not read body size (Begin/EndVirus) from LST"; return; }
	local HI=$((BODY + 512))
	# infected? => grew by a single body (+ decryptor), not zero and not doubled
	infected() { local g=$1; [ "$g" -ge "$BODY" ] && [ "$g" -lt "$HI" ]; }
	[ "$RUNNER" != qemu ] && { note "virus09: tunneling needs the real MS-DOS kernel -- drop --dosbox to run it"; return; }

	# T1 — dropper resident; HOST.COM infected on EXECUTE (E9 + '@'), still runs, not re-infected
	local S="$WORK/virus09/t1"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/HOST.COM" "HOSTOK"; local H0; H0="$(fsize "$S/HOST.COM")"
	run_in "$S" "V.COM" "HOST.COM > R1.TXT" "HOST.COM > R2.TXT"
	local H1 G FB MK O1 O2; H1="$(fsize "$S/HOST.COM")"; G=$((H1 - H0))
	FB="$(bytehex "$S/HOST.COM" 0)"; MK="$(bytehex "$S/HOST.COM" 3)"
	O1="$(tr -d '\r\n' < "$S/R1.TXT" 2>/dev/null)"; O2="$(tr -d '\r\n' < "$S/R2.TXT" 2>/dev/null)"
	infected "$G"       && ok "T1 host infected on execute, grew $G (~body $BODY + decryptor)" || bad "T1 host grew $G (want [$BODY,$HI))"
	[ "$FB" = "e9" ]    && ok "T1 host entry patched to E9 jmp"                                 || bad "T1 first byte 0x$FB (want e9)"
	[ "$MK" = "40" ]    && ok "T1 infection marker '@' at byte 3"                               || bad "T1 byte 3 0x$MK (want 40)"
	[ "$O1" = "HOSTOK" ] && ok "T1 host printed payload during infection run"                  || bad "T1 run-1 '$O1' (want HOSTOK)"
	[ "$O2" = "HOSTOK" ] && ok "T1 infected host still runs, not re-infected (grew only $G)"   || bad "T1 run-2 '$O2' (want HOSTOK)"

	# T2 — infect on CLOSE: copying a clean COM produces an infected copy
	S="$WORK/virus09/t2"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/CLEAN.COM" "CLEANX"; local K0; K0="$(fsize "$S/CLEAN.COM")"
	run_in "$S" "V.COM" "COPY CLEAN.COM MADE.COM >NUL"
	local M1 MG MFB MMK; M1="$(fsize "$S/MADE.COM")"; MG=$((M1 - K0)); MFB="$(bytehex "$S/MADE.COM" 0)"; MMK="$(bytehex "$S/MADE.COM" 3)"
	infected "$MG"                        && ok "T2 copied COM infected on close (grew $MG)"   || bad "T2 MADE.COM grew $MG (want [$BODY,$HI))"
	[ "$MFB" = "e9" ] && [ "$MMK" = "40" ] && ok "T2 close-infected copy has E9+'@' markers"    || bad "T2 MADE.COM markers 0x$MFB/0x$MMK (want e9/40)"

	# T3 — POLYMORPHIC: two identical clean COMs, infected, yield DIFFERENT bodies
	S="$WORK/virus09/t3"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/P1.COM" "POLYXX"; make_com_host "$S/P2.COM" "POLYXX"; local Q0; Q0="$(fsize "$S/P1.COM")"
	run_in "$S" "V.COM" "P1.COM > NUL" "P2.COM > NUL"
	local P1 P2 B1 B2; P1="$(fsize "$S/P1.COM")"; P2="$(fsize "$S/P2.COM")"
	B1="$(bytehex "$S/P1.COM" "$Q0" 96)"; B2="$(bytehex "$S/P2.COM" "$Q0" 96)"   # appended body past the host
	{ infected "$((P1-Q0))" && infected "$((P2-Q0))"; } && ok "T3 both identical hosts infected (P1 grew $((P1-Q0)), P2 $((P2-Q0)))" || bad "T3 one host not infected (P1 $((P1-Q0)), P2 $((P2-Q0)))"
	[ -n "$B1" ] && [ "$B1" != "$B2" ] && ok "T3 appended bodies differ => polymorphic"       || bad "T3 appended bodies identical => NOT polymorphic"

	# T4 — fresh boot: a gen-1 infected host goes resident and infects a fresh COM on execute
	S="$WORK/virus09/t4"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_com_host "$S/A.COM" "AAAAA"
	run_in "$S" "V.COM" "A.COM > NUL"; rm -f "$S/V.COM"
	make_com_host "$S/C.COM" "CCCCC"; local C0; C0="$(fsize "$S/C.COM")"
	run_in "$S" "A.COM > OA.TXT" "C.COM > OC.TXT"
	local C1 CG OA; C1="$(fsize "$S/C.COM")"; CG=$((C1 - C0)); OA="$(tr -d '\r\n' < "$S/OA.TXT" 2>/dev/null)"
	[ "$OA" = "AAAAA" ] && ok "T4 gen-1 host ran its payload in fresh boot"                    || bad "T4 gen-1 output '$OA' (want AAAAA)"
	infected "$CG"      && ok "T4 fresh COM infected by gen-1 TSR (grew $CG)"                  || bad "T4 fresh COM grew $CG (want [$BODY,$HI))"

	# T5 — installs via the TUNNEL, not a vector hook (see virus06 T4)
	S="$WORK/virus09/t5"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_probe "$S/PROBE.COM"
	run_in "$S" "PROBE.COM" "COPY PROBE.BIN BEFORE.BIN >NUL" "V.COM" "PROBE.COM" "COPY PROBE.BIN AFTER.BIN >NUL"
	local BV AV BID AID
	BV="$(bytehex "$S/BEFORE.BIN" 0 4)"; AV="$(bytehex "$S/AFTER.BIN" 0 4)"
	BID="$(bytehex "$S/BEFORE.BIN" 4 2)"; AID="$(bytehex "$S/AFTER.BIN" 4 2)"
	[ -n "$BID" ] && [ "$BID" != "474a" ]            && ok "T5 baseline clean: nobody answers 7979h (0x$BID)"       || bad "T5 baseline already intercepting (0x$BID)"
	[ "$AID" = "474a" ]                              && ok "T5 INT 21h intercepted after install (7979h->'JG')"     || bad "T5 not intercepting after install (0x$AID)"
	[ -n "$AV" ] && [ "$BV" = "$AV" ]                && ok "T5 INT 21h vector unchanged (0x$BV) => tunneled"        || bad "T5 vector changed 0x$BV->0x$AV (vector hook, not tunneled)"

	# T6 — failed open on missing 4B00h exec must not close STDERR; INT 24h returns via IRET
	S="$WORK/virus09/t6"; mkdir -p "$S"
	cp "$com" "$S/V.COM"; make_exec_missing "$S/CHKEXEC.COM"
	run_in "$S" "V.COM" "CHKEXEC.COM > CHK.TXT"
	local CHK I24_OFF BV_OFF I24_BYTES
	CHK="$(tr -d '\r\n' < "$S/CHK.TXT" 2>/dev/null)"
	BV_OFF="$(sym_from_lst "$lst" BEGINVIRUS)"; I24_OFF="$(sym_from_lst "$lst" INT24HHANDLER)"
	I24_BYTES="$(bytehex "$com" $((I24_OFF - BV_OFF)) 3)"
	[ "$CHK" = "OK" ]           && ok "T6 missing-file exec preserves STDERR handle"  || bad "T6 missing-file exec result '$CHK' (want OK)"
	[ "$I24_BYTES" = "b003cf" ] && ok "T6 INT 24h handler returns al=3 via IRET"      || bad "T6 INT 24h bytes 0x$I24_BYTES (want b003cf = mov al,3 / iret)"

	# T7 — COM max-size guard: oversized COM is skipped on execute
	S="$WORK/virus09/t7"; mkdir -p "$S"
	local B0=$((65535 - BODY + 32))
	cp "$com" "$S/V.COM"; make_com_host "$S/BIG.COM" "BIGOK" "$B0"
	run_in "$S" "V.COM" "BIG.COM > BIGOUT.TXT"
	local B1 BOUT; B1="$(fsize "$S/BIG.COM")"; BOUT="$(tr -d '\r\n' < "$S/BIGOUT.TXT" 2>/dev/null)"
	[ "$B1" = "$B0" ] && [ "$BOUT" = "BIGOK" ] \
		&& ok "T7 oversized COM skipped and ran cleanly ($B0 bytes)" \
		|| bad "T7 oversized COM $B0->$B1 output '$BOUT'"
}

# virus10: non-resident MBR bomb -- reads drive 80h MBR via INT 13h, XOR-encrypts
# its MBR payload with a random 16-bit key from INT 21h/2Ch, overwrites the start
# of the MBR (leaving the partition table and 55AA boot signature intact), and
# writes it back. On next boot the stub decrypts itself and chainloads the VBR.
test_virus10() {
	local com="$1" lst="$2"
	if [ "$RUNNER" != qemu ]; then
		note "virus10: MBR overwrite/boot test needs QEMU -- drop --dosbox to run it"
		return
	fi

	local BV BM BE EE EM KY
	BV="$(sym_from_lst "$lst" BEGINVIRUS)"
	BM="$(sym_from_lst "$lst" BEGINMBRSECTION)"
	BE="$(sym_from_lst "$lst" BEGINENCRYPTEDSECTION)"
	EE="$(sym_from_lst "$lst" ENDENCRYPTEDSECTION)"
	EM="$(sym_from_lst "$lst" ENDMBRSECTION)"
	KY="$(sym_from_lst "$lst" KEY)"
	if [ "$BV" -lt 0 ] || [ "$BM" -lt 0 ] || [ "$BE" -lt 0 ] || [ "$EE" -lt 0 ] || [ "$EM" -lt 0 ] || [ "$KY" -lt 0 ]; then
		bad "virus10: could not read MBR section symbols from LST"
		return
	fi
	local MBR_LEN=$((EM - BM)) STUB_LEN=$((BE - BM)) ENC_OFF=$((BE - BM))
	local ENC_WORDS=$(((EE - BE) / 2)) KEY_OFF=$((KY - BM))
	local COM_MBR_OFF=$((BM - BV)) COM_ENC_OFF=$((BE - BV))
	if [ "$MBR_LEN" -le 0 ] || [ "$MBR_LEN" -gt 446 ]; then
		bad "virus10: unexpected MBR payload size ($MBR_LEN bytes)"
		return
	fi

	# T1 — run dropper on a throwaway disk image; verify MBR overwrite, XOR
	# encryption with the stored Key, and intact partition table + 55AA signature.
	local S="$WORK/virus10/t1"; mkdir -p "$S"
	local IMG="$S/disk.img"
	cp "$DOS_IMAGE" "$IMG"
	cp "$com" "$S/V.COM"
	printf '@ECHO OFF\r\nC:\r\nCD \\\r\nV.COM\r\nECHO INFECTED>C:\\INFECTED.TXT\r\n' > "$S/AUTOEXEC.BAT"
	mcopy -i "$IMG@@$IMG_OFF" -o "$S/V.COM" "$S/AUTOEXEC.BAT" ::/ 2>/dev/null

	if qemu_boot "$IMG" "INFECTED.TXT"; then
		ok "T1 dropper ran under MS-DOS and exited cleanly"
	else
		bad "T1 dropper timed out before writing completion marker"
		return
	fi

	local ORIG_CODE NEW_CODE WANT_STUB GOT_STUB
	ORIG_CODE="$(bytehex "$DOS_IMAGE" 0 "$MBR_LEN" | tr -d '\n')"
	NEW_CODE="$(bytehex "$IMG" 0 "$MBR_LEN" | tr -d '\n')"
	WANT_STUB="$(bytehex "$com" "$COM_MBR_OFF" "$STUB_LEN" | tr -d '\n')"
	GOT_STUB="$(bytehex "$IMG" 0 "$STUB_LEN" | tr -d '\n')"
	[ -n "$NEW_CODE" ] && [ "$NEW_CODE" != "$ORIG_CODE" ] \
		&& ok "T1 MBR code overwritten ($MBR_LEN bytes)" \
		|| bad "T1 MBR code unchanged"
	[ "$GOT_STUB" = "$WANT_STUB" ] \
		&& ok "T1 MBR starts with BeginMbrSection decryptor stub ($STUB_LEN bytes)" \
		|| bad "T1 MBR decryptor stub mismatch"

	local KEY_HEX k0 k1 PLAIN_HEX GOT_ENC EXP_ENC="" i b0 b1
	KEY_HEX="$(bytehex "$IMG" "$KEY_OFF" 2 | tr -d '\n')"
	PLAIN_HEX="$(bytehex "$com" "$COM_ENC_OFF" $((ENC_WORDS * 2)) | tr -d '\n')"
	GOT_ENC="$(bytehex "$IMG" "$ENC_OFF" $((ENC_WORDS * 2)) | tr -d '\n')"
	if [ "${#KEY_HEX}" -eq 4 ]; then
		k0=$((16#${KEY_HEX:0:2})); k1=$((16#${KEY_HEX:2:2}))
		for ((i = 0; i < ENC_WORDS * 4; i += 4)); do
			b0=$((16#${PLAIN_HEX:i:2} ^ k0))
			b1=$((16#${PLAIN_HEX:i+2:2} ^ k1))
			printf -v EXP_ENC '%s%02x%02x' "$EXP_ENC" "$b0" "$b1"
		done
	fi
	[ -n "$EXP_ENC" ] && [ "$GOT_ENC" = "$EXP_ENC" ] \
		&& ok "T1 MBR body XOR-encrypted with stored Key (0x${KEY_HEX:2:2}${KEY_HEX:0:2})" \
		|| bad "T1 MBR encrypted body does not match plaintext XOR Key (0x$KEY_HEX)"

	local ORIG_PT NEW_PT SIG
	ORIG_PT="$(bytehex "$DOS_IMAGE" 446 64 | tr -d '\n')"
	NEW_PT="$(bytehex "$IMG" 446 64 | tr -d '\n')"
	SIG="$(bytehex "$IMG" 510 2 | tr -d '\n')"
	[ "$NEW_PT" = "$ORIG_PT" ] \
		&& ok "T1 partition table (0x1BE..0x1FD) preserved intact" \
		|| bad "T1 partition table corrupted"
	[ "$SIG" = "55aa" ] \
		&& ok "T1 MBR boot signature (0x1FE..0x1FF) preserved (55aa)" \
		|| bad "T1 MBR boot signature 0x$SIG (want 55aa)"

	# T2 — boot the already-infected disk image; verify the encrypted MBR stub
	# decrypts itself and chainloads MS-DOS cleanly. BOOTOK.TXT holds the content
	# we check; QDONE.TXT is written AFTER it as the completion marker, so once it
	# appears BOOTOK.TXT is fully flushed (qemu_boot kills on the marker, and a
	# marker's own content can be truncated -- never read the marker itself).
	printf '@ECHO OFF\r\nC:\r\nCD \\\r\nECHO BOOTOK>C:\\BOOTOK.TXT\r\nECHO DONE>C:\\QDONE.TXT\r\n' > "$S/AUTOEXEC.BAT"
	mcopy -i "$IMG@@$IMG_OFF" -o "$S/AUTOEXEC.BAT" ::/AUTOEXEC.BAT 2>/dev/null
	if qemu_boot "$IMG" "QDONE.TXT"; then
		mcopy -i "$IMG@@$IMG_OFF" -o ::/BOOTOK.TXT "$S/BOOTOK.TXT" 2>/dev/null
		local BOUT; BOUT="$(tr -d '\r\n' < "$S/BOOTOK.TXT" 2>/dev/null)"
		[ "$BOUT" = "BOOTOK" ] \
			&& ok "T2 infected disk booted MS-DOS cleanly via encrypted MBR" \
			|| bad "T2 infected disk boot marker '$BOUT' (want BOOTOK)"
	else
		bad "T2 infected disk failed to boot MS-DOS (timed out)"
	fi
}

# ---- driver ----------------------------------------------------------------

run_demo() {
	local name="$1" src="$2"
	read -r type res trig test_name <<<"$(demo_profile "$name")"
	printf '%s  %s\n' "$(green "########## $name")" "$(dim "[$type, resident=$res, infects: $trig]")"
	local bdir="$WORK/$name/build"
	if ! build_virus "$src" "$bdir"; then
		bad "$name: BUILD FAILED (see $LOG)"; echo; return
	fi
	ok "$name builds ($(fsize "$bdir/V.COM") bytes, VirusSize=$(virussize_from_lst "$bdir/V.LST"))"
	if [ "$test_name" != "-" ]; then
		if ! declare -F "test_$test_name" >/dev/null; then
			bad "$name: missing test_$test_name function"
		else
			local fail_before=$FAIL rc=0
			"test_$test_name" "$bdir/V.COM" "$bdir/V.LST" || rc=$?
			if [ "$rc" -ne 0 ] && [ "$FAIL" -eq "$fail_before" ]; then
				bad "$name: test_$test_name failed (exit $rc)"
			fi
		fi
	else
		note "behavioral test not yet implemented — build-check only"
	fi
	echo
}

# flags (parse first so --qemu is in effect for the pre-flight below)
args=()
for a in "$@"; do
	case "$a" in
		--qemu) RUNNER=qemu ;;
		--dosbox) RUNNER=dosbox ;;
		*) args+=("$a") ;;
	esac
done
set -- ${args[@]+"${args[@]}"}

echo "DOS tools: $DOS_TOOLS_DRIVE   DOSBox: $DOSBOX"
[ -f "$DOS_TOOLS_DRIVE/TASM/BIN/TASM.EXE" ] || { echo "$(red error): TASM not found under $DOS_TOOLS_DRIVE (see README)"; exit 1; }
if [ "$RUNNER" = qemu ]; then
	command -v "$QEMU" >/dev/null 2>&1 || { echo "$(red error): $QEMU not found (install qemu)"; exit 1; }
	command -v mcopy >/dev/null 2>&1 || { echo "$(red error): mtools (mcopy) not found (install mtools)"; exit 1; }
	[ -f "$DOS_IMAGE" ] || { echo "$(red error): bootable image $DOS_IMAGE not found (build it: install-dos-tools.py msdosimg)"; exit 1; }
	# first-partition byte offset (start-LBA at MBR 0x1C6 == dec 454) for mtools image@@offset access
	IMG_OFF=$(( $(dd if="$DOS_IMAGE" bs=1 skip=454 count=4 2>/dev/null | od -An -tu4 | tr -d ' ') * 512 ))
	export MTOOLS_SKIP_CHECK=1
	echo "Runner: qemu ($QEMU)   DOS image: $DOS_IMAGE   partition offset: $IMG_OFF"
fi
echo

targets=()
if [ $# -eq 0 ]; then
	for d in $ALL_DEMOS; do targets+=("$d|$REPO_ROOT/src/$d.asm"); done
else
	for a in "$@"; do
		if [ -f "$a" ]; then targets+=("$(basename "$a" .asm)|$a")
		else targets+=("$a|$REPO_ROOT/src/$a.asm"); fi
	done
fi

for t in "${targets[@]}"; do run_demo "${t%%|*}" "${t#*|}"; done

echo "============================================="
printf 'Result: %s passed, %s failed\n' "$(green "$PASS")" "$([ "$FAIL" -gt 0 ] && red "$FAIL" || echo 0)"
[ "$FAIL" -eq 0 ]
