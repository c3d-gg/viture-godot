#!/usr/bin/env python
import os

# DesktopCapture uses C++/WinRT, which requires exceptions (godot-cpp
# disables them by default).
ARGUMENTS.setdefault("disable_exceptions", "no")

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/", "thirdparty/viture-sdk-windows/include/"])
if env["platform"] == "windows":
    env.Append(LIBS=["setupapi", "d3d11", "dxgi", "windowsapp", "user32", "winmm", "advapi32"])

sources = Glob("src/*.cpp")

library = env.SharedLibrary(
    "demo/bin/libviture{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
