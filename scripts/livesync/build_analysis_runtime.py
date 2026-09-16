#!/usr/bin/env python3
"""Build or verify the pinned, self-contained capture and CPU inference runtime."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
from pathlib import Path

from prepare_native import checkout, digest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "native/live_subtitle_sync"


def settings(target):
    manifest = json.loads((ROOT / "docs/live-subtitle-sync-versions.json").read_text())
    if target == "macos-arm64":
        include = ROOT / "macos/LiveSyncMPV/Artifacts/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers"
        names = ["liblivesync_capture_bridge.dylib", "liblivesync_inference_bridge.dylib"]
    elif target == "windows-x64":
        include = ROOT / "windows/LiveSyncMPV/include"
        names = ["livesync_capture_bridge.dll", "livesync_inference_bridge.dll"]
    else:
        raise ValueError("Unsupported analysis runtime target")
    sources = sorted([*NATIVE.glob("*.cpp"), *NATIVE.glob("*.h"), NATIVE / "CMakeLists.txt", Path(__file__)])
    hasher = hashlib.sha256()
    for source in sources:
        hasher.update(str(source.relative_to(ROOT)).replace("\\", "/").encode() + b"\0" + source.read_bytes())
    return include, names, {
        "schema": 1, "target": target, "profile": "portable-cpu", "captureAbi": 1, "inferenceAbi": 1,
        "whisperRevision": manifest["whisper"]["revision"], "mpvRevision": manifest["native"]["commit"],
        "mpvHeaderSha256": digest(include / "mpv/client.h"), "sourceSha256": hasher.hexdigest(),
    }


def verify(target):
    _, names, expected = settings(target)
    directory = ROOT / "build/livesync/runtime" / target
    record = json.loads((directory / "provenance.json").read_text())
    if record["inputs"] != expected or set(record["files"]) != set(names + ["whisper-ggml-LICENSE"]):
        raise ValueError("Analysis runtime inputs changed; rebuild before packaging")
    for name, checksum in record["files"].items():
        path = directory / name
        if path.is_symlink() or digest(path) != checksum:
            raise ValueError("Analysis runtime file checksum mismatch")
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=["macos-arm64", "windows-x64"])
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--whisper-source", type=Path)
    parser.add_argument("--cmake", default="cmake")
    args = parser.parse_args()
    if args.verify:
        print(verify(args.target))
        return
    host = (platform.system(), platform.machine().lower())
    if (args.target == "macos-arm64" and host != ("Darwin", "arm64")) or (
        args.target == "windows-x64" and host not in [("Windows", "amd64"), ("Windows", "x86_64")]
    ):
        raise ValueError("Build this runtime on its target architecture")
    include, names, inputs = settings(args.target)
    source = checkout("https://github.com/ggml-org/whisper.cpp.git", inputs["whisperRevision"],
                      args.whisper_source or ROOT / "build/livesync/whisper-source")
    subprocess.run(["git", "-C", str(source), "diff", "--exit-code", "HEAD", "--"], check=True)
    build = ROOT / "build/livesync" / ("analysis-build-" + args.target)
    configure = [args.cmake, "-S", str(NATIVE), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
                 "-DGGML_METAL=OFF", "-DGGML_VULKAN=OFF", "-DGGML_CUDA=OFF", "-DGGML_BLAS=OFF", "-DGGML_OPENMP=OFF",
                 "-DLIVESYNC_CPU_PROFILE=portable", f"-DLIVESYNC_WHISPER_SOURCE={source}",
                 f"-DLIVESYNC_MPV_INCLUDE={include}"]
    if args.target == "macos-arm64":
        configure += ["-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"]
    subprocess.run(configure, check=True)
    subprocess.run([args.cmake, "--build", str(build), "--config", "Release", "--parallel", "3",
                    "--target", "livesync_capture_bridge", "livesync_inference_bridge"], check=True)
    binaries = build / "Release" if args.target == "windows-x64" else build
    directory = ROOT / "build/livesync/runtime" / args.target
    directory.mkdir(parents=True, exist_ok=True)
    paths = {name: binaries / name for name in names}
    paths.update({"whisper-ggml-LICENSE": source / "LICENSE"})
    for name, path in paths.items():
        temporary = directory / (name + ".partial")
        shutil.copyfile(path, temporary)
        temporary.replace(directory / name)
    record = {"inputs": inputs, "files": {name: digest(directory / name) for name in paths},
              "cmakeVersion": subprocess.check_output([args.cmake, "--version"], text=True).splitlines()[0],
              "configureArguments": configure[5:]}
    temporary = directory / "provenance.partial"
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(directory / "provenance.json")
    print(verify(args.target))


if __name__ == "__main__":
    main()
