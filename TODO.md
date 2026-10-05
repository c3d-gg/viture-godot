# TODO

The virtual-screens app remakes the useful parts of VITURE's SpaceWalker. Suggested order for what's next:
**curved screens → smooth-follow → standalone .exe**, then the larger projects.

## Next up

### Curved screens
Bend wide screens (ultrawide virtual monitors especially) around the viewer so the edges are as far away as
the centre.
- `ScreenPanel`: replace the `QuadMesh` with a generated cylinder-segment mesh (an `ArrayMesh` strip, ~32
  columns) of radius = `distance`, spanning `width / distance` radians, centred on -Z. UVs run 0..1 across.
- Add a per-screen `curve` amount (0 = flat .. 1 = full cylinder at `distance`) to the settings window and the
  saved dict; flat stays the default for 16:9 screens.
- Snapping and line-up use `half_extent()` (angle across the width); for a curved screen that's
  `width / (2 * distance)` exactly, so line-up stays flush.
- The shader's filtering uses screen-space derivatives, so it keeps working on a curved mesh.

### Smooth-follow mode
Screens (or one "follow" group) drift back in front of you after you turn away for a while: useful when
walking around.
- Per-screen `follow` flag. When the screen's centre has been more than ~35 deg from your gaze for ~1.5 s,
  ease its yaw (and optionally pitch) towards the gaze with an exponential smoothing factor; stop when
  within ~5 deg. Keep the screen's relative layout if several follow together (rotate the group).
- Position follows head translation too (`pin_origin` eases towards the head position) so it works while
  walking.
- Toggle per screen in settings; a tray/hotkey toggle for "follow mode on/off" for all.

### Standalone .exe
The app currently runs through the Godot editor binary in `tools/`, which Start with Windows depends on.
- Install the Godot 4.5.1 export templates, add an export preset for Windows (`export_presets.cfg`), and a
  release build of the extension (`target=template_release`; the `.gdextension` already lists it).
- The SDK DLLs must sit next to the exported .exe (`VitureGlasses.resolve_library_path` already looks there).
  Add a `[dependencies]` section to `viture.gdextension`, or a post-export copy step.
- `_launch_command()` should use the exported .exe when not running from the editor binary.
- Tray icon: a real `.ico` for the exe and tray instead of the generated texture.
- Can't be published with VITURE's DLLs until redistribution is sorted (see Distribution).

## Virtual screen

- [x] **Multiple virtual screens**: SudoVDA virtual monitors, any resolution.
- [x] **Arrange virtual monitors on the desktop** to match the room, with a cursor fence on the glasses.
- [x] **Single-window capture**: Ctrl+Alt+Shift+P pins the window you're using.
- [x] **Sharper text**: filtering, sharpness, pixel-perfect size, match resolution.
- [x] **Auto-start**: waits in the tray for the glasses; Start with Windows.
- [x] **Grab, snap and line up** screens, flush in tilted rows.
- [ ] **Curved screens**: see Next up.
- [ ] **Smooth-follow mode**: see Next up.
- [ ] **Hide the yellow capture border**: `GraphicsCaptureSession.IsBorderRequired(false)` needs a Windows
      SDK newer than the installed 10.0.19041 (22000+). Install a newer SDK and point the build at it, or
      query `IGraphicsCaptureSession3` manually. Unpackaged apps may also need
      `GraphicsCaptureAccess.RequestAccessAsync(Borderless)`.
- [ ] **Window capture without the title bar**: crop the frame to the window's client area (from
      `GetClientRect` + `ClientToScreen` relative to `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`).
- [ ] **Per-screen brightness/opacity**, e.g. dim a video screen while working.

## Tracking / anchoring

- [ ] **Visual marker anchor**: an AprilTag/ArUco marker on the desk (printed, or shown on a phone screen,
      which usually works fine), detected in the glasses' grayscale tracking cameras via the SDK's camera
      callback (`xr_device_provider_register_callbacks_carina`) and OpenCV (`opencv_world4100.dll` ships with
      the SDK). Store screen placements relative to the marker so they appear in the same physical spot every
      session, regardless of startup heading or drift.

## Distribution

- [ ] **Ask VITURE for redistribution rights**: the SDK license (in the Android SDK zip) says distribution
      is "prohibited unless explicitly permitted by a written agreement with VITURE Inc.", so releases can't
      bundle `glasses.dll` / `carina_vio.dll`. Email their developer program asking to ship the runtime DLLs
      with this open-source app.
- [ ] **SDK-free build**: declare the SDK functions ourselves again (as in the first version) so the
      extension compiles without VITURE's headers, e.g. in GitHub Actions. Running it still needs the SDK
      DLLs until VITURE agrees to redistribution.

## Stereo

- [ ] **Stereo alignment**: side-by-side 3D works but looked "a little off". Revisit with the convergence /
      vertical / IPD tuning keys in `demo/main.tscn`; the user's problem turned out to be fit/eyebox, which
      the pinned virtual screen solved, so this is lower priority.
