#!/bin/sh
# build-server-static.sh: Build a self-contained vrcd server binary
# Usage: ./build-server-static.sh [-c COMPILER]
set -eu

# POSIX sh rather than bash: the musl build runs inside an Alpine container,
# which ships no bash.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${ROOT}/server/vrcd_server"
COMPILER="ldc2"

while [ $# -gt 0 ]; do
    case "$1" in
    -c|--compiler) COMPILER="$2"; shift 2 ;;
    --compiler=*)  COMPILER="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

for tool in dub pkg-config "${COMPILER}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: ${tool} not found in PATH" >&2
        exit 1
    fi
done

# Which Alpine package carries lib<name>.a. Most are <name>-static, and the
# exceptions are the libraries whose package is not named after the archive.
alpine_package() {
    case "$1" in
    ssl|crypto)                       echo "openssl-libs-static" ;;
    z)                                echo "zlib-static" ;;
    # c-ares ships no -static subpackage, so libcares.a is either in -dev or
    # not packaged at all.
    cares)                            echo "c-ares-dev" ;;
    sqlite3)                          echo "sqlite-static" ;;
    brotlidec|brotlienc|brotlicommon) echo "brotli-static" ;;
    idn2)                             echo "libidn2-static" ;;
    unistring)                        echo "libunistring-static" ;;
    psl)                              echo "libpsl-static" ;;
    *)                                echo "$1-static" ;;
    esac
}

# An archive records no dependencies of its own, so a --static link leaves
# libcurl.a's nghttp2, OpenSSL, c-ares, brotli, zstd, idn2 and psl undefined.
# Only the .pc files know that list, which is what pkg-config is here for.
#
# Only its -l and -L entries may be forwarded. ldc2 hands those two to the
# compiler driver as-is but wraps anything else in -Xlinker, which is how
# `-pthread` reaches ld.bfd, which rejects it outright. Dropping it costs
# nothing on musl, which has no separate libpthread.
#
# -L is how dmd and ldc spell "pass this to the linker"; gdc is not handled.
#
# Run separately rather than inside the loop: pkg-config exits non-zero when a
# Requires.private package has no .pc installed, and a bare $(...) would eat
# that and leave the flags empty, which fails much later as an undefined symbol
# for every library at once. That is the same wall of errors as having no flags
# at all, so the two have to be told apart here.
if ! PKG_LIBS="$(pkg-config --static --libs libcurl sqlite3 2>&1)"; then
    echo "error: pkg-config could not resolve libcurl's dependencies:" >&2
    echo "${PKG_LIBS}" >&2
    echo "hint: each Requires.private entry needs its -dev package for the" >&2
    echo "      .pc, and its -static package for the archive" >&2
    exit 1
fi

FLAGS=""
for lib in ${PKG_LIBS}; do
    case "${lib}" in
    -l*|-L*) FLAGS="${FLAGS} -L${lib}" ;;
    esac
done

if [ -z "${FLAGS}" ]; then
    echo "error: pkg-config named no libraries at all" >&2
    exit 1
fi

# pkg-config answers from the .pc files, which come with the -dev packages, so
# it happily names archives that are not installed: the -static packages are
# separate and nothing pulls them in. Checking here turns a screen of "cannot
# find -lfoo" into the one line that fixes it. This script builds, it does not
# install.
SEARCH_DIRS="/usr/lib /lib /usr/local/lib"
for lib in ${PKG_LIBS}; do
    case "${lib}" in
    -L*) SEARCH_DIRS="${SEARCH_DIRS} ${lib#-L}" ;;
    esac
done

MISSING=""
for lib in ${PKG_LIBS}; do
    case "${lib}" in
    -l*) ;;
    *)   continue ;;
    esac
    name="${lib#-l}"
    for dir in ${SEARCH_DIRS}; do
        if [ -f "${dir}/lib${name}.a" ]; then
            name=""
            break
        fi
    done
    if [ -n "${name}" ]; then
        MISSING="${MISSING} ${name}"
    fi
done

if [ -n "${MISSING}" ]; then
    echo "error: no static archive installed for:${MISSING}" >&2
    if [ -f /etc/alpine-release ]; then
        PACKAGES=""
        for name in ${MISSING}; do
            pkg="$(alpine_package "${name}")"
            case " ${PACKAGES} " in
            *" ${pkg} "*) ;;
            *) PACKAGES="${PACKAGES} ${pkg}" ;;
            esac
        done
        echo "hint: apk add --no-cache${PACKAGES}" >&2
        echo "      or ./packaging/install-deps-alpine.sh for the full set" >&2
    else
        echo "hint: install the static (.a) package for each of those" >&2
    fi
    exit 1
fi

# ld resolves archives in one pass, in command line order: -lssl before
# -lcrypto links and the reverse does not, and the same holds for brotlidec
# against brotlicommon. pkg-config usually emits them in a workable order, but
# it depends on how each .pc was written. A group re-scans until nothing more
# resolves, which makes the order moot for a few extra passes over a handful of
# archives.
FLAGS="-L--start-group ${FLAGS} -L--end-group"

echo "==> Link flags:${FLAGS}"

# dub emits its own -lcurl and -lsqlite3 ahead of DFLAGS, so the dependencies
# land after the archives that need them, which is the order ld wants.
#
# The configuration has to come with the build type: the default one dlopens
# libcurl, which a statically linked binary cannot do, so -b without -c builds
# something that links cleanly and then finds no libcurl at run time.
echo "==> Building vrcd server (static-release, ${COMPILER})..."
cd "${ROOT}"
DFLAGS="${FLAGS}" dub build :server -c static -b static-release \
    --compiler="${COMPILER}"

if [ ! -f "${BINARY}" ]; then
    echo "error: expected binary not found: ${BINARY}" >&2
    exit 1
fi

# A binary that quietly kept a DT_NEEDED entry is the failure worth catching,
# since the whole point is that it runs on a host with no libcurl, no sqlite3
# and no musl.
#
# An interpreter has to be checked separately, because the two are independent:
# a binary can name no libraries at all and still carry a PT_INTERP segment
# pointing at /lib/ld-musl-x86_64.so.1, and that file is musl's libc. Such a
# binary is exactly as unportable as a dynamically linked one, and `file` calls
# it "dynamically linked". A truly static executable has neither, and a static
# PIE has an ELF type of DYN with no interpreter, which is fine.
if command -v readelf >/dev/null 2>&1; then
    if readelf -d "${BINARY}" | grep -q NEEDED; then
        echo "error: ${BINARY} still names shared libraries" >&2
        readelf -d "${BINARY}" | grep NEEDED >&2
        exit 1
    fi
    if readelf -l "${BINARY}" | grep -q INTERP; then
        echo "error: ${BINARY} still requires an interpreter to start" >&2
        readelf -l "${BINARY}" | grep -A1 INTERP >&2
        exit 1
    fi
else
    echo "warning: readelf not found, skipping static link checks" >&2
fi

echo "==> Done: ${BINARY}"
