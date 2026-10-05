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
   tools\godot\Godot_v4.5.1-stable_win64_console.exe --path demo
   ```

   Tab moves the window to the next monitor (the glasses), F11 toggles fullscreen,
   R recenters (yaw + position), T resets VIO tracking.

## VitureGlasses node

| Member | Notes |
| --- | --- |
| `library_path` | Default `res://bin/viture/glasses.dll`; exported games look beside the .exe. |
| `product_id` | `0` auto-detects over USB (Luma Ultra is `0x1104`). |
| `target` | Node3D (usually the Camera3D) driven by the head pose each frame. |
| `enable_6dof` | Luma Ultra only, applied at `start()`: include position from host VIO. |
| `prediction_ms` | Pose prediction passed to `get_gl_pose_carina`. |
| `start()` / `stop()` | Auto-start happens in `_ready` (never in the editor). |
| `get_pose()` | `Transform3D` in Godot axes. |
| `recenter()` | Re-anchors heading and position (horizon stays level). Done automatically on the first pose. |
| `reset_tracking()` | Luma Ultra: restarts VIO (`reset_pose_carina`). |
| `is_tracking_stable()` | Luma Ultra `pose_status == 0`. |
| `set_display_3d(bool)` | Switches the glasses between 2D and 3840x1080 side-by-side 3D. |
| `get/set_brightness`, `get/set_display_mode` | Raw SDK display controls. |
| signals | `started`, `stopped`, `state_changed(state_id, value)` |

Only one `VitureGlasses` may run at a time (the SDK callbacks have no user pointer).
