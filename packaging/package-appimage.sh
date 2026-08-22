#!/bin/bash
# package-appimage.sh: Build and package vrcd client as an AppImage
# Usage: [DC=COMPILER] ./package-appimage.sh [-c COMPILER]
# Needs: appimagetool, linuxdeploy, and the SDL3 development libraries
#        (libsdl3-dev, libsdl3-ttf-dev, libsdl3-image-dev)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/VERSION")"
BINARY="${SCRIPT_DIR}/client/vrcd_client"
OUTPUT="${SCRIPT_DIR}/vrcd-client-${VERSION}-x86_64.AppImage"
ICON="${SCRIPT_DIR}/res/vrcd-logo.png"
# Windows build of the :pipehelper subpackage ("Open in VRChat" IPC on
# Linux). Built separately on Windows; bundled when present.
PIPEHELPER_EXE="${PIPEHELPER_EXE:-${SCRIPT_DIR}/pipehelper/vrcd-pipehelper.exe}"

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

echo "==> Building vrcd client (release, static configuration)..."
DUB_COMPILER_ARG=()
if [[ -n "${COMPILER}" ]]; then
    DUB_COMPILER_ARG=(--compiler="${COMPILER}")
    echo "    compiler: ${COMPILER}"
fi
# The "static" configuration is what makes an AppImage of this buildable at
# all: bindbc-sdl binds SDL3 at link time, so libSDL3, libSDL3_ttf, and
# libSDL3_image become DT_NEEDED entries that linuxdeploy resolves and bundles
# on its own, along with what they in turn need. Under the default
# configuration they are dlopen'd, invisible to ldd, and every one of them
# (and every transitive dependency) has to be named by hand.
#
# Needs the SDL3 development libraries on the build host:
#   apt install libsdl3-dev libsdl3-ttf-dev libsdl3-image-dev
dub build :client -c static --build=release "${DUB_COMPILER_ARG[@]}"

echo "==> Creating AppDir in ${WORKDIR}..."
mkdir -p "${APPDIR}/usr/bin"

cp "${BINARY}" "${APPDIR}/usr/bin/vrcd_client"

# Bundle the pipe helper away from usr/bin, and let AppRun install it to
# ~/.config/vrcd/ where the client's fallback lookup finds it: the AppImage
# mount is a fresh directory under /tmp on every run, so a copy in the mount
# is not something anything else can be pointed at.
if [[ -f "${PIPEHELPER_EXE}" ]]; then
    mkdir -p "${APPDIR}/usr/share/vrcd"
    cp "${PIPEHELPER_EXE}" "${APPDIR}/usr/share/vrcd/vrcd-pipehelper.exe"
else
    echo "warning: ${PIPEHELPER_EXE} not found (set PIPEHELPER_EXE=...)," >&2
    echo "         \"Open in VRChat\" IPC will fall back to self-invite" >&2
fi

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

echo "==> Bundling libraries with linuxdeploy..."
run_tool linuxdeploy \
    --appdir "${APPDIR}" \
    --executable "${APPDIR}/usr/bin/vrcd_client" \
    --desktop-file "${APPDIR}/vrcd-client.desktop" \
    --icon-file "${APPDIR}/vrcd-client.png"

# Fail loudly rather than shipping an AppImage that dies on a missing SDL3:
# linuxdeploy reports a library it could not deploy as a warning and carries on.
for lib in libSDL3 libSDL3_ttf libSDL3_image; do
    if ! compgen -G "${APPDIR}/usr/lib/${lib}.so*" >/dev/null; then
        echo "error: ${lib} was not bundled into the AppDir" >&2
        exit 1
    fi
done

# AppRun, written after linuxdeploy: it leaves an existing AppRun alone but
# creates one as a symlink to the executable when there is none, and writing
# through that symlink would overwrite the binary.
#
# Nothing sets LD_LIBRARY_PATH here. linuxdeploy patches the RPATH of what it
# deploys to $ORIGIN/../lib, so the bundle is found without it, and the client
# spawns processes that belong to the host (notify-send, and Proton's own wine
# under the game's prefix for "Open in VRChat") -- those inherit the
# environment, and a bundled library ahead of the system one is how they break.
rm -f "${APPDIR}/AppRun"
cat > "${APPDIR}/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
# Install/refresh the "Open in VRChat" pipe helper at a stable path (the
# AppImage mount itself is a new /tmp directory on every run).
HELPER="${HERE}/usr/share/vrcd/vrcd-pipehelper.exe"
# Matches the client's vrcdConfigPath, which hardcodes ~/.config.
CONFDIR="${HOME}/.config/vrcd"
if [[ -f "${HELPER}" ]] && ! cmp -s "${HELPER}" "${CONFDIR}/vrcd-pipehelper.exe"; then
    mkdir -p "${CONFDIR}" && cp "${HELPER}" "${CONFDIR}/vrcd-pipehelper.exe" || true
fi
exec "${HERE}/usr/bin/vrcd_client" "$@"
EOF
chmod +x "${APPDIR}/AppRun"

echo "==> Packaging AppImage..."
ARCH=x86_64 run_tool appimagetool "${APPDIR}" "${WORKDIR}/out.AppImage"

echo "==> Copying result to ${OUTPUT}..."
cp "${WORKDIR}/out.AppImage" "${OUTPUT}"

echo "==> Done: ${OUTPUT}"
