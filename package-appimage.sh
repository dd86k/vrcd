#!/bin/bash
# package-appimage.sh: Build and package vrcd client as an AppImage
# Usage: [DC=COMPILER] ./package-appimage.sh [-c COMPILER]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/VERSION")"
BINARY="${SCRIPT_DIR}/client/vrcd_client"
OUTPUT="${SCRIPT_DIR}/vrcd-client-${VERSION}-x86_64.AppImage"
ICON="${SCRIPT_DIR}/res/vrcd-logo.png"

# CLI flag for compiler; env var DC is also respected natively by dub
COMPILER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--compiler) COMPILER="$2"; shift 2 ;;
        --compiler=*)  COMPILER="${1#*=}"; shift ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Check for required tools
for tool in appimagetool linuxdeploy; do
    if ! command -v "${tool}" &>/dev/null && ! command -v "${tool}-x86_64.AppImage" &>/dev/null; then
        echo "error: ${tool} not found in PATH (or as ${tool}-x86_64.AppImage)" >&2
        echo "  appimagetool: https://github.com/AppImage/AppImageKit/releases" >&2
        echo "  linuxdeploy:  https://github.com/linuxdeploy/linuxdeploy/releases" >&2
        exit 1
    fi
done

run_tool() {
    local name="$1"; shift
    if command -v "${name}" &>/dev/null; then
        "${name}" "$@"
    else
        "${name}-x86_64.AppImage" "$@"
    fi
}

# Work entirely in /tmp to avoid vboxsf symlink restrictions
WORKDIR="$(mktemp -d /tmp/vrcd-appimage.XXXXXX)"
APPDIR="${WORKDIR}/vrcd-client.AppDir"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> Building vrcd client (release)..."
DUB_COMPILER_ARG=()
if [[ -n "${COMPILER}" ]]; then
    DUB_COMPILER_ARG=(--compiler="${COMPILER}")
    echo "    compiler: ${COMPILER}"
fi
dub build :client --build=release "${DUB_COMPILER_ARG[@]}"

echo "==> Creating AppDir in ${WORKDIR}..."
mkdir -p "${APPDIR}/usr/bin"

cp "${BINARY}" "${APPDIR}/usr/bin/vrcd_client"

# Desktop entry
cat > "${APPDIR}/vrcd-client.desktop" <<EOF
[Desktop Entry]
Name=vrcd Client
Exec=vrcd_client
Icon=vrcd-client
Type=Application
Categories=Utility;
EOF

# Icon (linuxdeploy expects it named to match Icon= field)
cp "${ICON}" "${APPDIR}/vrcd-client.png"

# AppRun
cat > "${APPDIR}/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH:-}"
exec "${HERE}/usr/bin/vrcd_client" "$@"
EOF
chmod +x "${APPDIR}/AppRun"

# SDL2 libs are dlopen'd by bindbc-sdl so ldd won't find them.
# Locate them via ldconfig and pass explicitly to linuxdeploy.
# These work best on an Ubuntu 24.04 host, sorry!
SDL_LIB_ARGS=()
for lib in libSDL2-2.0 libSDL2_ttf-2.0 libSDL2_image-2.0; do
    path="$(ldconfig -p | awk -v l="${lib}.so" '$1 ~ l { print $NF; exit }')"
    if [[ -z "${path}" ]]; then
        echo "warning: ${lib} not found via ldconfig, AppImage may not run" >&2
    else
        SDL_LIB_ARGS+=(--library "${path}")
    fi
done

echo "==> Bundling libraries with linuxdeploy..."
run_tool linuxdeploy \
    --appdir "${APPDIR}" \
    --executable "${APPDIR}/usr/bin/vrcd_client" \
    --desktop-file "${APPDIR}/vrcd-client.desktop" \
    --icon-file "${APPDIR}/vrcd-client.png" \
    "${SDL_LIB_ARGS[@]}"

echo "==> Packaging AppImage..."
ARCH=x86_64 run_tool appimagetool "${APPDIR}" "${WORKDIR}/out.AppImage"

echo "==> Copying result to ${OUTPUT}..."
cp "${WORKDIR}/out.AppImage" "${OUTPUT}"

echo "==> Done: ${OUTPUT}"
