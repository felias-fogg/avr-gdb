# Mostly static patched AVR-GDB

The script `avr-gdb-build.sh` can be used to build a mostly static version of `avr-gdb` locally, which incorporates patches that reside in the main folder. *Mostly static* means that it is completely static for Linux, it depends only on a few system libraries (but nothing from Homebrew) under macOS, and only dynamic system libraries under Windows. The script is designed to build for the machine the script is executed on. However, in order to create the Windows versions, you need to cross-compile it under Linux.

The result of running this script will be stored under `build/avr-<os>-<arch>/`.

The result of the latest CI run can be found as assets of the [latest release](https://github.com/felias-fogg/avr-gdb/releases/latest). These are used as part of the avrocd tools for debug-enabled Arduino platform packages (see [https://pyavrocd.io](https://pyavrocd.io))

## Generating a patch

Clone https://sourceware.org/git/binutils-gdb.git

Make changes. Commit. Run git format-patch -1. 

## Acknowledgement

The shell script `avr-gdb-build.sh` is based on [Zak's `avr-gcc-build.sh`](https://github.com/ZakKemble/avr-gcc-build).
