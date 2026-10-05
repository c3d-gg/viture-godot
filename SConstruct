#!/usr/bin/env python
import os

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/", "thirdparty/viture-sdk-windows/include/"])
if env["platform"] == "windows":
    env.Append(LIBS=["setupapi"])

sources = Glob("src/*.cpp")

library = env.SharedLibrary(
    "demo/bin/libviture{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
