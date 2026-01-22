#!/bin/bash

usage()
{
    echo "usage: ./avr-gdb-build <os> <arch>"
    echo "  with <os> one of { windows32, windows64, macos, linux }"
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

if [[ "x$1" != "xwindows32" ]] && [[ "x$1" != "xwindows64" ]] && [[ "x$1" != "xmacos" ]] &&  [[ "x$1" != "xlinux" ]]; then
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
# to specify it nevertheless so that GMP get compiled right
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

NAME_GDB="gdb-${VER_GDB:-17.1}"
NAME_GMP="gmp-6.3.0" # GDB 11+ needs libgmp
NAME_MPFR="mpfr-4.2.2" # GDB 14+ needs libmpfr
NAME_EXPAT=("R_2_7_1" "expat-2.7.1") # GDB XML support

# Output locations for built toolchains
BASE=${BASE:-${CWD}/build/}
PREFIX=${BASE}avr-$OS-$ARCH

# Uncomment the next 2 export lines to get a fully static build (under Linux)
if [[ $OS == "linux" ]]; then
    export CFLAGS="-static --static"
    export CXXFLAGS="${CFLAGS}"
fi
export CXXFLAGS="${CXXFLAGS} -D_WIN32_WINNT=0x0600"

OPTS_GDB="
	--target=avr
	--with-static-standard-libraries
	--with-expat
        --without-python
        --without-guile
        --with-static-standard-libraries
"
# --disable-source-highlight

TMP_DIR=${CWD}/tmp
LOG_DIR=${CWD}

log()
{
	echo "$1"
	echo "[$(date +"%d %b %y %H:%M:%S")]: $1" >> "$LOG_DIR/avr-gdb-build.log"
}

installPackages()
{
        if [[ $OS == "windows32" ]] || [[ $OS == "windows64" ]]; then
            local required=("wget" "make" "mingw-w64" "bzip2" "xz-utils" "autoconf" "texinfo" "libgmp-dev" "libmpfr-dev" "libexpat1-dev")
        elif [[ $OS == "linux" ]]; then
            local required=("wget" "make" "bzip2" "xz-utils" "autoconf" "texinfo" "libgmp-dev" "libmpfr-dev" "libexpat1-dev")
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
		apt install "${required[@]}"
        elif hash brew 2>/dev/null; then
                brew install "${required[@]}"
        else
                echo "You need to install Homebrew first"
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

downloadSources()
{
        
	log "Downloading sources..."
	log "$NAME_GDB"
        if [ ! -f $NAME_GDB.tar.xz ]; then 
	    wget https://ftpmirror.gnu.org/gdb/$NAME_GDB.tar.xz
        fi
	if [[ $OS != "linux"  ]]; then
	        log "$NAME_GMP"
                if [ ! -f $NAME_GMP.tar.xz ]; then 
		    wget https://ftpmirror.gnu.org/gmp/$NAME_GMP.tar.xz
                fi
		log "$NAME_MPFR"
                if [ ! -f $NAME_MPFR.tar.xz ]; then
		    wget https://ftpmirror.gnu.org/mpfr/$NAME_MPFR.tar.xz
                fi
		log "${NAME_EXPAT[1]}"
                if [ ! -f  ${NAME_EXPAT[1]}.tar.xz ]; then
		    wget https://github.com/libexpat/libexpat/releases/download/${NAME_EXPAT[0]}/${NAME_EXPAT[1]}.tar.xz
                fi
	fi
}

confMake()
{
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
	log "***GDB (and GMP, MPFR, Expat for Windows/macOS)***"
	mkdir -p $NAME_GDB/obj-avr
	if [[ $OS == "windows32" ]] || [[ $OS == "windows64" ]] || [[ $OS == "macos" ]]; then
            	log "Extracting libs ..."
		tar xf $NAME_GMP.tar.xz
		mkdir -p $NAME_GMP/obj
		tar xf $NAME_MPFR.tar.xz
		mkdir -p $NAME_MPFR/obj
		tar xf ${NAME_EXPAT[1]}.tar.xz
		mkdir -p ${NAME_EXPAT[1]}/obj
	fi

	if [[ $OS == "linux" ]]; then
		log "Making for Linux..."
		cd $NAME_GDB/obj-avr
		confMake "$PREFIX" "$OPTS_GDB"
		cd ../../
	else
		log "GMP..."
		cd $NAME_GMP/obj
		confMake $TMP_DIR/$OS-$ARCH "--enable-static --disable-shared ${ASSEMBLY}" $HOST
		cd ../../
		
		log "MPFR..."
		cd $NAME_MPFR/obj
		confMake $TMP_DIR/$OS-$ARCH "--with-gmp=${TMP_DIR}/${OS}-${ARCH} --disable-shared --enable-static" $HOST
		cd ../../

		log "Expat..."
		cd ${NAME_EXPAT[1]}/obj
                if [[ $OS == "macos" ]]; then 
		    confMake $TMP_DIR/$OS-$ARCH "--disable-shared --enable-static" $HOST
                else
		    confMake $TMP_DIR/$OS-$ARCH "--disable-shared --enable-static" $HOST "../conftools/config.guess"
                fi
		cd ../../


		log "GDB..."
		cd $NAME_GDB/obj-avr
		confMake "$PREFIX" "--enable-static --disable-shared --with-gmp=${TMP_DIR}/${OS}-${ARCH} --with-mpfr=${TMP_DIR}/${OS}-${ARCH} --with-libexpat-prefix=${TMP_DIR}/${OS}-${ARCH} ${OPTS_GDB}" $HOST
		cd ../../
	fi

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

exit 0

