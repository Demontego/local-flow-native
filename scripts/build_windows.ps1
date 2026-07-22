# Build local-flow-windows (full) and stage portable artifacts under dist/release.
# Requires: Rust MSVC toolchain, CMake, VS C++ Build Tools, LLVM (see bootstrap_windows.ps1).
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

# Ensure cargo / cmake on PATH (common after fresh installs).
$cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
$cmakeBin = "C:\Program Files\CMake\bin"
if (Test-Path $cmakeBin) { $env:Path = "$cmakeBin;$env:Path" }

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo not found. Run .\scripts\bootstrap_windows.ps1 and open a new shell."
}
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "cmake not found. Run .\scripts\bootstrap_windows.ps1 and open a new shell."
}

# bindgen needs libclang.dll
if (-not $env:LIBCLANG_PATH) {
    foreach ($dir in @("C:\Program Files\LLVM\bin", "C:\Program Files (x86)\LLVM\bin")) {
        if (Test-Path (Join-Path $dir "libclang.dll")) {
            $env:LIBCLANG_PATH = $dir
            break
        }
    }
}
if (-not $env:LIBCLANG_PATH -or -not (Test-Path (Join-Path $env:LIBCLANG_PATH "libclang.dll"))) {
    throw "libclang.dll not found. Run .\scripts\bootstrap_windows.ps1 (installs LLVM) or set LIBCLANG_PATH."
}
Write-Host "LIBCLANG_PATH=$env:LIBCLANG_PATH"

# MSBuild blows up past MAX_PATH when CARGO_TARGET_DIR is a deep sandbox cache path.
$localTarget = Join-Path $RepoRoot "target"
if (-not $env:CARGO_TARGET_DIR -or $env:CARGO_TARGET_DIR.Length -gt 90 -or
    $env:CARGO_TARGET_DIR -match 'cursor-sandbox-cache') {
    $env:CARGO_TARGET_DIR = $localTarget
}
Write-Host "CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR"

# Import VS MSVC env so CMake finds cl/link (Vcvars).
function Import-VsDevEnv {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $false }
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsPath) { return $false }
    $vsDevCmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) { return $false }
    $lines = & cmd.exe /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
        }
    }
    return $true
}
if (-not (Import-VsDevEnv)) {
    Write-Warning "VsDevCmd not imported; CMake may fail to find the MSVC compiler"
} else {
    Write-Host "VS env loaded (VCINSTALLDIR=$env:VCINSTALLDIR)"
}

$version = $env:LF_VERSION
if (-not $version) {
    $cargoToml = Get-Content -Raw (Join-Path $RepoRoot "Cargo.toml")
    if ($cargoToml -match '(?m)^version\s*=\s*"([^"]+)"') {
        $version = $Matches[1]
    } else {
        throw "could not read workspace version from Cargo.toml; set LF_VERSION"
    }
}

Write-Host "==> cargo build -p local-flow-windows --release --features full"
cargo build -p local-flow-windows --release --features full
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed (exit $LASTEXITCODE)"
}

$exeSrc = Join-Path $env:CARGO_TARGET_DIR "release\local-flow-windows.exe"
if (-not (Test-Path $exeSrc)) {
    throw "missing $exeSrc"
}

$outDir = Join-Path $RepoRoot "dist\release"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$exeName = "local-flow-$version-windows-x64.exe"
$zipName = "local-flow-$version-windows-x64.zip"
$exeDst = Join-Path $outDir $exeName
$zipDst = Join-Path $outDir $zipName

Copy-Item -Force $exeSrc $exeDst
if (Test-Path $zipDst) { Remove-Item -Force $zipDst }
Compress-Archive -Path $exeDst -DestinationPath $zipDst -Force

$sumFile = Join-Path $outDir "SHA256SUMS-windows.txt"
$lines = @()
foreach ($f in @($exeDst, $zipDst)) {
    $hash = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLowerInvariant()
    $lines += "$hash  $(Split-Path $f -Leaf)"
}
$lines | Set-Content -Encoding ascii -Path $sumFile

Write-Host "Staged:"
Write-Host "  $exeDst"
Write-Host "  $zipDst"
Write-Host "  $sumFile"
Get-Content $sumFile
