#!/usr/bin/env python3
"""Wrap the built static mpv in a test dylib using its actual link dependencies.

This does not alter the distributed XCFramework. It exposes exactly the same
archive objects to the Python capture probe without a Flutter UI dependency.
Read Meson build metadata without reconfiguring or rebuilding the library.
"""

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True, help="mpv Meson scratch directory for the selected arch")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    output = args.output.resolve()
    # Only accept metadata from our locally built pinned checkout, never from
    # an arbitrary downloaded build directory. No shell interpretation is used.
    targets = json.loads((build / "meson-info/intro-targets.json").read_text())
    target = next(t for t in targets if t["name"] == "mpv" and t["type"] == "static library")
    selected = set(target["dependencies"])
    dependencies = json.loads((build / "meson-info/intro-dependencies.json").read_text())
    flags = [arg for dep in dependencies if dep["name"] in selected for arg in dep.get("link_args", [])]
    # The pkg-config file also contains mpv's own platform framework flags.
    # Introspection alone collapses repeated appleframeworks entries. Do not
    # re-run pkg-config: that could resolve host libraries instead of the ones
    # actually selected by the upstream build for this architecture.
    pc = (build / "meson-private/mpv.pc").read_text().splitlines()
    own = next(line.removeprefix("Libs: ") for line in pc if line.startswith("Libs: "))
    flags.extend(arg for arg in shlex.split(own) if arg not in ("-L${libdir}", "-lmpv"))
    if any("${" in arg for arg in flags):
        raise RuntimeError("Unexpected unresolved pkg-config variable; inspect the pinned build")
    options = json.loads((build / "meson-info/intro-buildoptions.json").read_text())
    link_options = next(o["value"] for o in options if o["name"] == "c_link_args")
    if "-arch" not in link_options or link_options[link_options.index("-arch") + 1] != args.arch:
        raise RuntimeError("The requested architecture does not match this native build")
    flags.extend(link_options)
    # mpv's Swift object also needs the same runtime search paths added by
    # osdep/mac/meson.build. Ask upstream's helper instead of hardcoding Xcode.
    source = Path(target["defined_in"]).parent
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    swift_lib = subprocess.check_output(
        [sys.executable, str(source / "TOOLS/macos-swift-lib-directory.py"), swift], text=True).strip()
    flags.extend(["-L" + swift_lib, "-L/usr/lib/swift", "-Xlinker", "-rpath", "-Xlinker", swift_lib,
                  "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["clang", "-dynamiclib", "-arch", args.arch, "-o", str(output),
                    "-Wl,-force_load," + str(build / "libmpv.a"), *flags], cwd=build, check=True)


if __name__ == "__main__":
    main()
