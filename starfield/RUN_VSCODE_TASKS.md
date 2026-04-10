# One-Click Emulator Launch from VS Code Tasks

This guide adds a VS Code task so you can launch your C64 emulator with a single command.

## Goal

After setup, you can press:

- `Ctrl+Shift+B` (Run Build Task), or
- `F1` -> `Tasks: Run Task` -> `Run C64 in VICE`

and `starfield.prg` will autostart in VICE.

## 1. Create tasks file

Create this file in your workspace:

- `.vscode/tasks.json`

Paste the following:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Run C64 in VICE",
      "type": "shell",
      "command": "C:\\Program Files\\VICE\\x64sc.exe",
      "args": [
        "-autostart",
        "${workspaceFolder}\\starfield.prg"
      ],
      "group": {
        "kind": "build",
        "isDefault": true
      },
      "problemMatcher": []
    }
  ]
}
```

## 2. Run it in one click

Use either:

- `Ctrl+Shift+B` (because task is default build), or
- `Terminal` -> `Run Task...` -> `Run C64 in VICE`

## 3. If VICE is installed elsewhere

Edit the `command` value in `.vscode/tasks.json` to your actual path.

Example:

```json
"command": "D:\\Emulators\\VICE\\x64sc.exe"
```

## 4. Optional: Add a rebuild + run workflow

If you later add an assembler build task, you can chain build and run. For now, this task runs the existing `starfield.prg` directly.

## Troubleshooting

- `SYS 2077` does nothing:
  - Current source entry is `SYS 2205`.
  - Rebuild and relaunch from the task so the PRG matches the latest source.

- `The system cannot find the file specified`:
  - VICE path is wrong. Fix `command` path.
- Task runs but emulator does not load program:
  - Confirm `${workspaceFolder}\\starfield.prg` exists.
- Command window flashes and closes:
  - Run the task from `Terminal -> Run Task...` to see full output.
