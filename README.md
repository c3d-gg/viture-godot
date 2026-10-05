# viture-godot

Godot 4.5 GDExtension for VITURE XR glasses (built on a Luma Ultra), plus a virtual-screens app that pins
your Windows desktop, extra virtual monitors and individual app windows in the room around you.

## Layout

```
SConstruct              builds demo/bin/libviture.<platform>.<target>.<arch>.dll
godot-cpp/              submodule, pinned to godot-4.5-stable
src/
  viture_sdk.*          runtime loader for glasses.dll (typed from the SDK headers) + Win32 helpers
  viture_glasses.*      VitureGlasses node: tracking, display control, desktop/login-item helpers
  viture_xr_interface.* VitureXRInterface: side-by-side stereo XR interface
  desktop_capture.*     DesktopCapture: monitor/window capture via Windows Graphics Capture
  virtual_displays.*    VirtualDisplays: SudoVDA virtual monitors + desktop arrangement
  global_hotkeys.*      GlobalHotkeys: system-wide hotkeys (RegisterHotKey)
  cursor_fence.*        CursorFence: keeps the mouse out of a desktop rectangle
  register_types.cpp    extension entry point (viture_library_init)
demo/                   Godot project
  virtual_screen.tscn   the virtual-screens app (virtual_screen.gd, screen_panel.gd, desktop_screen.gdshader)
  main.tscn             head-tracking / stereo test scene
  bin/viture/           VITURE SDK runtime DLLs (not committed)
thirdparty/viture-sdk-windows/  unzipped VITURE SDK (headers needed to build; not committed)
tools/godot/            Godot 4.5.1 editor binaries (not committed)
TODO.md                 next features, with design notes
CLAUDE.md               developer notes: workflow, testing, gotchas
```

## Setup from scratch (Windows)

1. **Toolchain:** MSVC (VS 2019 Build Tools or newer, with the Windows 10 SDK), Python 3 and
   `pip install scons`, git.
2. **Godot:** unzip Godot 4.5.1 (`Godot_v4.5.1-stable_win64.exe.zip`) into `tools/godot/`.
3. **VITURE SDK** (request it from VITURE's developer program; it is not redistributable): unzip
   `VITURE_XR_Glasses_SDK_for_Windows_x86_64.zip` into `thirdparty/viture-sdk-windows/`, and copy its
   `x86_64/*.dll` into `demo/bin/viture/`.
4. **Virtual monitors** (optional): install the SudoVDA driver ("SudoMaker Virtual Display Adapter", e.g. via
   [Apollo](https://github.com/ClassicOldSong/Apollo)). Without it everything else works.
5. **Build:**

   ```
   git submodule update --init
   python -m SCons platform=windows target=template_debug
   ```

   The first build compiles godot-cpp (a few minutes). The build fails with "Access is denied" while the
   app is running, because it has the DLL loaded: quit it first (tray icon > Quit).
6. **Windows display mode:** the glasses must be their own display: Win+P > **Extend**.

## Virtual-screens app

```
./tools/godot/Godot_v4.5.1-stable_win64_console.exe --path demo res://virtual_screen.tscn
```

- Waits in the tray (window hidden, nearly idle) until the glasses are plugged in, then switches them to
  1920x1200 @ 120 Hz, goes fullscreen on them and restores every screen. Unplugging saves and goes back to
  waiting. Only one copy runs at a time. **Start with Windows** (settings or tray) adds a login item.
- Screens show a monitor, a SudoVDA virtual monitor (created on demand, any resolution), or one app window.
  Each has its own size, distance and placement, saved in `user://virtual_screen.cfg`
  (`%APPDATA%\Godot\app_userdata\VITURE Demo\virtual_screen.cfg`).
- Grab a screen to move it: it follows your gaze and snaps edge to edge beside other screens. **Line up
  screens** makes a flush row (tilted rows rotate about the screens' own up axis).
- The Windows desktop is arranged to match the room (monitors left of the primary screen in the room go to
  its left, etc.); the glasses' own display goes at the far end, and the mouse is fenced off it.
- Text: supersampled/bicubic filtering, a sharpness slider, **Pixel-perfect size**, and **Match resolution
  to size** (sets a virtual monitor's resolution to the glasses pixels it covers).

Global hotkeys (work from any app):

| Hotkey | Action |
| --- | --- |
| Ctrl+Alt+Shift+Space | Grab the screen you're looking at / drop it |
| Ctrl+Alt+Shift+S | Show/hide the settings window |
| Ctrl+Alt+Shift+P | Pin the window you're using as its own screen |
| Ctrl+Alt+Shift+PageUp / PageDown | Raise / lower the screen you're looking at |

The settings window opens on the primary desktop, so it appears inside a virtual screen and works with the
mouse. Tray icon: left-click for settings, right-click for a menu (grab, add virtual monitor, line up,
settings, display edges, Start with Windows, Quit). Closing the settings window only hides it; quit from the
tray. While the app or its settings window has focus: Space grab/drop, W/S raise/lower, Up/Down distance,
Left/Right size, [ / ] field of view, B display edges, H display mode.

## VitureGlasses node

| Member | Notes |
| --- | --- |
| `library_path` | Default `res://bin/viture/glasses.dll`; exported games look beside the .exe. |
| `product_id` | `0` auto-detects over USB (Luma Ultra is `0x1104`). |
| `target` | Node3D (usually the camera) driven by the head pose each frame. |
| `stereo` | Side-by-side 3D through `VitureXRInterface` (see below). |
| `enable_6dof` | Luma Ultra only, applied at `start()`: include position from host VIO. |
| `prediction_ms` | Pose prediction passed to `get_gl_pose_carina`. |
| `auto_start` | Start in `_ready` (never in the editor). The virtual-screens app turns it off and starts manually. |
| `start()` / `stop()` / `is_glasses_connected()` | Session control; the last checks USB without a session. |
| `get_pose()` / `update_pose()` | `Transform3D` in Godot axes. |
| `recenter()` | Re-anchors heading and position (horizon stays level). Done automatically on the first pose. |
| `reset_tracking()` | Luma Ultra: restarts VIO (`reset_pose_carina`). |
| `is_tracking_stable()` | Luma Ultra `pose_status == 0`. |
| `set_display_3d(bool)` | Switches the glasses between 2D and 3840x1080 side-by-side 3D (~4 s). |
| `get/set_brightness`, `get/set_display_mode` | Raw SDK display controls (`get_display_mode` is a USB round trip). |
| static helpers | `extend_desktop()`, `get_glasses_display()`, `claim_single_instance()`, `set/is_run_at_login()`, `set/is_native_window_shown()` |
| signals | `started`, `stopped`, `state_changed(state_id, value)` (2 = display mode changed) |

Only one `VitureGlasses` may run at a time (the SDK callbacks have no user pointer).

## Stereo

Set `stereo = true` on `VitureGlasses` and use `XROrigin3D` + `XRCamera3D` for the camera. This:

1. registers `VitureXRInterface` with `XRServer` and makes it primary,
2. sets `use_xr` on the viewport (Godot renders both eyes in one multiview pass),
3. switches the glasses to 3840x1080 side-by-side mode (takes ~4 s; `state_changed(2, mode)` fires when done).

The window must then be fullscreen on the glasses' 3840-wide screen. Windows treats each glasses mode as a
separate monitor, so apply Extend (Win+P, or `VitureGlasses.extend_desktop()`) once in that mode.

Projects need **Project Settings > XR > Shaders > Enabled** (`xr/shaders/enabled=true`).
2D `CanvasItem`s on the main viewport are not shown in stereo; use `Label3D` or a `SubViewport` on a quad.

`VitureXRInterface` tuning (defaults from the Luma Ultra spec):

| Property | Default | Notes |
| --- | --- | --- |
| `eye_separation` | `0.063` m | Your IPD. |
| `fov` | `52` deg | Diagonal field of view per eye. |
| `convergence_distance` | `3.0` m | Virtual screen distance: objects there have zero disparity. `0` = parallel eyes. |
| `vertical_offset` | `0` deg | Right eye's image above the left's. |

`demo/main.tscn` is the test scene: 3 toggles stereo; Left/Right convergence, Up/Down vertical offset,
[ / ] eye separation, Backspace resets; R recenter, T reset tracking, Tab next screen, F11 fullscreen.

## Platform notes

- **Capture** uses Windows Graphics Capture (C++/WinRT, so the build enables exceptions). DXGI Desktop
  Duplication doesn't work on hybrid-GPU laptops when the captured monitor is on the other GPU.
- **Display modes:** each glasses mode (2D/3D, 1080p/1200p, 60/120 Hz) appears to Windows as a separate
  monitor that may not be on the extended desktop yet; the app applies Extend after a mode switch.
- **Virtual monitors** come from SudoVDA and exist only while the app runs. The driver removes *all* its
  monitors (including other apps', e.g. Apollo's) if it isn't pinged for ~3 s, so a crash cleans up by itself.
- **Desktop layout:** Windows closes any gap between monitors, hence the cursor fence for the glasses.

## License

MIT; see [LICENSE](LICENSE). The VITURE Glasses SDK is not included and has its own terms (redistribution
needs VITURE's written permission). The SudoVDA control definitions in `src/virtual_displays.cpp` come from
[SudoMaker/SudoVDA](https://github.com/SudoMaker/SudoVDA) (MIT / CC0).
