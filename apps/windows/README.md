# Local Flow (Windows tray)

Hold **Ctrl+Alt** → speak → release → cleaned text is pasted via clipboard + Ctrl+V.

```bash
# from repo root, on Windows + MSVC
make windows
./target/release/local-flow-windows.exe
```

Tray menu: Load models, Download Whisper, Download Qwen3, Quit.

Data directory: `%LOCALAPPDATA%\Local Flow Native\`
