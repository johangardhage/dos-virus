# dos-virus

Retro programming in Borland Turbo Assembler

![Screenshot](/screenshots/tasm.png "Borland Turbo Assembler IDE")

## Prerequisites

To build and run the Borland Turbo Assembler virus programs, you must first install the following tools:

- [DOSBox](https://www.dosbox.com/download.php)
- [Borland Turbo Assembler](https://winworldpc.com/product/turbo-assembler/4x)
- [ASM Edit](http://www.o-love.net/asmedit/ae_down.html)

### Install DOSBox

#### openSUSE

`$ sudo zypper install dosbox mtools p7zip-full`

#### Ubuntu

`$ sudo apt install dosbox mtools p7zip-full`

#### Configuration

When starting `dosbox` the first time, the configuration file `~/.dosbox/dosbox-0.74-2.conf` will be generated

### Install Borland Turbo Assembler

1. Download `Borland Turbo Assembler 4.0 (3.5-1.44mb).7z`

1. Create a directory which will contain the DOS C: drive
   ```
   $ mkdir ~/DOSBox
   ```

1. Extract the downloaded Borland Turbo Assembler archive
   ```
   $ 7z x "Borland Turbo Assembler 4.0 (3.5-1.44mb).7z"
   ```

1. Extract the Borland Turbo Assembler disk images
   ```
   $ cd "Borland Turbo Assembler 4.0 (3.5-1.44mb).7z"/
   $ mkdir tasminst
   $ for i in disk01.img disk02.img disk03.img; do echo $i; mcopy -m -i $i :: tasminst; done
   ```

1. Move the extracted files to the DOS C: drive
   ```
   $ mv tasminst ~/DOSBox/
   ```

1. Configure DOSBox

   Edit `~/.dosbox/dosbox-0.74-2.conf` and add the following autoexec options
   ```
   [autoexec]
   mount c ~/DOSBox
   path %PATH%;C:\TASM\BIN
   c:
   ```

1. Start `dosbox` and execute the Borland Turbo Assembler installation program
   ```
   $ dosbox
   C:\> cd tasminst
   C:\TASMINST> install.exe
   ```
   In the installation program, select the following options
   ```
   Enter the SOURCE drive to use: C
   Enter the SOURCE Path: \TASMINST
   TASM Directory             [ C:\TASM ]
   Windows Directory          [ C:\WINDOWS ]
   16-bit command line tools  [ Yes ]
   32-bit command line tools  [ No  ]
   Turbo Debugger for Windows [ No  ]
   Turbo Debugger for DOS     [ Yes ]
   Turbo Debugger for Win32   [ No  ]
   Examples                   [ No  ]
   Documentation Files        [ No  ]

   Start Installation
   ```

### Install ASM Edit

1. Download [ASM Edit](http://www.o-love.net/asmedit/ae_down.html)
   ```
   $ curl -O http://www.o-love.net/asmedit/aedt182b.zip
   ```

1. Extract the downloaded ASM Edit archive
   ```
   $ unzip aedt182b.zip -d aedtinst/
   ```

1. Move the extracted files to the DOS C: drive
   ```
   $ mv aedtinst ~/DOSBox/
   ```

1. Configure DOSBox

   Edit `~/.dosbox/dosbox-0.74-2.conf` and add the following autoexec options
   ```
   [autoexec]
   path %PATH%;C:\ASMEDIT
   ```

1. Start `dosbox` and execute the ASM Edit installation program
   ```
   $ dosbox
   C:\> cd aedtinst
   C:\AEDTINST> install.exe
   ```
   In the installation program, select the following options
   ```
   Press Alt+I to Begin install
   Target path: C:\ASMEDIT
   Press Alt+X to Exit
   ```

## Build virus programs

Link the `dos-virus` git repository to the DOS C: drive
```
$ ln -s ~/git/github/dos-virus ~/DOSBox/virus
```

#### Build from DOS terminal

1. Execute build script
   ```
   C:\VIRUS> buildall.bat
   ```
   The virus programs will be located in the `C:\VIRUS\BUILD` directory

#### Build from ASM Edit

1. Start ASM Edit
   ```
   C:\VIRUS> asmshell
   ```

1. Configure ASM Edit

   Press `ALT+O` for options

   Select `External programs`, `Assembler`, `user defined`, `Edit` and type in the following options
   ```
   Program title: TASM
   Program path: C:\TASM\BIN\TASM.EXE
   Command line: /w1/m/t !ACMPL,!ANAME,!ANAME
   ```

   Select `External programs`, `Linker`, `user defined`, `Edit` and type in the following options
   ```
   Program title: TLINK
   Program path: C:\TASM\BIN\TLINK.EXE
   Command line: !ANAME!OBJFL,!ANAME!TARGT,!ANAME.MAP,!LIBFL,!MKCOM
   ```

   Select `Directories` and type in the following directories
   ```
   ASM files search path: C:\VIRUS\SRC
   COM, EXE, LIB and OBJ: C:\VIRUS\BUILD
   Includes and Macros: C:\VIRUS\SRC
   ```

   Select `Environment`, `Preferences` and the following options
   ```
   Auto save: [ ] Desktop
   ```

   Select `Environment`, `Editor` and the following options
   ```
   [ ] Create backup files
   ```

   Select `Save`

1. Open virus source file

   Press `F3` to open file

1. Build virus program

   Press `Alt-A` and then press `Assemble` to assemble the file

   Press `Alt-A` and then press `Link` to link the file

   The virus programs will be located in the `C:\VIRUS\BUILD` directory

## License

Licensed under MIT license. See [LICENSE](LICENSE) for more information.

## Authors

* Johan Gardhage
