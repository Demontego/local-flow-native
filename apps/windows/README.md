# Local Flow (Windows tray)

Hold **Ctrl+Alt** → speak → release → cleaned text is pasted via clipboard + Ctrl+V.

Tray-only (no console). Status HUD appears top-right while dictating / loading.

## Bootstrap (once)

```powershell
# from repo root
.\scripts\bootstrap_windows.ps1
# reopen PowerShell so rustc / cmake / cl are on PATH
```

Installs Rustup (MSVC) + CMake + LLVM (libclang for bindgen) if missing. Uses any
installed VS C++ Build Tools (2022 / 2026 / etc.); only installs VS 2022 Build Tools
when none are found.

## Build

```powershell
.\scripts\build_windows.ps1
# → dist/release/local-flow-<ver>-windows-x64.exe
# → dist/release/local-flow-<ver>-windows-x64.zip
```

Or with make (Git Bash / CI):

```bash
make windows
./target/release/local-flow-windows.exe
```

Override version tag via `$env:LF_VERSION = "0.1.0"`.

Tray menu: Load models, Download Whisper, Download Qwen3, Quit.

Data directory: `%LOCALAPPDATA%\Local Flow Native\`
