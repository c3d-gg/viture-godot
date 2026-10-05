# viture-dev

Godot 4.5 GDExtension wrapping the VITURE Glasses SDK, plus a demo project.

## Layout

```
SConstruct              builds demo/bin/libviture.<platform>.<target>.<arch>.dll
godot-cpp/              submodule, pinned to godot-4.5-stable
src/
  viture_sdk.*          runtime loader for glasses.dll, typed from the SDK headers
  viture_glasses.*      VitureGlasses node exposed to Godot
  register_types.cpp    extension entry point (viture_library_init)
demo/                   Godot project; open demo/project.godot
  bin/viture/           VITURE SDK runtime DLLs (not committed)
thirdparty/viture-sdk-windows/  unzipped VITURE SDK (headers needed to build; not committed)
tools/godot/            local Godot editor (not committed)
```

## Setup

1. Unzip `VITURE_XR_Glasses_SDK_for_Windows_x86_64.zip` (requested from VITURE) into
   `thirdparty/viture-sdk-windows/` and copy its `x86_64/*.dll` into `demo/bin/viture/`.
2. Build the extension (needs Python + `pip install scons` and MSVC):

   ```
   git submodule update --init
   python -m SCons platform=windows target=template_debug
   ```
3. Run the demo:

   ```
   ./tools/godot/Godot_v4.5.1-stable_win64_console.exe --path demo
   ```

   3 toggles stereo, Tab moves the window to the next monitor (the glasses), F11 toggles
   fullscreen, R recenters (yaw + position), T resets VIO tracking.

## VitureGlasses node

| Member | Notes |
| --- | --- |
| `library_path` | Default `res://bin/viture/glasses.dll`; exported games look beside the .exe. |
| `product_id` | `0` auto-detects over USB (Luma Ultra is `0x1104`). |
| `target` | Node3D (usually the camera) driven by the head pose each frame. |
| `stereo` | Side-by-side 3D through `VitureXRInterface` (see below). |
| `enable_6dof` | Luma Ultra only, applied at `start()`: include position from host VIO. |
| `prediction_ms` | Pose prediction passed to `get_gl_pose_carina`. |
| `start()` / `stop()` | Auto-start happens in `_ready` (never in the editor). |
| `get_pose()` | `Transform3D` in Godot axes. |
| `get_xr_interface()` | The `VitureXRInterface`, for tuning stereo. |
| `recenter()` | Re-anchors heading and position (horizon stays level). Done automatically on the first pose. |
| `reset_tracking()` | Luma Ultra: restarts VIO (`reset_pose_carina`). |
| `is_tracking_stable()` | Luma Ultra `pose_status == 0`. |
| `set_display_3d(bool)` | Switches the glasses between 2D and 3840x1080 side-by-side 3D. |
| `get/set_brightness`, `get/set_display_mode` | Raw SDK display controls. |
| signals | `started`, `stopped`, `state_changed(state_id, value)` |

Only one `VitureGlasses` may run at a time (the SDK callbacks have no user pointer).

## Stereo

Set `stereo = true` on `VitureGlasses` and use `XROrigin3D` + `XRCamera3D` for the camera. This:

1. registers `VitureXRInterface` with `XRServer` and makes it primary,
2. sets `use_xr` on the viewport (Godot renders both eyes in one multiview pass),
3. switches the glasses to 3840x1080 side-by-side mode (takes ~4 s; `state_changed(2, mode)` fires when done).

The window must then be fullscreen on the glasses' 3840-wide screen, which needs Windows display mode
**Extend** (Win+P), not Duplicate. The demo finds that screen automatically.

Projects need **Project Settings > XR > Shaders > Enabled** (`xr/shaders/enabled=true`).
2D `CanvasItem`s on the main viewport are not shown in stereo; use `Label3D` or a `SubViewport` on a quad.

`VitureXRInterface` tuning (defaults from the Luma Ultra spec):

| Property | Default | Notes |
| --- | --- | --- |
| `eye_separation` | `0.063` m | Your IPD. |
| `fov` | `52` deg | Diagonal field of view per eye. |
| `convergence_distance` | `3.0` m | Virtual screen distance: objects there have zero disparity. `0` = parallel eyes. |
## Virtual screen

`demo/virtual_screen.tscn` pins a live capture of a Windows monitor in the room, so you look around it
instead of being limited to the fixed display in the glasses. Run it with:

```
./tools/godot/Godot_v4.5.1-stable_win64_console.exe --path demo res://virtual_screen.tscn
```

It switches the glasses to 1920x1200 @ 120 Hz, goes fullscreen on them (Windows must be on **Extend**), and
captures the primary monitor. Placement and settings persist in `user://virtual_screen.cfg`.

Global hotkeys (any app has focus, via `GlobalHotkeys` / Win32 `RegisterHotKey`):

| Hotkey | Action |
| --- | --- |
| Ctrl+Alt+Shift+Space | Pin the screen where you are looking |
| Ctrl+Alt+Shift+S | Show/hide the settings window |
| Ctrl+Alt+Shift+P | Pin the window you're using as its own screen |
| Ctrl+Alt+Shift+PageUp / PageDown | Raise / lower the screen |

Without the glasses the app waits in the tray (window hidden, nearly idle) and activates within ~2 s of
them being plugged in, restoring every screen and virtual monitor; unplugging saves and goes back to
waiting. **Start with Windows** (settings or tray menu) adds a login item that runs the windowless Godot
binary, so it's always waiting. Only one copy can run at a time.

The settings window opens on the primary desktop, so it appears inside the virtual screen and works with the
mouse. A tray icon gives the same: left-click for settings, right-click for a menu. While the app or its
settings window has focus: Space pin, W/S raise/lower, Up/Down distance, Left/Right size, [ / ] field of view,
B display edges, H display mode, M monitor.

`DesktopCapture` uses Windows Graphics Capture (C++/WinRT, so the build enables exceptions). DXGI Desktop
Duplication doesn't work on hybrid-GPU laptops when the captured monitor is on the other GPU.

Each glasses display mode appears to Windows as a separate monitor that may not be on the desktop yet;
`VitureGlasses.extend_desktop()` applies Extend (same as Win+P) and the demo calls it after a mode switch.

Virtual monitors come from the SudoVDA driver (`VirtualDisplays`) and exist only while the app runs. The
desktop is arranged to match the room (`VirtualDisplays.arrange_displays`): monitors whose screens sit left
of the primary monitor's screen go to its left, and so on. The glasses' display goes at the far end, and
`CursorFence` keeps the mouse off it, since Windows doesn't allow gaps between monitors.

## License

MIT; see [LICENSE](LICENSE). The VITURE Glasses SDK is not included and has its own terms. The SudoVDA
control definitions in `src/virtual_displays.cpp` come from
[SudoMaker/SudoVDA](https://github.com/SudoMaker/SudoVDA) (MIT / CC0).
