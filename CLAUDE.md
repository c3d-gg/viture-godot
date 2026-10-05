# Developer notes

Godot 4.5 GDExtension (C++, godot-cpp) for VITURE XR glasses on Windows, plus the virtual-screens app in
`demo/virtual_screen.tscn`. See README.md for features and setup, TODO.md for what's next.

## Hardware and environment

- VITURE **Luma Ultra** (USB `35CA:1104`, SDK device type Carina = 6DoF via host-side VIO). Panel 1920x1200,
  52 deg diagonal FOV; the app runs it at 1920x1200 @ 120 Hz (mode `0x44`). Monitor PnP ID `CVT...`.
- Hybrid-GPU laptop: Intel drives the laptop panel (`\\.\DISPLAY1`, primary), NVIDIA RTX 4060 drives the
  glasses. Godot renders with Vulkan on the NVIDIA GPU.
- Toolchain: VS 2019 Build Tools (MSVC 14.29), Windows SDK 10.0.19041 (too old for
  `IsBorderRequired`), Python + SCons, Godot 4.5.1 in `tools/godot/`.
- VITURE Windows SDK v2.4.0 in `thirdparty/viture-sdk-windows/` (DLL is `glasses.dll`); its runtime DLLs are
  copied to `demo/bin/viture/`. Neither is committed: the SDK license forbids redistribution.
- SudoVDA, Parsec VDD and Meta Virtual Monitor drivers are installed; only SudoVDA is used.

## Build and run

```
python -m SCons platform=windows target=template_debug
./tools/godot/Godot_v4.5.1-stable_win64_console.exe --path demo res://virtual_screen.tscn
```

- **The running app locks the extension DLL**: the link step fails with "Access is denied". Ask the user to
  quit it (tray icon > Quit; closing the settings window only hides it), or close it gracefully by posting
  `WM_CLOSE` to its main window (title "VITURE Demo (DEBUG)"), which lets it remove virtual monitors and save.
  Compile errors still show before the link step, so a locked build is still a useful compile check.
- Only one copy of the app can run (named mutex), so tests that run the full scene need it closed.
- GDScript-only changes need no build, just an app restart.
- The user launches the app themselves with `! <command>` (bash: use forward slashes).

## Checking and testing without unplugging anything

- Parse check: `Godot_..._console.exe --headless --path demo --check-only --script res://virtual_screen.gd`.
  It loads the extension DLL on disk, so new C++ methods show as "not found" until the build succeeds.
- Shaders only compile with a real renderer: run a tiny non-headless SceneTree script that draws a quad.
- Test harness pattern: a SceneTree script in the scratchpad that `instantiate()`s `virtual_screen.tscn`,
  then pokes it. Set `$Glasses.product_id = 0x9999` before adding it to fake "glasses unplugged"; set it back
  to `0` to "plug in"; call `app._deactivate()` to simulate an unplug.
- Simulate hotkeys from PowerShell **outside** Godot (`keybd_event`), not via `OS.execute` from Godot
  (quoting breaks). `SetForegroundWindow` a window first to test "pin the foreground window".
- Inspect real window state from PowerShell with `EnumWindows`; the `_console.exe` launcher spawns the real
  Godot process as a child, so match child PIDs. Check visibility with `VitureGlasses.is_native_window_shown`.
- Tests that run the full app read and write the user's real config: back up
  `%APPDATA%\Godot\app_userdata\VITURE Demo\virtual_screen.cfg` first and restore it after.
- Window titles can be personal: print app names, not titles, in test output.

## Gotchas learned the hard way

- PowerShell `Get-Content`/`Set-Content` round trips mangle UTF-8 (`·` became `Â·`, BOMs added). Edit files
  with the Edit tool or Python (`encoding="utf-8", newline="\n"`). For long multi-line Python edits, write the
  script to a file first: inline heredocs with nested quotes break in the Bash tool.
- Python string literals in edit scripts eat a level of backslash escaping (C++ `\\` became `\`).
- Godot runs a parent's `_process` before its children's: the scene sets `glasses.process_priority = -1` so
  the head pose is current before grabbed screens are aimed.
- Godot can't truly hide its main window on Windows (`visible = false` lies): use
  `VitureGlasses.set_native_window_shown`.
- Godot draws subwindows inside the main window unless `display/window/subwindows/embed_subwindows=false`
  (set in demo/project.godot), which the settings window needs.
- `class_name` only registers after an editor import; the scripts use `preload` constants instead.
- Glasses display mode switches take ~4 s; `state_changed(2, mode)` fires when done. Each mode is a separate
  monitor to Windows and may drop off the desktop until Extend is applied. After plug-in, USB appears before
  the display: wait for the display before applying Extend.
- Monitor handles and `\\.\DISPLAYn` indices change whenever the layout changes: track monitors by device
  name and restart captures after any layout change.
- A virtual monitor isn't capturable for a moment after creation: capture it after the refit.
- Windows closes gaps between monitors (`SetDisplayConfig` reports success but re-snaps).

## Working with the user

- Build and self-test before handing over; explain what was verified and what wasn't.
- Commit and push (to https://github.com/c3d-gg/viture-godot, branch `main`) once the user confirms a
  feature works on the glasses. Commit messages end with the Co-Authored-By line.
