# TODO

Ideas for the virtual screen (remaking the useful parts of SpaceWalker) and the extension.

## Virtual screen

- [x] **Multiple virtual screens** — several pinned panels, each showing its own monitor; extra
      monitors come from the SudoVDA virtual display driver.
- [ ] **Arrange virtual monitors on the desktop** — Windows places new ones to the right of the
      glasses' display, so the mouse passes through the glasses to reach them. Position them next to
      the laptop screen (and the glasses out of the way) with `SetDisplayConfig`.
- [ ] **Single-window capture** — pin one app window (video, chat, doc) instead of a whole desktop.
      Windows Graphics Capture supports windows via `CreateForWindow`.
- [ ] **Sharper text** — better filtering/mipmaps or supersampling so small text stays readable at
      a distance.
- [ ] **Curved screen** — bend wide panels around the viewer so edges are as close as the centre.
- [ ] **Smooth-follow mode** — the screen drifts back in front of you after you turn away for a
      while; useful when walking around.
- [ ] **Auto-start** — launch when the glasses are plugged in or at login, living in the tray.
- [ ] **Hide the yellow capture border** — needs `GraphicsCaptureSession.IsBorderRequired(false)`,
      which requires a Windows SDK newer than the installed 10.0.19041.

## Tracking / anchoring

- [ ] **Visual marker anchor** — a printed (or phone-displayed) AprilTag/ArUco marker on the desk,
      detected with the glasses' tracking cameras and the SDK's OpenCV, so screens appear in the
      same physical spot every session regardless of startup heading.

## Distribution

- [ ] **Ask VITURE for redistribution rights** — the SDK license (in the Android SDK zip) says
      distribution is "prohibited unless explicitly permitted by a written agreement with VITURE
      Inc.", so releases can't bundle `glasses.dll` / `carina_vio.dll`. Email their developer program
      asking to ship the runtime DLLs with this open-source app.
- [ ] **SDK-free build** — declare the SDK functions ourselves again (as in the first version) so the
      extension compiles without VITURE's headers, e.g. in GitHub Actions. Running it still needs
      the SDK DLLs until VITURE agrees to redistribution.

## Stereo

- [ ] **Stereo alignment** — side-by-side 3D works but looked "a little off"; revisit with the
      convergence / vertical / IPD tuning keys in `demo/main.tscn`.
