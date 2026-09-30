# Highly portable, patched AVR-GDB version

The script `avr-gdb-build.sh` can be used to build a version of `avr-gdb` locally, which tries to be as compatible as possible with different OS versions by linking non-standard libraries statically. The script is designed to build for the machine the script is executed on. However, in order to create the Windows versions, you need to cross-compile it under Linux.

The result of running this script will be stored under `build/avr-<os>-<arch>/`.

The result of the latest CI run, which builds binaries for all platforms, can be found as assets of the [latest release](https://github.com/felias-fogg/avr-gdb/releases/latest). These are used as part of the avrocd tools for debug-enabled Arduino platform packages (see [https://pyavrocd.io](https://pyavrocd.io)). The following table specifies the compatibility with OS versions (macOS, Windows) or GLIBC (Linux).

| Platform                         | Oldest possible OS  or GLIBC version                         |
| -------------------------------- | ------------------------------------------------------------ |
| Windows / Intel / 32 bit         | Windows Vista                                                |
| Windows / Intel / 64 bit         | Windows Vista                                                |
| Linux / Intel / 32 bit (armv6hf) | GLIBC 2.31 (Pi OS bullseye)                                  |
| Linux / Intel / 64 bit           | GLIBC 2.34 (Ubuntu 22.04 / Debian 12 / Pi OS bookworm / RHEL 9) |
| Linux / ARM / 32 bit             | GLIBC 2.34 (Ubuntu 22.04 / Debian 12 / Pi OS bookworm / RHEL 9) |
| Linux / ARM / 64 bit             | GLIBC 2.34 (Ubuntu 22.04 / Debian 12 / Pi OS bookworm / RHEL 9) |
| macOS / Intel / 64 bit           | macOS 10.15                                                  |
| macOS / ARM / 64 bit             | macOS 11.0                                                   |

Note that in order to be as portable as possible, neither Python nor Guile is enabled in the GDB client. However, you can use TUI (but only for non-Windows builds). 

## Generating a patch

Clone https://sourceware.org/git/binutils-gdb.git

Make changes. Commit. Run git format-patch -1. 

## Acknowledgement

The shell script `avr-gdb-build.sh` is based on [Zak's `avr-gcc-build.sh`](https://github.com/ZakKemble/avr-gcc-build).
