# build.ps1 - builds the relay sender, the relay server, and the test binaries.
#
# Usage:
#   powershell -File scripts/build.ps1            build everything and run the crypto test
#   powershell -File scripts/build.ps1 -Clean     remove built binaries first
#   powershell -File scripts/build.ps1 -Test      also print the integration test commands
#
# The toolchain is the portable llvm-mingw tree under tools/, so no Visual
# Studio installation is required.
#
# Both relay programs are GUI-subsystem binaries: double-clicking opens a window,
# and `--console` runs them headless for scripts and the integration tests.
# This script lives in scripts/, not build/: -Clean targets build output, and a
# script inside that directory would delete itself.

[CmdletBinding()]
param(
    [switch]$Test,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $root 'build'
$incDirs = @('common\crypto', 'common\json', 'common\wire', 'common\net', 'common\util', 'common\ui') |
    ForEach-Object { Join-Path $root $_ }

function Find-Clang {
    $found = Get-ChildItem -Path (Join-Path $root 'tools') -Recurse -Filter 'clang.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($found) { return $found.FullName }

    $onPath = Get-Command clang -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    throw 'clang not found. Expected tools/llvm-mingw/**/bin/clang.exe - see README.md.'
}

$clang = Find-Clang
Write-Host "toolchain  : $clang"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

if ($Clean) {
    Write-Host "cleaning   : build output only"
    Get-ChildItem -Path $buildDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.exe', '.obj') -or $_.Name -like '*.log' -or $_.Name -like '*.pid' } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force -ErrorAction Stop }
            catch { Write-Warning "could not remove $($_.Name) (in use)" }
        }
}

# -mwindows produces a GUI subsystem binary; main() still works as the entry
# point because libmingw32 supplies the WinMain shim.
$commonFlags = @('-std=c99', '-Wall', '-Wextra', '-Wno-unused-parameter', '-O2',
                 '-mwindows', '-DUNICODE', '-D_UNICODE')
$includeFlags = $incDirs | ForEach-Object { "-I$_" }
$guiLibs = @('-lws2_32', '-lbcrypt', '-lcomctl32')

$core = @(
    'common\crypto\dsh_aes.c'
    'common\crypto\dsh_sha256.c'
    'common\crypto\dsh_sha1.c'
    'common\json\dsh_json.c'
    'common\wire\dsh_wire.c'
    'common\net\dsh_net.c'
    'common\util\dsh_cfg.c'
    'common\util\dsh_log.c'
    'common\ui\dsh_ui.c'
) | ForEach-Object { Join-Path $root $_ }

function Invoke-Build {
    param(
        [string]$Name,
        [string[]]$Sources,
        [string[]]$Libraries
    )

    $output = Join-Path $buildDir $Name
    Write-Host "building   : $Name"
    $clangArgs = @($commonFlags + $includeFlags + @('-o', $output) + $Sources + $Libraries)
    & $clang @clangArgs
    if ($LASTEXITCODE -ne 0) {
        throw "build failed: $Name"
    }
    Write-Host ("             {0:N0} bytes" -f (Get-Item $output).Length)
}

Invoke-Build -Name 'dsh-relay-server.exe' `
    -Sources ($core + @(
        (Join-Path $root 'server\main.c')
        (Join-Path $root 'server\ui.c')
    )) `
    -Libraries $guiLibs

Invoke-Build -Name 'dsh-relay-sender.exe' `
    -Sources ($core + @(
        (Join-Path $root 'common\net\dsh_http.c')
        (Join-Path $root 'common\net\dsh_ws.c')
        (Join-Path $root 'agent\main.c')
        (Join-Path $root 'agent\ui.c')
    )) `
    -Libraries $guiLibs

# The tests are console-only, so they skip the GUI flags and libraries.
$testFlags = @('-std=c99', '-Wall', '-Wextra', '-Wno-unused-parameter', '-O2')

function Invoke-TestBuild {
    param([string]$Name, [string[]]$Sources, [string[]]$Libraries)

    $output = Join-Path $buildDir $Name
    Write-Host "building   : $Name"
    & $clang @($testFlags + $includeFlags + @('-o', $output) + $Sources + $Libraries)
    if ($LASTEXITCODE -ne 0) {
        throw "build failed: $Name"
    }
}

Invoke-TestBuild -Name 'test_crypto.exe' -Sources @(
    (Join-Path $root 'tests\test_crypto.c')
    (Join-Path $root 'common\crypto\dsh_aes.c')
    (Join-Path $root 'common\crypto\dsh_sha256.c')
    (Join-Path $root 'common\json\dsh_json.c')
    (Join-Path $root 'common\wire\dsh_wire.c')
) -Libraries @('-lbcrypt')

Invoke-TestBuild -Name 'test_http.exe' -Sources @(
    (Join-Path $root 'tests\test_http.c')
    (Join-Path $root 'common\crypto\dsh_aes.c')
    (Join-Path $root 'common\crypto\dsh_sha256.c')
    (Join-Path $root 'common\json\dsh_json.c')
    (Join-Path $root 'common\wire\dsh_wire.c')
    (Join-Path $root 'common\net\dsh_net.c')
    (Join-Path $root 'common\net\dsh_http.c')
) -Libraries @('-lws2_32', '-lbcrypt')

Write-Host ''
Write-Host 'crypto conformance (the gate for every other test):'
& (Join-Path $buildDir 'test_crypto.exe') (Join-Path $root 'tests\vectors.json')
if ($LASTEXITCODE -ne 0) {
    throw "crypto conformance failed (exit $LASTEXITCODE)"
}

if ($Test) {
    Write-Host ''
    Write-Host 'Integration tests need a running server and sender:'
    Write-Host '  build\dsh-relay-server.exe --console --port 7777 --passphrase <secret>'
    Write-Host '  build\dsh-relay-sender.exe --console --passphrase <secret> --dsh-token <token>'
    Write-Host '  node tests\relay_client.mjs 127.0.0.1 7777 <secret>'
    Write-Host '  node tests\relay_follow.mjs 127.0.0.1 7777 <secret> [sessionId]'
}

Write-Host ''
Write-Host 'build complete.'
