# Ensure Rust (MSVC), CMake, and VS C++ Build Tools for local-flow-windows.
# Skips packages that are already present (e.g. VS Build Tools 2022/2026).
# Reopen PowerShell after first install so PATH updates apply.
$ErrorActionPreference = "Stop"

function Ensure-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install App Installer from the Microsoft Store."
    }
}

function Test-VcTools {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $false }
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    return [bool]$vsPath
}

function Install-WingetPkg {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Override = ""
    )
    Write-Host "==> winget install $Id"
    $args = @(
        "install", "-e", "--id", $Id,
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )
    if ($Override) {
        $args += @("--override", $Override)
    }
    & winget @args
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        # -1978335189 = already installed
        throw "winget install $Id failed (exit $LASTEXITCODE)"
    }
}

$cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
if (Test-Path $cargoBin) {
    $env:Path = "$cargoBin;$env:Path"
}
$cmakeBin = "C:\Program Files\CMake\bin"
if (Test-Path $cmakeBin) {
    $env:Path = "$cmakeBin;$env:Path"
}

Ensure-Winget

if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Install-WingetPkg -Id "Rustlang.Rustup"
    if (Test-Path $cargoBin) { $env:Path = "$cargoBin;$env:Path" }
} else {
    Write-Host "==> rustup already present"
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    Install-WingetPkg -Id "Kitware.CMake"
    if (Test-Path $cmakeBin) { $env:Path = "$cmakeBin;$env:Path" }
} else {
    Write-Host "==> cmake already present"
}

function Test-LibClang {
    if ($env:LIBCLANG_PATH -and (Test-Path (Join-Path $env:LIBCLANG_PATH "libclang.dll"))) {
        return $true
    }
    $candidates = @(
        "C:\Program Files\LLVM\bin",
        "C:\Program Files (x86)\LLVM\bin"
    )
    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir "libclang.dll")) {
            $env:LIBCLANG_PATH = $dir
            return $true
        }
    }
    return $false
}

if (Test-VcTools) {
    Write-Host "==> VS C++ tools already present (skip Build Tools install)"
} else {
    Install-WingetPkg -Id "Microsoft.VisualStudio.2022.BuildTools" `
        -Override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
}

# bindgen (whisper-rs-sys / llama-cpp-sys) needs libclang.dll
if (Test-LibClang) {
    Write-Host "==> libclang already present ($env:LIBCLANG_PATH)"
} else {
    Install-WingetPkg -Id "LLVM.LLVM"
    if (-not (Test-LibClang)) {
        Write-Warning "LLVM installed but libclang.dll not found yet; reopen shell and set LIBCLANG_PATH"
    } else {
        Write-Host "==> LIBCLANG_PATH=$env:LIBCLANG_PATH"
    }
}

$rustup = Get-Command rustup -ErrorAction SilentlyContinue
if (-not $rustup) {
    Write-Warning "rustup not on PATH yet. Open a new PowerShell, then re-run the checklist below."
} else {
    rustup default stable
    rustup target add x86_64-pc-windows-msvc
}

Write-Host ""
Write-Host "=== checklist (open a NEW PowerShell if tools missing) ==="
foreach ($cmd in @("rustc", "cargo", "rustup", "cmake")) {
    $c = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($c) {
        Write-Host ("  OK  {0,-8} {1}" -f $cmd, $c.Source)
    } else {
        Write-Host ("  --  {0,-8} not found" -f $cmd)
    }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$clOk = $false
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($vsPath) {
        Write-Host "  OK  VS      $vsPath"
        $cl = Get-ChildItem -Path $vsPath -Recurse -Filter cl.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\Hostx64\\x64\\cl\.exe$' } |
            Select-Object -First 1
        if ($cl) {
            Write-Host "  OK  cl      $($cl.FullName)"
            $clOk = $true
        }
    }
}
if (-not $clOk) {
    Write-Host "  --  cl       not found (install C++ build tools workload)"
}
if ($env:LIBCLANG_PATH -and (Test-Path (Join-Path $env:LIBCLANG_PATH "libclang.dll"))) {
    Write-Host "  OK  libclang $env:LIBCLANG_PATH"
} elseif (Test-Path "C:\Program Files\LLVM\bin\libclang.dll") {
    Write-Host "  OK  libclang C:\Program Files\LLVM\bin"
} else {
    Write-Host "  --  libclang not found (needed for bindgen; winget install LLVM.LLVM)"
}

Write-Host ""
Write-Host "Next: .\scripts\build_windows.ps1"
