#!/usr/bin/env bash
# Cross-build vrcd-pipehelper.exe (Windows x86_64) from Linux with LDC and
# lld-link. No Windows SDK or LDC Windows package needed: import libraries
# are generated from the export lists below.
#
# Usage: pipehelper/build.sh [output.exe]
# Env: LDC (default ldc2), LLD_LINK (default lld-link, then lld-link-NN)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${SRC_DIR}/vrcd-pipehelper.exe}"
LDC="${LDC:-ldc2}"

if [[ -z "${LLD_LINK:-}" ]]; then
    LLD_LINK="$(compgen -c lld-link | sort -V | tail -1)"
fi
for tool in "${LDC}" "${LLD_LINK}"; do
    if ! command -v "${tool}" > /dev/null; then
        echo "error: '${tool}' not found (lld-link ships with lld)" >&2
        exit 1
    fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Every Win32 function the helper calls. A missing one fails the link by name.
cat > "${TMP}/kernel32.def" <<'EOF'
LIBRARY kernel32.dll
EXPORTS
CancelIo
CloseHandle
CreateEventA
CreateFileA
ExitProcess
GetCommandLineW
GetLastError
GetOverlappedResult
GetProcessHeap
GetStdHandle
HeapAlloc
ReadFile
WaitForSingleObject
WaitNamedPipeA
WideCharToMultiByte
WriteFile
EOF
cat > "${TMP}/shell32.def" <<'EOF'
LIBRARY shell32.dll
EXPORTS
CommandLineToArgvW
EOF

for lib in kernel32 shell32; do
    "${LLD_LINK}" /lib /machine:x64 /def:"${TMP}/${lib}.def" /out:"${TMP}/${lib}.lib"
done

"${LDC}" -mtriple=x86_64-windows-msvc -betterC -checkaction=halt -Os -release \
    -I"${SRC_DIR}/source" -c -of="${TMP}/pipehelper.obj" \
    "${SRC_DIR}/source/main.d" "${SRC_DIR}/source/vrcpipe.d"

"${LLD_LINK}" /nologo /nodefaultlib /subsystem:console /machine:x64 \
    /out:"${OUT}" "${TMP}/pipehelper.obj" "${TMP}/kernel32.lib" "${TMP}/shell32.lib"

echo "${OUT}"
