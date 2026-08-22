#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and packages the vrcd client and server for Windows.

.DESCRIPTION
    Produces one zip per component, each holding the executable, the DLLs it
    loads at run time, and the licences those DLLs come with:

        vrcd-client-<version>-windows-x86_64.zip
        vrcd-server-<version>-windows-x86_64.zip

    Both are built under the default configuration, which loads SDL3 and
    libcurl at run time rather than linking them. sqlite3 is the exception: it
    is linked into the server, so nothing has to sit beside it.

    Run packaging\fetch-deps-windows.ps1 first.

.PARAMETER Target
    client, server, or all (the default).

.PARAMETER Deps
    Where fetch-deps-windows.ps1 put its output.

.PARAMETER Compiler
    Passed to dub as --compiler. Defaults to whatever dub picks.

.PARAMETER OutputDir
    Where to write the zips. Defaults to the repository root.
#>
[CmdletBinding()]
param(
    [ValidateSet('client', 'server', 'all')]
    [string] $Target = 'all',
    [string] $Deps = (Join-Path $PSScriptRoot 'deps'),
    [string] $Compiler,
    [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RootDir = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir)
{
    $OutputDir = $RootDir
}

$Version = (Get-Content -Path (Join-Path $RootDir 'VERSION') -Raw).Trim()
$BinDir     = Join-Path $Deps 'bin'
$LicenseDir = Join-Path $Deps 'licenses'

if (-not (Get-Command 'dub' -ErrorAction SilentlyContinue))
{
    throw 'dub not found in PATH'
}

if (-not (Test-Path $BinDir))
{
    throw "dependencies not found in $Deps - run packaging\fetch-deps-windows.ps1 first"
}

# Always from the repository root, whatever directory this was called from: the
# linker finds sqlite3.lib in the working directory, and dub runs the compiler
# from wherever dub itself was invoked rather than from the package directory.
function Invoke-Dub
{
    param([Parameter(Mandatory)] [string[]] $Arguments)

    if ($Compiler)
    {
        $Arguments += "--compiler=$Compiler"
    }

    Write-Host "==> dub $($Arguments -join ' ')"

    Push-Location $RootDir
    try
    {
        & dub $Arguments
        if ($LASTEXITCODE -ne 0)
        {
            throw "dub failed with exit code $LASTEXITCODE"
        }
    }
    finally
    {
        Pop-Location
    }
}

# Everything goes inside a folder named like the zip: a Windows user opening one
# of these gets a directory rather than half a dozen loose files in Downloads,
# and the DLLs are only found if they stay next to the executable.
function New-Package
{
    param(
        [Parameter(Mandatory)] [string]   $Component,
        [Parameter(Mandatory)] [string]   $Executable,
        [Parameter(Mandatory)] [string[]] $Libraries,
        [string[]] $Licenses = @()
    )

    $binary = Join-Path $RootDir "$Component\$Executable"
    if (-not (Test-Path $binary))
    {
        throw "expected binary not found: $binary"
    }

    $name  = "vrcd-$Component-$Version-windows-x86_64"
    $stage = Join-Path ([IO.Path]::GetTempPath()) $name
    $zip   = Join-Path $OutputDir "$name.zip"

    Write-Host "==> Staging $name..."

    if (Test-Path $stage)
    {
        Remove-Item -Path $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stage | Out-Null

    Copy-Item -Path $binary -Destination $stage
    foreach ($library in $Libraries)
    {
        $path = Join-Path $BinDir $library
        if (-not (Test-Path $path))
        {
            throw "missing dependency: $path - re-run packaging\fetch-deps-windows.ps1"
        }
        Copy-Item -Path $path -Destination $stage
    }

    # vrcd's own licence at the top, the third-party ones in a subdirectory:
    # the same split the .deb makes between its copyright file and what it
    # pulls in from the distribution.
    Copy-Item -Path (Join-Path $RootDir 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt')
    if ($Licenses.Count -gt 0)
    {
        $thirdParty = Join-Path $stage 'licenses'
        New-Item -ItemType Directory -Path $thirdParty | Out-Null
        foreach ($license in $Licenses)
        {
            Copy-Item -Path (Join-Path $LicenseDir $license) -Destination $thirdParty
        }
    }

    Write-Host "==> Packaging $zip..."
    if (Test-Path $zip)
    {
        Remove-Item -Path $zip -Force
    }
    Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

    Remove-Item -Path $stage -Recurse -Force
    Write-Host "==> Done: $zip"
}

if ($Target -in @('client', 'all'))
{
    Invoke-Dub @('build', ':client', '--build=release')

    # No pipehelper here. Talking to VRChat's launch pipe is in-process on
    # Windows (client/dub.sdl compiles vrcpipe.d in); the separate executable
    # exists for the Linux client, which runs it inside the game's Proton prefix.
    New-Package -Component 'client' -Executable 'vrcd_client.exe' `
        -Libraries @('SDL3.dll', 'SDL3_ttf.dll', 'SDL3_image.dll') `
        -Licenses @('SDL3-LICENSE.txt', 'SDL3_ttf-LICENSE.txt', 'SDL3_image-LICENSE.txt')
}

if ($Target -in @('server', 'all'))
{
    # Built by fetch-deps-windows.ps1, which puts it here rather than under
    # deps\ because the working directory is where the linker will look for it.
    if (-not (Test-Path (Join-Path $RootDir 'sqlite3.lib')))
    {
        throw 'sqlite3.lib not found in the repository root - run packaging\fetch-deps-windows.ps1 first'
    }

    Invoke-Dub @('build', ':server', '--build=release')

    New-Package -Component 'server' -Executable 'vrcd_server.exe' `
        -Libraries @('libcurl.dll') `
        -Licenses @('curl-COPYING.txt')
}
