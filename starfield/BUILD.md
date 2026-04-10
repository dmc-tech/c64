# How to Assemble starfield.asm

This project uses **Kick Assembler** syntax (`.pc`, `.const`, `.fill`, `!` labels). Follow the steps below to assemble it into a C64-loadable PRG file.

## Prerequisites

1. **Java Runtime** (JRE 8 or later)  
   Download from https://adoptium.net/ or use `winget install EclipseAdoptium.Temurin.21.JRE`

2. **Kick Assembler**  
   Download from http://theweb.dk/KickAssembler/  
   Extract the zip; the key file is `KickAss.jar`.

## Assemble

From the project folder (`C:\Commodore\asm`):

```powershell
java -jar "C:\Commodore\KickAss\KickAss.jar" starfield.asm -o starfield.prg
```

On success you will see output like:

```
assembling
Output: starfield.prg
```

and a fresh `starfield.prg` plus `starfield.sym` will appear in the current folder.

## Quick test after assembly

Load and run in VICE:

```powershell
x64sc -autostart starfield.prg
```

Or load the PRG manually, then type `RUN` at the BASIC prompt.  
Press any key to exit back to BASIC.

## Common errors

| Symptom | Fix |
|---------|-----|
| `java` not recognized | Install Java and ensure it is on your PATH. |
| `Error: File not found KickAss.jar` | Use the full path to the JAR file. |
| Assembler syntax errors | Confirm you are using Kick Assembler 5.x (see version in `asminfo.txt`). |

## Optional: VS Code build task

Add this to `.vscode/tasks.json` so `Ctrl+Shift+B` assembles and launches:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Build PRG",
      "type": "shell",
      "command": "java",
      "args": [
        "-jar",
        "C:\\Commodore\\KickAss\\KickAss.jar",
        "${workspaceFolder}\\starfield.asm",
        "-o",
        "${workspaceFolder}\\starfield.prg"
      ],
      "group": {
        "kind": "build",
        "isDefault": true
      },
      "problemMatcher": []
    },
    {
      "label": "Run C64 in VICE",
      "type": "shell",
      "command": "C:\\Program Files\\VICE\\x64sc.exe",
      "args": [
        "-autostart",
        "${workspaceFolder}\\starfield.prg"
      ],
      "dependsOn": "Build PRG",
      "problemMatcher": []
    }
  ]
}
```

Then use `Terminal -> Run Task -> Run C64 in VICE` to build and launch in one step.
