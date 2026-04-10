# Running `starfield.prg` in a Commodore 64 Emulator

This project already contains a built program file:

- `starfield.prg`

You can run it directly in an emulator without rebuilding first.

## Option 1: VICE (recommended on Windows)

### 1. Install VICE

- Download VICE from the official site: https://vice-emu.sourceforge.io/
- Install it.

### 2. Start the C64 emulator

- Open `x64sc.exe` (cycle-accurate) or `x64.exe` (faster).

### 3. Load the PRG

Use one of these methods:

- Drag and drop `starfield.prg` into the emulator window, or
- In emulator menu: `File -> Smart Attach Disk/Tape...` and select `starfield.prg`, or
- Use BASIC command in the emulator:

```basic
LOAD "*",8,1
RUN
```

If you used drag-and-drop on a PRG, many VICE setups auto-load and you may only need:

```basic
RUN
```

### 4. What you should see

- The program executes `SYS 2205` from the BASIC stub.
- A starfield pattern is drawn on the C64 text screen.

## Option 2: VICE autostart from command line

From the project folder:

```powershell
x64sc -autostart starfield.prg
```

If `x64sc` is not in your PATH, use the full executable path, for example:

```powershell
"C:\Program Files\VICE\x64sc.exe" -autostart "C:\Commodore\asm\starfield.prg"
```

## Optional: Rebuild before running

If you edit `starfield.asm`, rebuild to regenerate `starfield.prg`.

Exact build command depends on your assembler setup. A common Kick Assembler style command is:

```powershell
java -jar KickAss.jar starfield.asm -o starfield.prg
```

Then run again with VICE:

```powershell
x64sc -autostart starfield.prg
```

## Troubleshooting

- `SYS 2077` does nothing:
	- This source now uses `SYS 2205` (the actual `Main` address in the current layout).
	- Rebuild `starfield.prg`, then reload it in the emulator.

- Black screen or no effect: make sure you loaded `starfield.prg` (not `.asm`).
- `?FILE NOT FOUND ERROR`: the emulator drive does not point to your folder; use drag-and-drop or `-autostart`.
- Program starts but appears static: current code draws stars continuously in place (no movement routine yet).
