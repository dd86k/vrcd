#!/bin/sh
# install-deps-alpine.sh: Install what a static vrcd server build needs on Alpine
# Usage: ./install-deps-alpine.sh
set -eu

# POSIX sh rather than bash: Alpine ships none.

if [ ! -f /etc/alpine-release ]; then
    echo "error: this installs Alpine packages and this is not Alpine" >&2
    exit 1
fi

APK="apk"
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        APK="sudo apk"
    else
        echo "error: apk needs root, and sudo is not installed" >&2
        exit 1
    fi
fi

# Every library below is needed twice over: the .a from its -static package,
# and the .pc from its -dev one.
#
# The .pc files are not optional extras. libcurl.pc names its dependencies as
# Requires.private, and pkg-config can only turn those names into -l flags by
# reading each named package's own .pc. Without libbrotlidec.pc, for one,
# nothing ever mentions libbrotlicommon.a, which is where half of brotlidec's
# symbols live.
#
# c-ares is the exception with no -static subpackage at all, so only its -dev
# is listed. Naming a package Alpine does not have fails the whole apk
# transaction, not just that one name, so nothing is listed here on spec.
# Whether libcares.a arrives with c-ares-dev is what build-server-static.sh
# reports, and libcurl.a does reference ares_ symbols.
#
# ldc-static is LDC's own runtime as archives, and git is here because dub
# fetches ddlogger and ddcurl as git dependencies.
echo "==> Installing build dependencies..."
${APK} add --no-cache \
    git ldc ldc-static dub gcc musl-dev binutils pkgconf \
    curl-dev sqlite-dev nghttp2-dev openssl-dev brotli-dev \
    zstd-dev zlib-dev libidn2-dev libpsl-dev c-ares-dev \
    curl-static sqlite-static openssl-libs-static zlib-static \
    nghttp2-static brotli-static zstd-static \
    libidn2-static libunistring-static libpsl-static

echo "==> Done. Build with: ./packaging/build-server-static.sh"
