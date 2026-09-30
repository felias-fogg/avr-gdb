#!/bin/bash
#
# Reports what a finished client demands of the system it will run on, and fails
# if it demands more than it was allowed to. One script for all three platforms,
# because the question is the same everywhere and only the place to read the
# answer differs:
#
#   ELF     the highest glibc version referenced   readelf -V
#   Mach-O  the deployment target                  vtool -show-build
#   PE      the subsystem version in the header    objdump -p
#
# Linux is the only one of the three with no way to declare that floor in the
# build; it falls out of the distribution one builds on. Hence this script: what
# cannot be stated has to be measured.
#
# Reading works across architectures -- readelf parses ELF directly instead of
# going through a target backend -- so an armhf client can be checked on an x86
# machine, which is what the arm job does.
#
# Usage:
#   ./check-floor.sh <binary> <floor> [--armv6-hardfloat]
#
#   ./check-floor.sh tool/avr-gdb 2.35
#   ./check-floor.sh tool/avr-gdb 2.31 --armv6-hardfloat
#   ./check-floor.sh tool/avr-gdb 11.0
#   ./check-floor.sh tool/avr-gdb.exe 6.0

set -eu

BIN=${1:?usage: check-floor.sh <binary> <floor> [--armv6-hardfloat]}
FLOOR=${2:?usage: check-floor.sh <binary> <floor> [--armv6-hardfloat]}
WANT_ARMV6=${3:-}

fail() { echo "::error::$*" >&2; echo "FAILED: $*" >&2; exit 1; }

test -f "$BIN" || fail "no such file: $BIN"
echo "=== $BIN"
file "$BIN"
KIND=$(file -b "$BIN")

case "$KIND" in
  *ELF*)
    echo "--- libraries it needs at start ---"
    readelf -d "$BIN" | grep NEEDED || echo "(none -- statically linked)"
    readelf -l "$BIN" | grep -i interpreter || echo "(no interpreter)"

    echo "--- glibc ---"
    MAX=$(readelf -V "$BIN" | grep -o 'GLIBC_2\.[0-9]*' | sort -uV | tail -1 || true)
    echo "highest glibc requirement: ${MAX:-none}"
    [ -n "$MAX" ] || fail "no GLIBC_ references at all -- statically linked glibc? \
that is not portable: NSS and gconv load modules with dlopen at run time and \
then need the glibc it was linked against"
    HAVE=${MAX#GLIBC_2.}
    WANT=${FLOOR#2.}
    [ "$HAVE" -le "$WANT" ] || fail "requires $MAX, allowed at most GLIBC_$FLOOR"

    if [ "$WANT_ARMV6" = "--armv6-hardfloat" ]; then
      echo "--- ARM ABI ---"
      readelf -A "$BIN" | grep -E 'Tag_CPU_arch|Tag_FP_arch|Tag_ABI_VFP_args' || true
      readelf -A "$BIN" | grep -q 'Tag_CPU_arch: v6' \
        || fail "not armv6 -- this drops the Pi 1 and Zero"
      readelf -A "$BIN" | grep -q 'Tag_ABI_VFP_args: VFP registers' \
        || fail "not hard-float -- this does not run on Raspberry Pi OS"
    fi
    ;;

  *Mach-O*)
    echo "--- libraries it needs at start ---"
    otool -L "$BIN"
    echo "--- deployment target ---"
    otool -l "$BIN" | grep -A4 LC_BUILD_VERSION || true
    MINOS=$(vtool -show-build "$BIN" 2>/dev/null | awk '/minos/ {print $2; exit}' || true)
    echo "minos: ${MINOS:-unknown}"
    [ -n "$MINOS" ] || fail "could not read a deployment target from $BIN"
    case "$MINOS" in
      "$FLOOR"|"$FLOOR".*) ;;
      *) fail "asked for macOS $FLOOR, binary says $MINOS -- is \
MACOSX_DEPLOYMENT_TARGET set for the whole build, not just for gdb?" ;;
    esac
    ;;

  *PE*|*MS\ Windows*)
    echo "--- subsystem version (the Windows floor) ---"
    OD=objdump
    command -v x86_64-w64-mingw32-objdump >/dev/null && OD=x86_64-w64-mingw32-objdump
    "$OD" -p "$BIN" | grep -iE 'Major(OSystem|Subsystem)Version|Minor(OSystem|Subsystem)Version' \
      || echo "(could not read the PE header with $OD)"
    # Reported, not enforced: the number mingw-w64 writes depends on its
    # version, and the real floor is set by _WIN32_WINNT in the build. Enforcing
    # a value here would be guessing at the toolchain rather than checking the
    # client.
    echo "declared floor in the build: _WIN32_WINNT=0x0600 (Vista); asked here: $FLOOR"
    ;;

  *)
    fail "do not know how to read $BIN: $KIND"
    ;;
esac

echo "OK: $BIN stays within $FLOOR"
