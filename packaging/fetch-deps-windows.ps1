#Requires -Version 5.1
<#
.SYNOPSIS
    Fetches the Windows build and runtime dependencies for vrcd client and server.

.DESCRIPTION
    Windows ships none of what vrcd loads at run time, so the pieces have to
    travel with the binaries. This downloads them, and builds the one thing that
    cannot be downloaded ready-made: an sqlite3 library to link against.

    Everything lands under -Dest:
        bin\        DLLs to ship next to the executables
        licenses\   what the shipped DLLs require us to carry
        cache\      the downloaded archives, kept so a re-run is free
        build\      the same archives expanded, and safe to delete

    Except sqlite3.lib, which goes to the repository root. See Build-Sqlite.

    Run this once, then packaging\package-windows.ps1.

.PARAMETER Dest
    Where to put everything. Defaults to packaging\deps beside this script.

.PARAMETER Force
    Re-download and rebuild even when the outputs are already present.
#>
[CmdletBinding()]
param(
    [string] $Dest = (Join-Path $PSScriptRoot 'deps'),
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Invoke-WebRequest spends more time drawing its progress bar than downloading.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Pinned so a release is reproducible and a bump is a visible commit. These are
# the only lines in this file that should need touching.
#
# Every archive is checked. curl.se publishes a sha256 and this is it; sqlite.org
# publishes a SHA3-256, which Get-FileHash cannot compute, so what is pinned here
# is the sha256 of the archive whose SHA3-256 matched the site (do not paste the
# hash off sqlite.org into this, it will never match). SDL publishes neither, so
# theirs were recorded when the version was pinned, which still catches an asset
# that changed under a tag that did not.
$SDL3Version      = '3.4.14'
$SDL3Sha256       = '69a4e55645651af85e6ccfe40981b5a0bc2c594d0004fe7844db680e23cfbdaf'
$SDL3TtfVersion   = '3.2.2'
$SDL3TtfSha256    = '13455007029cf487c5aacaa6ff84406be78ffdbed08f933aba3668680ff245f8'
$SDL3ImageVersion = '3.4.4'
$SDL3ImageSha256  = '15c88c3f4e20c0bd0640d7e6ebd40c8112cde308fc2bb5d0c92fa921f5745613'
# curl.se's own builds. 8.11 is the floor: WebSocket support stopped being
# experimental there, and the server's event stream is a WebSocket.
$CurlBuild        = '8.21.0_7'
$CurlSha256       = 'e469dcdb219d0eca9236b01c7e4bb34fe04af3d4036d350829178dc60f241ae4'
$SqliteYear       = '2026'
$SqliteAmalgam    = 'sqlite-amalgamation-3530400'
$SqliteSha256     = '1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d'

$RootDir    = Split-Path -Parent $PSScriptRoot
$BinDir     = Join-Path $Dest 'bin'
$LicenseDir = Join-Path $Dest 'licenses'
$CacheDir   = Join-Path $Dest 'cache'
# Expanded archives live apart from the archives themselves, so that cache\ is
# only ever the downloads: it is what CI caches, and the extracted copies would
# double its size for something that is thrown away and redone every run.
$WorkDir    = Join-Path $Dest 'build'

function New-Directories
{
    foreach ($dir in @($BinDir, $LicenseDir, $CacheDir, $WorkDir))
    {
        if (-not (Test-Path $dir))
        {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

# Downloads to the cache and returns the local path. A cached archive is reused:
# these are pinned by version, so a file that is already here is the right one.
function Get-Archive
{
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Sha256
    )

    $path = Join-Path $CacheDir $Name

    if ((Test-Path $path) -and (-not $Force))
    {
        Write-Host "  cached: $Name"
    }
    else
    {
        Write-Host "  downloading: $Name"
        Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing
    }

    if ($Sha256)
    {
        $actual = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant())
        {
            throw "checksum mismatch for ${Name}: expected $Sha256, got $actual"
        }
    }

    return $path
}

# Expands into a fresh directory and returns it. Fresh because a half-extracted
# leftover from an interrupted run would otherwise be taken as good.
function Expand-Package
{
    param([Parameter(Mandatory)] [string] $Path)

    $dir = Join-Path $WorkDir ([IO.Path]::GetFileNameWithoutExtension($Path))
    if (Test-Path $dir)
    {
        Remove-Item -Path $dir -Recurse -Force
    }

    Expand-Archive -Path $Path -DestinationPath $dir -Force
    return $dir
}

function Copy-Payload
{
    param(
        [Parameter(Mandatory)] [string] $From,
        [Parameter(Mandatory)] [string] $To
    )

    if (-not (Test-Path $From))
    {
        throw "expected file missing from archive: $From"
    }

    Copy-Item -Path $From -Destination $To -Force
}

# The SDL runtime zips are flat: the DLL alongside LICENSE.txt (zlib) and a
# couple of markdown files. The devel zips would also bring import libraries,
# which the default (dynamic) configuration has no use for.
function Get-Sdl
{
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $Sha256
    )

    $name = "$Component-$Version-win32-x64.zip"
    $url  = "https://github.com/libsdl-org/$Repo/releases/download/release-$Version/$name"

    $dir = Expand-Package (Get-Archive -Url $url -Name $name -Sha256 $Sha256)

    Copy-Payload (Join-Path $dir "$Component.dll") (Join-Path $BinDir "$Component.dll")
    Copy-Payload (Join-Path $dir 'LICENSE.txt') (Join-Path $LicenseDir "$Component-LICENSE.txt")
}

function Get-Sdl3Libraries
{
    Write-Host '==> SDL3 runtime libraries...'

    Get-Sdl -Repo 'SDL'     -Component 'SDL3'     -Version $SDL3Version -Sha256 $SDL3Sha256
    Get-Sdl -Repo 'SDL_ttf' -Component 'SDL3_ttf' -Version $SDL3TtfVersion -Sha256 $SDL3TtfSha256
    # SDL3_image also carries an optional\ directory (avif, tiff, webp, and --
    # unlike SDL2_image -- libpng). Avatar and world thumbnails are PNG and
    # JPEG, and the core DLL decodes both on its own when those are absent, so
    # they are left behind rather than shipped unused.
    Get-Sdl -Repo 'SDL_image' -Component 'SDL3_image' -Version $SDL3ImageVersion -Sha256 $SDL3ImageSha256
}

function Get-Curl
{
    Write-Host '==> libcurl...'

    $name = "curl-$CurlBuild-win64-mingw.zip"
    $url  = "https://curl.se/windows/dl-$CurlBuild/$name"
    $dir  = Join-Path (Expand-Package (Get-Archive -Url $url -Name $name -Sha256 $CurlSha256)) `
        "curl-$CurlBuild-win64-mingw"

    # Renamed, not copied as-is: ddcurl's dynamic binding looks for exactly
    # "libcurl.dll" on Windows and nothing else, and the archive names it
    # libcurl-x64.dll.
    Copy-Payload (Join-Path $dir 'bin\libcurl-x64.dll') (Join-Path $BinDir 'libcurl.dll')
    Copy-Payload (Join-Path $dir 'COPYING.txt') (Join-Path $LicenseDir 'curl-COPYING.txt')

    # No CA bundle is shipped alongside. These builds use LibreSSL, but are
    # configured with CURL_CA_NATIVE=ON, so libcurl reads the Windows
    # certificate store by default and needs no curl-ca-bundle.crt. The archive
    # ships one for curl.exe's benefit; vrcd never sets CURLOPT_CAINFO.
}

# cl.exe and lib.exe, without needing a Developer Command Prompt: find the
# installation with vswhere (which ships with every VS since 2017 at a fixed
# path) and import what vcvars64.bat sets into this process.
function Import-MsvcEnvironment
{
    if (Get-Command 'cl.exe' -ErrorAction SilentlyContinue)
    {
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere))
    {
        throw @'
Visual Studio C++ tools not found (no vswhere.exe).
Install "Visual Studio Build Tools" with the "Desktop development with C++"
workload, or run this from a Developer PowerShell. They are needed to compile
sqlite3 into a library for the server to link against.
'@
    }

    # -products '*' quoted: Build Tools are a different product to the IDE, and
    # the default filter would find only the IDE.
    $install = & $vswhere -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $install)
    {
        throw 'Visual Studio is installed but without the C++ tools (VC.Tools.x86.x64).'
    }

    $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars))
    {
        throw "vcvars64.bat not found under $install"
    }

    Write-Host "  using MSVC from $install"

    # SetEnvironmentVariable rather than Set-Item env:, because some of the
    # names vcvars exports contain parentheses (ProgramFiles(x86)) and would
    # need escaping as a provider path.
    cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$')
        {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }

    if (-not (Get-Command 'cl.exe' -ErrorAction SilentlyContinue))
    {
        throw 'cl.exe still not on PATH after importing the MSVC environment.'
    }
}

# arsd.sqlite does pragma(lib, "sqlite3"), so the linker wants an sqlite3.lib
# whatever we do. Building one from the amalgamation rather than making an
# import library from the official DLL means there is no sqlite3.dll to ship
# and no chance of the server finding somebody else's copy on PATH.
#
# It lands in the repository root rather than under deps\, because that is where
# the linker looks. pragma(lib) becomes /DEFAULTLIB:sqlite3, which link.exe
# resolves against /LIBPATH, then the LIB environment variable, then the working
# directory - and dub runs the compiler from wherever dub itself was invoked,
# which is the root. LIB is not an option: DMD's sc.ini sets it for the linker
# and so overwrites anything we put there. Neither is passing /LIBPATH through
# DFLAGS, since dub splits that on spaces and a path like
# C:\Users\Some Name\vrcd would arrive in pieces.
function Build-Sqlite
{
    Write-Host '==> sqlite3...'

    $lib = Join-Path $RootDir 'sqlite3.lib'
    if ((Test-Path $lib) -and (-not $Force))
    {
        # Named rather than just "up to date", because an sqlite3.lib that was
        # already sitting here is kept: an import library for sqlite3.dll links
        # just as well and fails only at run time, on a machine without the DLL.
        # Pass -Force to replace it.
        Write-Host "  keeping existing $lib"
        return
    }

    $name = "$SqliteAmalgam.zip"
    $url  = "https://sqlite.org/$SqliteYear/$name"
    $dir  = Join-Path (Expand-Package (Get-Archive -Url $url -Name $name -Sha256 $SqliteSha256)) $SqliteAmalgam

    Import-MsvcEnvironment

    Push-Location $dir
    try
    {
        # /MT: DMD and LDC both link the static release CRT (libcmt) on Win64,
        #      and an object built against the DLL CRT would collide with it.
        # SQLITE_ENABLE_COLUMN_METADATA: what Debian and Ubuntu enable, so the
        #      Windows build is not the odd one out if arsd's
        #      sqlite_extended_metadata_available is ever turned on.
        & cl.exe /nologo /c /O2 /MT /DSQLITE_ENABLE_COLUMN_METADATA sqlite3.c
        if ($LASTEXITCODE -ne 0)
        {
            throw "cl.exe failed with exit code $LASTEXITCODE"
        }

        & lib.exe /nologo "/OUT:$lib" sqlite3.obj
        if ($LASTEXITCODE -ne 0)
        {
            throw "lib.exe failed with exit code $LASTEXITCODE"
        }
    }
    finally
    {
        Pop-Location
    }

    Write-Host "  built $lib"
}

New-Directories

Get-Sdl3Libraries
Get-Curl
Build-Sqlite

Write-Host ''
Write-Host "Dependencies ready in $Dest"
Get-ChildItem -Path $BinDir, (Join-Path $RootDir 'sqlite3.lib') | ForEach-Object {
    Write-Host ("  {0,-20} {1,10:N0} bytes" -f $_.Name, $_.Length)
}
