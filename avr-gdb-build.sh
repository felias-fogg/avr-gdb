#!/bin/bash

NAME_GDB="gdb-${VER_GDB:-17.2}"
NAME_GMP="gmp-6.3.0" # GDB 11+ needs libgmp
NAME_MPFR="mpfr-4.2.2" # GDB 14+ needs libmpfr
NAME_EXPAT=("R_2_7_1" "expat-2.7.1") # GDB XML support

usage()
{
    echo "usage: ./avr-gdb-build <os> <arch>"
    echo "  with <os> one of { windows32, windows64, linux32, linux64, macos }"
    echo "  and  <arch> one of { arm, intel }"
    echo "Note: Only Windows is cross-compiled"
}


# avr-gdb-build
# based on avr-gcc-build modified for generating
# patched statically linked avr-gdb's
# Copyright (C) 2026, Bernhard Nebel
# Copyright (C) 2017-2025, Zak Kemble
# Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)
# http://creativecommons.org/licenses/by-sa/4.0/

if [[ "x$1" != "xwindows32" ]] && [[ "x$1" != "xwindows64" ]] && [[ "x$1" != "xmacos" ]] &&  [[ "x$1" != "xlinux32" ]]  &&  [[ "x$1" != "xlinux64" ]]; then
    usage
    exit 1
fi
if [[ "x$2" != "xarm" ]] && [[ "x$2" != "xintel" ]]; then
    usage
    exit 1
fi

OS=$1
ARCH=$2
CWD=$(pwd)

# Only Windows binaries are cross compiled, but for apple we need
# to specify it nevertheless so that GMP gets compiled right
if [[ $OS == "windows32" ]]; then
    HOST="--host=i686-w64-mingw32"
elif [[ $OS == "windows64" ]]; then
    HOST="--host=x86_64-w64-mingw32"
elif [[ $OS == "macos" ]] && [[ $arch == "intel" ]]; then
    HOST="--host=x86_64-apple-darwin --build=x86_64-apple-darwin"
elif [[ $OS == "macos" ]] && [[ $arch == "arm" ]]; then
    HOST="--host=arm64-apple-darwin --build=arm64-apple-darwin"
fi

# macOS on Intel hardware cannot use the assembly variant in GMP
if [[ $OS == "macos" ]] && [[ $ARCH == "intel" ]]; then
    ASSEMBLY="--disable-assembly"
else
    ASSEMBLY=""
fi

# ++++ Error Handling and Backtracing ++++
set -eE -o functrace

backtrace()
{
    local deptn=${#FUNCNAME[@]}
    local start=${1:-1}
    for ((i=$start; i<$deptn; i++)); do
        local func="${FUNCNAME[$i]}"
        local line="${BASH_LINENO[$((i-1))]}"
        local src="${BASH_SOURCE[$((i-1))]}"
        printf '%*s' $i '' # indent
        echo "at: $func(), $src, line $line"
    done
}

suppressError=0

failure()
{
	[[ $suppressError -ne 0 ]] && return 0
	local lineno=$1
	local msg=$2
	echo "Failed at $lineno: $msg"
	echo "  pwd: $CWD"
	backtrace 2
}

trap 'failure ${LINENO} "$BASH_COMMAND"' ERR
# ---- Erorr Handling and Backtracing ----


JOBCOUNT=${JOBCOUNT:-$(getconf _NPROCESSORS_ONLN)}

# Output locations for built toolchains
BASE=${BASE:-${CWD}/build/}
PREFIX=${BASE}avr-$OS-$ARCH


# Linux is linked against the glibc of the build system, not statically.
#
# A statically linked glibc is not self-contained: NSS (getaddrinfo, getpwuid)
# and gconv (iconv_open, so every charset conversion) load their modules with
# dlopen at run time. Those modules pull in the system's libc.so.6, so a second
# glibc lands in the process, its __libc_early_init runs against thread-local
# storage laid out by the first, and the client dies in __ctype_init. What it
# takes to get there: an ELF file loaded, so that there is a target charset at
# all, then a language set, then any expression evaluated -- the charset is set
# up lazily, so the first evaluation after the change is what calls iconv_open.
# It only appears to work while the build machine and the running machine have
# the same glibc.
#
# Reach comes from building on an old base instead: glibc is backwards
# compatible, so a client built against 2.31 runs on 2.39, never the reverse.
# LINK_STATIC=1 brings the old behaviour back, for comparing the two.
if [[ ${OS:0:5} == "linux" ]] && [[ "${LINK_STATIC:-0}" == "1" ]]; then
    # echo, not log: log() is defined further down in this file, and the
    # script runs with set -e.
    echo "LINK_STATIC=1: linking glibc statically -- see the note above"
    export CFLAGS="-static --static"
    export CXXFLAGS="${CFLAGS}"
fi
# Windows says which version it targets the same way macOS does with a
# deployment target, only through the headers: _WIN32_WINNT decides which API
# functions are visible at all. 0x0600 is Vista, and that is the floor of the
# Windows clients. The linker writes a second number into the PE header, the
# subsystem version, which 'objdump -p' reports.
if [[ ${OS:0:7} == "windows" ]]; then
    export CXXFLAGS="${CXXFLAGS} -D_WIN32_WINNT=0x0600"
fi

# Everything gdb's configure would otherwise decide by looking at what happens
# to be installed on the build machine. Pinned here, so that two machines give
# the same binary: the ARM client came out without debuginfod only because that
# host did not have the library, not because anybody chose it.
#
# Most of the list pins what the clients already are: the configuration gdb
# carries for 'show configuration' reports --without-lzma, --without-xxhash,
# --without-babeltrace, --without-debuginfod and --disable-source-highlight.
#
# --enable-tui is the one deliberate change, and the reason is that curses
# cannot be refused. --without-curses looks like a switch but is only a
# preference: configure treats it exactly like not passing it, and then looks
# for curses anyway, because Readline needs termcap. So on a machine that has
# ncurses the library gets linked either way. The ARM client reports
# --without-curses because that build host had none, not because it was asked
# for. Given that the dependency is there regardless, refusing the TUI would
# cost a feature and save nothing; asking for it also makes a missing curses a
# failed configure rather than a client quietly built without it.
#
# --without-libiconv-prefix means gdb uses glibc's iconv. That is what loads
# gconv/ISO8859-1.so through dlopen, which is fatal in a statically linked
# binary whose glibc differs from the one on the running system. It is spelled
# out here so the trap is visible rather than implied.
OPTS_GDB="
	--target=avr
	--with-static-standard-libraries
	--with-expat
	--enable-tui
	--without-python
	--without-guile
	--without-debuginfod
	--without-xxhash
	--without-lzma
	--without-zstd
	--without-babeltrace
	--disable-source-highlight
	--without-libiconv-prefix
"

# Two cases where the TUI has to go, both because it needs curses and curses is
# not there. Asking for it anyway is a failed configure, which is the right
# behaviour and the wrong moment.
#
#  - Windows: the cross build installs mingw-w64 and no curses for it. Until
#    that changes, the Windows clients have no TUI -- as they never had, only
#    now it is said out loud instead of happening quietly.
#
# On Linux the answer is the other way round: libncurses-dev is in the package
# list now. Asking for the TUI without asking for its library worked only on
# machines that happened to have it -- a GitHub runner does, a Raspberry Pi OS
# lite image does not. Pinning an option is half of the job; the other half is
# requiring what it needs.
#  - LINK_STATIC=1: a static link needs a static curses, which the build machine
#    may not have. That comparison is about glibc, not about the TUI.
if [[ ${OS:0:7} == "windows" ]] || [[ "${LINK_STATIC:-0}" == "1" ]]; then
    OPTS_GDB="${OPTS_GDB//--enable-tui/--disable-tui}"
fi

# macOS takes the system zlib; everywhere else the one in the source tree.
if [[ $OS == "macos" ]]; then
    OPTS_GDB="${OPTS_GDB}
	--with-system-zlib
"
fi

TMP_DIR=${CWD}/tmp
LOG_DIR=${CWD}

log()
{
	echo "$1"
	echo "[$(date +"%d %b %y %H:%M:%S")]: $1" >> "$LOG_DIR/avr-gdb-build.log"
}

installPackages()
{
        if [[ $OS == "linux32" ]] && [[ $ARCH == "intel" ]]; then
            if  [[ $EUID -ne 0 ]]; then
                echo "ERROR: Need to run as root to switch architecture"
                exit 2
            else
                dpkg --add-architecture i386
            fi
        fi
        if [[ ${OS:0:7} == "windows" ]]; then
            local required=("build-essential" "m4" "ca-certificates" "wget" "make" "mingw-w64" "bzip2" "xz-utils" "autoconf" "texinfo")
        elif [[ $OS == "linux64"  || ( $OS == "linux32" && $ARCH == "arm" ) ]]; then
            local required=("build-essential" "m4" "ca-certificates" "wget" "make" "bzip2" "xz-utils" "autoconf" "texinfo" "libncurses-dev" "libgmp-dev" "libmpfr-dev")
        elif [[ $OS == "linux32" &&  $ARCH == "intel" ]]; then
            local required=("libstdc++6:i386" "libgcc1:i386" "zlib1g:i386" "libncurses5:i386" "gcc-11:i386" "g++-11:i386" "binutils:i386" "cpp-11:i386" "libelf-dev:i386" "freeglut3-dev:i386" "gcc-avr" "avr-libc"  "m4" "wget" "make" "bzip2" "xz-utils" "autoconf" "texinfo" "libncurses-dev:i386" "libgmp-dev:i386" "libmpfr-dev:i386" )
        else
            local required=( "texinfo" )
        fi
	if [[ $EUID -ne 0 ]] && [[ $OS != "macos" ]]; then
		log "Not running as root user. Checking whether all required packages are installed..."
		local packageMissing=0
		for package in "${required[@]}"
		do
			if ! dpkg -s "$package" > /dev/null 2>&1; then
				echo "ERROR: Package \"$package\" is not installed. But it is required." 1>&2
				packageMissing=1
			fi
		done

		if [[ $packageMissing -ne 0 ]]; then
			echo "Not all required packages are installed. You need to install them manually or run the script with root (sudo)" 1>&2
			exit 2
		fi

		echo "All required packages are installed. Continuing..."
	elif [[ $OS != "macos" ]]; then
		log "Running as root user. Installing required packages via apt..."
		apt update
		apt install -y "${required[@]}"
        elif hash brew 2>/dev/null; then
	    for package in "${required[@]}"
	    do
                brew list $package || brew install $package
	    done
        else
            echo "You need to install Homebrew first"
            exit 2
	fi
        if [[ $OS == "linux32" ]] && [[ $ARCH == "intel" ]]; then
            echo "update-alternatives ..."
            ls -l /usr/bin/*gcc*
            update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 10
            update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 20
            update-alternatives --install /usr/bin/cc cc /usr/bin/gcc 30
            update-alternatives --set cc /usr/bin/gcc
            ls -l /usr/bin/*g++*
            update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 10
            update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 20
            update-alternatives --install /usr/bin/cxx cxx /usr/bin/g++ 30
            update-alternatives --set cxx /usr/bin/g++
        fi
}

makeDir()
{
	rm -rf "$1/"
	mkdir -p "$1"
}

cleanup()
{
	log "Clearing output directories..."
	makeDir "$PREFIX"

	log "Clearing old download directories..."
        makeDir "$PREFIX"
        rm -rf $TMP_DIR
	#rm -f $NAME_GDB.tar.xz
	rm -rf $NAME_GDB
	#rm -f $NAME_GMP.tar.xz
	rm -rf $NAME_GMP
	#rm -f $NAME_MPFR.tar.xz
	rm -rf $NAME_MPFR
	#rm -f ${NAME_EXPAT[1]}.tar.xz
	rm -rf ${NAME_EXPAT[1]}
}

genManifest()
{
         if [[ $OS == "linux64" && $ARCH == "arm" ]]; then
             SYSTEM="linux_aarch64"
         elif [[ $OS == "linux32" && $ARCH == "arm" ]]; then
             SYSTEM="linux_armv6l"
         elif [[ $OS == "macos" &&  $ARCH == "arm" ]]; then
             SYSTEM="darwin_arm64"
         elif [[ $OS == "linux32" && $ARCH == "intel" ]]; then
             SYSTEM="linux_i686"
         elif [[ $OS == "windows32" && $ARCH == "intel" ]]; then
             SYSTEM="windows_x86"
         elif [[ $OS == "macos" && $ARCH == "intel" ]]; then
             SYSTEM="darwin_x86_64"
         elif [[ $OS == "linux64" && $ARCH == "intel" ]]; then
             SYSTEM="linux_x86_64"
         elif [[ $OS == "windows64" && $ARCH == "intel" ]]; then
             SYSTEM="windows_amd64"
         else
             echo "Unknown platform"
             exit 2
         fi
         cat <<EOF >${PREFIX}/package.json
{
  "name": "tool-avr-gdb",
  "version": "$(head -n 1 VERSION)",
  "description": "GNU Project Debugger cross-compiled for the Microchip AVR microcontroller architecture",
  "keywords": [
    "tools",
    "debugger",
    "microchip",
    "avr"
  ],
  "license": "GPL-3.0-or-later",
  "system": [
    "${SYSTEM}"
  ],
  "repository": {
    "type": "git",
    "url": "https://sourceware.org/git/binutils-gdb"
  }
}
EOF

}

downloadSources()
{
        
	log "Downloading sources..."
	log "$NAME_GDB"
        if [ ! -f $NAME_GDB.tar.xz ]; then 
	    wget https://ftpmirror.gnu.org/gdb/$NAME_GDB.tar.xz
        fi
	# Only the cross targets build GMP and MPFR from source; on Linux we take the
	# static archives the distribution ships. See buildGDB.
	if [[ ${OS:0:5} != "linux" ]]; then
	    log "$NAME_GMP"
            if [ ! -f $NAME_GMP.tar.xz ]; then
	        wget https://ftpmirror.gnu.org/gmp/$NAME_GMP.tar.xz
            fi
	    log "$NAME_MPFR"
            if [ ! -f $NAME_MPFR.tar.xz ]; then
	        wget https://ftpmirror.gnu.org/mpfr/$NAME_MPFR.tar.xz
            fi
	fi
	log "${NAME_EXPAT[1]}"
        if [ ! -f  ${NAME_EXPAT[1]}.tar.xz ]; then
	    wget https://github.com/libexpat/libexpat/releases/download/${NAME_EXPAT[0]}/${NAME_EXPAT[1]}.tar.xz
        fi
}

confMake()
{
        # $3 is the host (possibly empty), $4 the path to a config.guess. An
        # empty unquoted $3 at the call site shifts $4 into its place, and
        # configure then reads a file name as a host type and says so in a way
        # that takes a while to understand. Cheaper to say it here.
        if [[ -n "$3" ]] && [[ ${3:0:2} != "--" ]]; then
            log "confMake: '$3' is not a configure option -- quote \$HOST at the call site"
            exit 2
        fi
        if [[ -z "$4" ]]; then
            echo "$1 $2 $3"
            ../configure --prefix=$1 $2 $3
        else
	    ../configure --prefix=$1 $2 $3 --build=`${4:-../config.guess}`
        fi
	make -j $JOBCOUNT
	make install-strip
	rm -rf *
}

# Takes the static archive out of a distribution -dev package and puts it where
# gdb will look for it. The copy is the whole point: in one directory the linker
# prefers lib*.so over lib*.a, and /usr/lib holds both, so -lgmp would quietly
# pick up the shared library. In a directory that holds only the archive it has
# no choice. Asking the compiler for the path keeps this independent of the
# architecture's multiarch directory.
collectStaticLib()
{
	local archive
	archive=$(gcc -print-file-name=lib$1.a)
	if [[ "$archive" == "lib$1.a" ]]; then
		log "no static lib$1.a on this system -- is lib$1-dev installed?"
		exit 2
	fi
	log "lib$1.a from $archive"
	cp "$archive" $TMP_DIR/$OS-$ARCH/lib/
}

patchGDB()
{
	log "Extracting GDB ..."
	tar xf $NAME_GDB.tar.xz
        log "Patching..."
        cp -f VERSION $NAME_GDB/gdb/version.in
        cd $NAME_GDB
        for f in ../*.patch
        do
            patch -p 1 < $f
        done
        cd ..
}

buildGDB()
{
	log "***GDB, with GMP, MPFR and Expat linked in statically***"
	mkdir -p $NAME_GDB/obj-avr
	mkdir -p $TMP_DIR/$OS-$ARCH/lib

	# None of the three may end up as a shared library the user has to have:
	# libmpfr.so.6 in particular is missing on a minimal system. Curses is the
	# one exception -- the TUI needs it, it is not built here, and it is there
	# wherever there is a terminal.
	#
	# Where the three come from differs. Expat is built from source everywhere:
	# it is the only one of them that parses input, so its version should be
	# ours and the same on all platforms, not whatever the build machine had.
	# GMP and MPFR are pure arithmetic with a stable ABI, so on Linux the
	# distribution's own static archives will do -- which saves building GMP,
	# and in the emulated arm job that is the expensive step. The cross targets
	# have no such archives and build all three.
	log "Extracting libs ..."
	tar xf ${NAME_EXPAT[1]}.tar.xz
	mkdir -p ${NAME_EXPAT[1]}/obj
	if [[ ${OS:0:5} != "linux" ]]; then
		tar xf $NAME_GMP.tar.xz
		mkdir -p $NAME_GMP/obj
		tar xf $NAME_MPFR.tar.xz
		mkdir -p $NAME_MPFR/obj
	fi

	if [[ ${OS:0:5} == "linux" ]]; then
		log "GMP and MPFR (static archives from the distribution)..."
		collectStaticLib gmp
		collectStaticLib mpfr
		# Only the library directory is ours; the headers stay where the
		# distribution put them, which is what --with-*-lib is for.
		OPTS_LIBS="--with-gmp-lib=${TMP_DIR}/${OS}-${ARCH}/lib --with-mpfr-lib=${TMP_DIR}/${OS}-${ARCH}/lib"
	else
		log "GMP..."
		cd $NAME_GMP/obj
		confMake $TMP_DIR/$OS-$ARCH "--enable-static --disable-shared ${ASSEMBLY}" $HOST
		cd ../../

		log "MPFR..."
		cd $NAME_MPFR/obj
		confMake $TMP_DIR/$OS-$ARCH "--with-gmp=${TMP_DIR}/${OS}-${ARCH} --disable-shared --enable-static" $HOST
		cd ../../

		OPTS_LIBS="--with-gmp=${TMP_DIR}/${OS}-${ARCH} --with-mpfr=${TMP_DIR}/${OS}-${ARCH}"
	fi

	log "Expat..."
	cd ${NAME_EXPAT[1]}/obj
	# --build is only of interest where we cross-compile; a native build finds
	# out by itself. And it has to be passed as the fourth argument, so $HOST
	# must be quoted: empty and unquoted it disappears, and then the path to
	# config.guess slides into its place and configure reads it as a host type.
	if [[ ${OS:0:5} == "linux" ]] || [[ $OS == "macos" ]]; then
	    confMake $TMP_DIR/$OS-$ARCH "--disable-shared --enable-static" "$HOST"
	else
	    confMake $TMP_DIR/$OS-$ARCH "--disable-shared --enable-static" "$HOST" "../conftools/config.guess"
	fi
	cd ../../

	if [[ $OS == "macos" ]]; then
	    brew uninstall --ignore-dependencies zstd || echo "OK"
	    brew uninstall --ignore-dependencies gettext || echo "OK"
	    brew uninstall --ignore-dependencies xz || echo "OK"
	fi

	log "GDB..."
	cd $NAME_GDB/obj-avr
	confMake "$PREFIX" "--enable-static --disable-shared ${OPTS_LIBS} --with-libexpat-prefix=${TMP_DIR}/${OS}-${ARCH} ${OPTS_GDB}" $HOST
	cd ../../

	# For some reason we need some random command here otherwise
	# the script exits with no error when FOR_WINX64=0
	echo "" > /dev/null
}

installPackages

log "Start"

export PATH="$PREFIX/bin:$PATH"
export CC=""

cleanup
downloadSources
patchGDB
buildGDB
genManifest

exit 0

