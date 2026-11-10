#!/usr/bin/env bash
#
# Downloads DOS tools and extracts their installation files into DOSBox,
# ready to be installed.
#
#   asmedit ASM Edit 1.82b                              -> DOSBox/aedtinst
#   bc      Borland C++ 3.1 and Application Frameworks  -> DOSBox/bcsetup
#   fprot   F-PROT 3.16f                                -> DOSBox/fprot
#   freedos FreeDOS 1.4 (LiteUSB)                       -> DOSBox/fdsetup
#   msdos   MS-DOS 6.22 Plus Enhanced Tools             -> DOSBox/dossetup
#   msdosimg (same as msdos, for install-dos-tools.py msdosimg)
#   nc      Norton Commander 5.51                       -> DOSBox/ncsetup
#   tasm    Borland Turbo Assembler 4.0                 -> DOSBox/tasminst
#   tbav    Thunderbyte Anti-Virus 8.03                 -> DOSBox/tbavinst
#   tp      Borland Turbo Pascal 7.01                   -> DOSBox/tpsetup
#
# The floppy sets (bc, msdos, nc, tasm, tp) are downloaded from WinWorld,
# F-PROT and TBAV from DOSDays, ASM Edit from o-love.net and FreeDOS from
# ibiblio.org.
#
# Usage: download-dos-tools.sh [directory] <target>...
#        The installation folders are created in the given directory.
#        With no directory, they are written to DOSBox.
#        With no target, the options are printed and nothing is downloaded.
#
# Every download is checked against its SHA-256.
#
# Requires: curl, 7zz (or 7z), unzip, shasum (or sha256sum)
#
set -euo pipefail

ALL_TARGETS=(asmedit bc fprot freedos msdos nc tasm tbav tp)

# WinWorld's file server only serves a file after its download link has been
# opened, so files are downloaded through that link (download id + mirror).
WINWORLD_URL="https://winworldpc.com/download"
WINWORLD_MIRROR="c3ae6ee2-8099-713d-3411-c3a6e280947e"   # dl.winworldpc.com

usage() {
    cat <<EOF
Usage: $(basename "$0") [directory] <target>...

The installation folders are created in the given directory. With no directory, they are written to DOSBox.

Targets:
  all         every tool below
  asmedit     ASM Edit 1.82b
  bc          Borland C++ 3.1 and Application Frameworks
  fprot       F-PROT 3.16f
  freedos     FreeDOS 1.4 (LiteUSB)
  msdos       MS-DOS 6.22 Plus Enhanced Tools
  msdosimg    same download as msdos
  nc          Norton Commander 5.51
  tasm        Borland Turbo Assembler 4.0
  tbav        Thunderbyte Anti-Virus 8.03
  tp          Borland Turbo Pascal 7.01
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# Parse arguments. No arguments prints the options.
# A leading directory is used as it is. Otherwise files go under DOSBox/.
BASE="$PWD/DOSBox"
targets=()
if [ "$#" -eq 0 ]; then
    usage
    exit 0
fi
first=1
for arg in "$@"; do
    case "$arg" in
        all) targets+=("${ALL_TARGETS[@]}") ;;
        asmedit|bc|fprot|freedos|msdos|msdosimg|nc|tasm|tbav|tp) targets+=("$arg") ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ "$first" -eq 1 ]; then
                case "$arg" in
                    */*|.|..) is_dir=1 ;;
                    *) is_dir=0 ;;
                esac
                if [ "$is_dir" -eq 1 ] || [ "$#" -gt 1 ]; then
                    BASE="${arg%/}"
                    first=0
                    continue
                fi
            fi
            echo "error: unknown target '$arg'" >&2
            usage >&2
            exit 1
            ;;
    esac
    first=0
done
if [ "${#targets[@]}" -eq 0 ]; then
    usage
    exit 0
fi

command -v curl >/dev/null || die "curl not found"
command -v unzip >/dev/null || die "unzip not found"
if command -v 7zz >/dev/null; then
    SEVENZIP=7zz
elif command -v 7z >/dev/null; then
    SEVENZIP=7z
else
    die "7zz/7z not found (install 7zip / sevenzip)"
fi
if command -v shasum >/dev/null; then
    SHA256=(shasum -a 256)
elif command -v sha256sum >/dev/null; then
    SHA256=(sha256sum)
else
    die "shasum/sha256sum not found"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# download <url> <file> <sha256>
download() {
    local url="$1" file="$2" expected="$3" actual
    echo "Downloading $(basename "$file") from $url"
    curl -fL --retry 3 -o "$file" "$url" || die "download of $url failed"
    actual="$("${SHA256[@]}" "$file" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] ||
        die "$(basename "$file") has SHA-256 $actual, expected $expected"
}

# merge <src dir> <dest dir> [path]
# Moves everything in src into dest. A file that already exists in dest must
# have the same contents (disks of a set may repeat a file). path is the
# directory's path on the disk, for the error message.
merge() {
    local src="$1" dest="$2" path="${3:-}" entry name
    for entry in "$src"/* "$src"/.[!.]*; do
        [ -e "$entry" ] || continue
        name="${entry##*/}"
        if [ ! -e "$dest/$name" ]; then
            mv "$entry" "$dest/$name"
        elif [ -d "$entry" ] && [ -d "$dest/$name" ]; then
            merge "$entry" "$dest/$name" "$path$name/"
        elif [ -f "$entry" ] && [ -f "$dest/$name" ] && cmp -s "$entry" "$dest/$name"; then
            mv -f "$entry" "$dest/$name"
        else
            die "$path$name differs between the disk images"
        fi
    done
}

# install_floppies <download id> <name> <dest dir> <sha256> [boot image]
# Downloads a WinWorld floppy set (<name>.7z) and extracts all FAT disk images
# into dest. The boot sector of the given boot image is saved as BOOTSECT.BIN.
install_floppies() {
    local id="$1" name="$2" dest="$BASE/$3" work="$WORKDIR/$3"
    local archive="$work/$name.7z"
    local url="$WINWORLD_URL/$id/from/$WINWORLD_MIRROR"

    mkdir -p "$work/out"
    download "$url" "$archive" "$4"

    echo "Extracting archive"
    (cd "$work" && "$SEVENZIP" x -y "$archive" >/dev/null)

    local imgdir="$work/$name"
    [ -d "$imgdir" ] || imgdir="$work"

    local images i
    shopt -s nullglob nocaseglob
    images=("$imgdir"/*.img)
    shopt -u nullglob nocaseglob
    [ "${#images[@]}" -gt 0 ] || die "no .img files found in $name"

    for i in "${images[@]}"; do
        basename "$i"
        rm -rf "$work/disk"
        "$SEVENZIP" x -y -o"$work/disk" "$i" >/dev/null
        merge "$work/disk" "$work/out"
    done

    if [ -n "${5:-}" ]; then
        [ -f "$imgdir/$5" ] || die "$5 not found in $name"
        head -c 512 "$imgdir/$5" > "$work/out/BOOTSECT.BIN"
    fi

    mv "$work/out" "$dest"
    echo "Done: $dest"
}

# install_image_zip <url> <image> <dest dir> <sha256>
# Downloads a zip holding a disk image and extracts the image's files into dest.
install_image_zip() {
    local url="$1" image="$2" dest="$BASE/$3" work="$WORKDIR/$3" archive
    archive="$work/$(basename "$url")"

    mkdir -p "$work"
    download "$url" "$archive" "$4"

    echo "Extracting $image"
    unzip -q -o "$archive" "$image" -d "$work"
    "$SEVENZIP" x -y -o"$work/out" "$work/$image" >/dev/null

    mv "$work/out" "$dest"
    echo "Done: $dest"
}

# install_zip <url> <dest dir> <sha256>
install_zip() {
    local url="$1" dest="$BASE/$2" work="$WORKDIR/$2" archive
    archive="$work/$(basename "$url")"

    mkdir -p "$work"
    download "$url" "$archive" "$3"

    # unzip is used instead of 7zz: some old DOS zips (e.g. TBAV) have bogus
    # attribute bits that 7zz extracts as broken symlinks
    echo "Extracting archive"
    unzip -q -o "$archive" -d "$work/out"

    mv "$work/out" "$dest"
    echo "Done: $dest"
}

dest_of() {
    case "$1" in
        asmedit) echo aedtinst ;;
        bc)      echo bcsetup ;;
        fprot)   echo fprot ;;
        freedos) echo fdsetup ;;
        msdos|msdosimg) echo dossetup ;;
        nc)      echo ncsetup ;;
        tasm)    echo tasminst ;;
        tbav)    echo tbavinst ;;
        tp)      echo tpsetup ;;
    esac
}

run_target() {
    case "$1" in
        asmedit)
            install_zip "http://www.o-love.net/asmedit/aedt182b.zip" aedtinst \
                f997877956a0d0bc4cd7e7fa4643be210cc4e96ac591d5090285da2232248c36
            ;;
        bc)
            install_floppies f7396558-9ba2-11e9-ab10-fa163e9022f0 \
                "Borland CPP 3.1 and Application Frameworks (1992) (3.5-1.44mb)" bcsetup \
                76e155a7fb7eb0590930ecd513644c977497a020466a272943776fbf683d0f27
            ;;
        fprot)
            install_zip "https://www.dosdays.co.uk/media/frisk/3.16f/f-prot.zip" fprot \
                af8814b0080cabb711adbbe81d8fc82a765e7eaba67ebe8781139c6183da4cd4
            ;;
        freedos)
            install_image_zip \
                "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/FD14-LiteUSB.zip" \
                FD14LITE.img fdsetup \
                857dcd2ebf9d3d094320154db5fb5b830acba6fb98f981a95a0ca7ab3350338b
            ;;
        msdos|msdosimg)
            install_floppies c38fc38d-68c2-bbe2-80a6-4b11c3a4c2ac \
                "Microsoft MS-DOS 6.22 Plus Enhanced Tools (3.5)" dossetup \
                3e5916663284e39e793ef1dbec61c7893b20ece3a7a2847946f0b6624603d76f Disk1.img
            ;;
        nc)
            install_floppies 483de280-9437-18c3-9a11-c3a4e284a2ef \
                "Norton Commander 5.51 (3.5)" ncsetup \
                65e8f3badc6383d95fe390726b0e7456591ec77f5fa02bd88b5c29cb49da7e38
            ;;
        tasm)
            install_floppies c2a9c393-6b65-c391-c380-11c3a6c2bb2a \
                "Borland Turbo Assembler 4.0 (3.5-1.44mb)" tasminst \
                089bc5d90caae6529cd26d84b7ec3e9aa9759fbc760da63275e3a7449a4e4c3a
            ;;
        tbav)
            install_zip "https://www.dosdays.co.uk/media/anti_virus/tbdos803.zip" tbavinst \
                1785b805c55a337fe84f792d76104c864eb963a6cfefaaa064a6ee3b44314912
            ;;
        tp)
            install_floppies a1fd01e4-767f-11ea-8c4a-fa163e9022f0 \
                "Borland Turbo Pascal 7.01 (3.5-720k)" tpsetup \
                38815257b2fc22b163ffae5cd062cfc018425d2d3c62a6032d9823708e79b92b
            ;;
    esac
}

mkdir -p "$BASE"

for t in "${targets[@]}"; do
    dest="$(dest_of "$t")"
    if [ -e "$BASE/$dest" ]; then
        echo "Skipping $t: $BASE/$dest already exists"
        continue
    fi
    run_target "$t"
done
