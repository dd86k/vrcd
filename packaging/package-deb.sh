#!/bin/bash
# package-deb.sh: Build Debian (.deb) packages for vrcd client and/or server
# Usage: [DC=COMPILER] ./package-deb.sh [-c COMPILER] [--static] [client|server|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/VERSION")"
ICON="${SCRIPT_DIR}/res/vrcd-logo.png"
MAINTAINER="dd86k <dd@dax.moe>"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

COMPILER=""
TARGET="all"
STATIC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--compiler) COMPILER="$2"; shift 2 ;;
        --compiler=*)  COMPILER="${1#*=}"; shift ;;
        --static) STATIC=1; shift ;;
        client|server|all) TARGET="$1"; shift ;;
        -h|--help)
            sed -n '2,3p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

for tool in dpkg-deb dub; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "error: ${tool} not found in PATH" >&2
        exit 1
    fi
done

DUB_COMPILER_ARG=()
if [[ -n "${COMPILER}" ]]; then
    DUB_COMPILER_ARG=(--compiler="${COMPILER}")
fi

WORKDIR="$(mktemp -d /tmp/vrcd-deb.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

# build_deb <component> <binary-name> <depends> <build-args...>
build_deb() {
    local component="$1"
    local binname="$2"
    local depends="$3"
    shift 3

    local pkgname="vrcd-${component}"
    local binary="${SCRIPT_DIR}/${component}/${binname}"
    local stage="${WORKDIR}/${pkgname}"
    local output="${SCRIPT_DIR}/${pkgname}_${VERSION}_${ARCH}.deb"

    echo "==> Building vrcd ${component} (release)..."
    dub build ":${component}" "$@" "${DUB_COMPILER_ARG[@]}"

    if [[ ! -f "${binary}" ]]; then
        echo "error: expected binary not found: ${binary}" >&2
        exit 1
    fi

    echo "==> Staging ${pkgname} in ${stage}..."
    rm -rf "${stage}"
    mkdir -p "${stage}/DEBIAN" "${stage}/usr/bin"

    install -Dm755 "${binary}" "${stage}/usr/bin/${binname}"

    # Debian policy: every package ships a copyright file under share/doc/<pkg>/
    local docdir="${stage}/usr/share/doc/${pkgname}"
    mkdir -p "${docdir}"
    {
        echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
        echo "Upstream-Name: vrcd"
        echo "Upstream-Contact: ${MAINTAINER}"
        echo "Source: https://github.com/dd86k/vrcd"
        echo
        echo "Files: *"
        echo "Copyright: 2026 dd86k <dd@dax.moe>"
        # In DEP-5, the license body is folded into the License: field as a
        # continuation: every line indented by one space, blank lines as " .".
        # No blank line between "License:" and the body or the stanza breaks.
        echo "License: BSD-3-Clause-Clear"
        sed 's/^$/./; s/^/ /' "${SCRIPT_DIR}/LICENSE"
    } > "${docdir}/copyright"
    chmod 644 "${docdir}/copyright"

    if [[ "${component}" == "client" ]]; then
        install -Dm644 "${ICON}" \
            "${stage}/usr/share/icons/hicolor/256x256/apps/vrcd-client.png"
        mkdir -p "${stage}/usr/share/applications"
        cat > "${stage}/usr/share/applications/vrcd-client.desktop" <<EOF
[Desktop Entry]
Name=vrcd Client
Comment=VRChat event viewer and log watcher
Exec=${binname}
Icon=vrcd-client
Type=Application
Categories=Utility;Network;
EOF
        chmod 644 "${stage}/usr/share/applications/vrcd-client.desktop"
    fi

    local installed_size
    installed_size="$(du -sk "${stage}" | cut -f1)"

    cat > "${stage}/DEBIAN/control" <<EOF
Package: ${pkgname}
Version: ${VERSION}
Section: $( [[ "${component}" == "client" ]] && echo utils || echo net )
Priority: optional
Architecture: ${ARCH}
Depends: ${depends}
Installed-Size: ${installed_size}
Maintainer: ${MAINTAINER}
Homepage: https://github.com/dd86k/vrcd
Description: vrcd ${component} - VRChat companion suite
 vrcd is an application suite for VRChat.
 .
 This package contains the ${component} component.
EOF

    echo "==> Packaging ${output}..."
    dpkg-deb --root-owner-group --build "${stage}" "${output}" >/dev/null

    echo "==> Done: ${output}"
}

case "${TARGET}" in
    client|all)
        build_deb client vrcd_client \
            "libc6, libsdl2-2.0-0, libsdl2-image-2.0-0, libsdl2-ttf-2.0-0, libcurl4" \
            --build=release
        ;;
esac

case "${TARGET}" in
    server|all)
        if [[ "${STATIC}" -eq 1 ]]; then
            # static-release links libcurl/sqlite into the binary, so the only
            # remaining runtime dep is libc.
            build_deb server vrcd_server "libc6" \
                --build=static-release
        else
            build_deb server vrcd_server \
                "libc6, libcurl4, libsqlite3-0" \
                --build=release
        fi
        ;;
esac
