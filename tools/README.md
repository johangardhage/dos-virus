# Download scripts

## download-dos-tools.sh

Tools are written to `DOSBox`. Every download is checked against its SHA-256 before it is extracted.

| Target | Destination | Name | Download |
| --- | --- | --- | --- |
| `asmedit` | `aedtinst` | ASM Edit 1.82b | [aedt182b.zip](http://www.o-love.net/asmedit/) |
| `bc` | `bcsetup` | Borland C++ 3.1 and Application Frameworks | [Borland CPP 3.1 and Application Frameworks (1992) (3.5-1.44mb).7z](https://winworldpc.com/product/borland-c/30) |
| `fprot` | `fprot` | F-PROT 3.16f | [f-prot.zip](https://www.dosdays.co.uk/topics/antivirus_utilities.php) |
| `freedos` | `fdsetup` | FreeDOS 1.4 (contents of the LiteUSB image) | [FD14-LiteUSB.zip](https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/) |
| `msdos`, `msdosimg` | `dossetup` | MS-DOS 6.22 Plus Enhanced Tools (setup disks 1-3 and the supplemental disk) | [Microsoft MS-DOS 6.22 Plus Enhanced Tools (3.5).7z](https://winworldpc.com/product/ms-dos/622) |
| `nc` | `ncsetup` | Norton Commander 5.51 | [Norton Commander 5.51 (3.5).7z](https://winworldpc.com/product/norton-commander/55x) |
| `tasm` | `tasminst` | Borland Turbo Assembler 4.0 | [Borland Turbo Assembler 4.0 (3.5-1.44mb).7z](https://winworldpc.com/product/turbo-assembler/4x) |
| `tbav` | `tbavinst` | Thunderbyte Anti-Virus 8.03 | [tbdos803.zip](https://www.dosdays.co.uk/topics/antivirus_utilities.php) |
| `tp` | `tpsetup` | Borland Turbo Pascal 7.01 | [Borland Turbo Pascal 7.01 (3.5-720k).7z](https://winworldpc.com/product/turbo-pascal/7x) |

## install-dos-tools.py

Tools are installed to `DOSBox`, the DOSBox C: drive, the same way as their DOS `INSTALL.EXE` would, without running DOS. The setup files are checked before installing; only the versions downloaded by `download-dos-tools.sh` are supported. If an installation fails or is interrupted, the partly installed directory is removed.

| Target | Source | Destination | Name | Installer options |
| --- | --- | --- | --- | --- |
| `asmedit` | `aedtinst` | `ASMEDIT` | ASM Edit 1.82b | `C:\ASMEDIT` |
| `bc` | `bcsetup` | `BORLANDC` | Borland C++ 3.1 and Application Frameworks | `C:\BORLANDC`, Windows capability: No |
| `tasm` | `tasminst` | `TASM`, `WINDOWS` | Borland Turbo Assembler 4.0 | `C:\TASM`, 16-bit command line tools, Turbo Debugger for DOS |
| `tp` | `tpsetup` | `TP` | Borland Turbo Pascal 7.01 | `C:\TP` |
| `msdos` | `dossetup` | `DOS` | MS-DOS 6.22 | `C:\DOS`, MS-DOS only (no Windows parts) |
| `msdosimg` | `dossetup` | `MSDOS.IMG` | MS-DOS 6.22 bootable hard disk image | 64 MB, FAT16, `C:\DOS`, SETUP's `CONFIG.SYS` and `AUTOEXEC.BAT` |
| `freedos` | `fdsetup` | `FREEDOS`, `FDAUTO.BAT` | FreeDOS 1.4 | `C:\FREEDOS`, DOSBox hybrid install, base packages without sources |

The operating systems are always installed natively, also with `--dosbox`; their setup programs only install to a bootable drive.

- **msdos**: `C:\DOS` gets the files that `SETUP.EXE` copies there from setup disks 1-3, expanded like `EXPAND.EXE` does (byte-identical, with the same dates). `IO.SYS`, `MSDOS.SYS` and the supplemental disk are not installed. The MS-DOS 6.22 programs check the DOS version, so run `ver set 6.22` in DOSBox Staging first.
- **msdosimg**: `MSDOS.IMG` is a 64 MB hard disk with MS-DOS 6.22 installed the way `FDISK`, `FORMAT C: /S` and `SETUP` would: an active FAT16 partition, the system files, `C:\DOS`, and SETUP's `CONFIG.SYS` and `AUTOEXEC.BAT`. Booting it runs the real MS-DOS kernel instead of DOSBox's built-in DOS, which programs that trace into DOS (like the INT 01h tunneling in `virus06`) need:

  ```
  mount c MSDOS.IMG -t hdd
  boot c:
  ```

  The image is built directly, without running DOS. Its partition boot sector is the one MS-DOS FORMAT writes (saved from setup disk 1 as `dossetup/BOOTSECT.BIN`); the master boot record code is a small loader in `install-dos-tools.py`.
- **freedos**: FreeDOS runs on the DOSBox kernel. Run `C:\FDAUTO.BAT` to start the FreeDOS shell with `C:\FREEDOS\BIN` on the path.

With `--dosbox`, the real `INSTALL.EXE` is run in DOSBox Staging instead, and the installer options are typed with `AUTOTYPE`. Both ways give the same result.

| Option | Description |
| --- | --- |
| `--dosbox` | run the real `INSTALL.EXE` in DOSBox Staging; don't type into the DOSBox window |
| `--headless` | run DOSBox without a window |
| `--slowdown N` | make the pauses between typed keys N times longer, for slow machines |
