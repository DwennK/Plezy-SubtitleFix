#!/usr/bin/env python3
"""Build or verify the pinned, self-contained capture and inference runtime."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
from pathlib import Path

from prepare_native import checkout, digest, download_model

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "native/live_subtitle_sync"


def settings(target, profile="cpu"):
    if profile not in ("cpu", "metal") or (profile == "metal" and target != "macos-arm64"):
        raise ValueError("Metal inference is only supported on macOS arm64")
    manifest = json.loads((ROOT / "docs/live-subtitle-sync-versions.json").read_text())
    if target == "macos-arm64":
        include = ROOT / "macos/LiveSyncMPV/Artifacts/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers"
        names = ["liblivesync_capture_bridge.dylib", "liblivesync_inference_bridge.dylib"]
    elif target == "windows-x64":
        include = ROOT / "windows/LiveSyncMPV/include"
        names = ["livesync_capture_bridge.dll", "livesync_inference_bridge.dll", "livesync_inference_bridge_avx2.dll"]
    else:
        raise ValueError("Unsupported analysis runtime target")
    sources = sorted([*NATIVE.glob("*.cpp"), *NATIVE.glob("*.h"), NATIVE / "CMakeLists.txt", NATIVE / "SILERO-LICENSE", Path(__file__), ROOT / "scripts/livesync/embed_speech_model.py"])
    hasher = hashlib.sha256()
    for source in sources:
        hasher.update(str(source.relative_to(ROOT)).replace("\\", "/").encode() + b"\0" + source.read_bytes())
    return include, names, {
        "schema": 1, "target": target,
        "profile": ("metal-preferred-with-cpu-fallback" if profile == "metal" else
                    "portable-and-guarded-avx2-cpu" if target == "windows-x64" else "portable-cpu"),
        "captureAbi": 1, "inferenceAbi": 2,
        "speechDetectorSha256": manifest["speechDetector"]["sha256"],
        "whisperRevision": manifest["whisper"]["revision"], "mpvRevision": manifest["native"]["commit"],
        "mpvHeaderSha256": digest(include / "mpv/client.h"), "sourceSha256": hasher.hexdigest(),
    }


def verify(target, profile=None):
    directory = ROOT / "build/livesync/runtime" / target
    record = json.loads((directory / "provenance.json").read_text())
    # The Xcode embed phase verifies the explicitly built profile. Build callers
    # can require one profile; unknown labels still fail exact input comparison.
    if profile is None:
        profile = "metal" if record["inputs"]["profile"] == "metal-preferred-with-cpu-fallback" else "cpu"
    _, names, expected = settings(target, profile)
    if record["inputs"] != expected or set(record["files"]) != set(names + ["whisper-ggml-LICENSE", "SILERO-LICENSE"]):
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
    parser.add_argument("--profile", choices=["cpu", "metal"],
                        help="Build defaults to CPU; verification defaults to the recorded supported profile")
    parser.add_argument("--whisper-source", type=Path)
    parser.add_argument("--cmake", default="cmake")
    args = parser.parse_args()
    if args.verify:
        print(verify(args.target, args.profile))
        return
    host = (platform.system(), platform.machine().lower())
    if (args.target == "macos-arm64" and host != ("Darwin", "arm64")) or (
        args.target == "windows-x64" and host not in [("Windows", "amd64"), ("Windows", "x86_64")]
    ):
        raise ValueError("Build this runtime on its target architecture")
    profile = args.profile or "cpu"
    include, names, inputs = settings(args.target, profile)
    manifest = json.loads((ROOT / "docs/live-subtitle-sync-versions.json").read_text())
    speech_model = download_model(manifest["speechDetector"], ROOT / "build/livesync/models")
    source = checkout("https://github.com/ggml-org/whisper.cpp.git", inputs["whisperRevision"],
                      args.whisper_source or ROOT / "build/livesync/whisper-source")
    subprocess.run(["git", "-C", str(source), "diff", "--exit-code", "HEAD", "--"], check=True)
    build = ROOT / "build/livesync" / ("analysis-build-" + args.target)
    metal = "ON" if profile == "metal" else "OFF"
    configure = [args.cmake, "-S", str(NATIVE), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
                 f"-DLIVESYNC_USE_METAL={metal}", f"-DGGML_METAL={metal}", "-DGGML_METAL_EMBED_LIBRARY=ON",
                 "-DGGML_VULKAN=OFF", "-DGGML_CUDA=OFF", "-DGGML_BLAS=OFF", "-DGGML_OPENMP=OFF",
                 "-DLIVESYNC_CPU_PROFILE=portable", f"-DLIVESYNC_WHISPER_SOURCE={source}",
                 f"-DLIVESYNC_MPV_INCLUDE={include}", f"-DLIVESYNC_SPEECH_MODEL={speech_model}"]
    if args.target == "macos-arm64":
        configure += ["-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"]
    subprocess.run(configure, check=True)
    subprocess.run([args.cmake, "--build", str(build), "--config", "Release", "--parallel", "3",
                    "--target", "livesync_capture_bridge", "livesync_inference_bridge"], check=True)
    binaries = build / "Release" if args.target == "windows-x64" else build
    directory = ROOT / "build/livesync/runtime" / args.target
    directory.mkdir(parents=True, exist_ok=True)
    paths = {name: binaries / name for name in names[:2]}
    accelerated_configure = None
    if args.target == "windows-x64":
        accelerated_build = ROOT / "build/livesync/analysis-build-windows-x64-avx2"
        accelerated_configure = [
            str(accelerated_build) if value == str(build) else
            "-DLIVESYNC_CPU_PROFILE=guarded-avx2" if value == "-DLIVESYNC_CPU_PROFILE=portable" else value
            for value in configure
        ]
        subprocess.run(accelerated_configure, check=True)
        subprocess.run([args.cmake, "--build", str(accelerated_build), "--config", "Release", "--parallel", "3",
                        "--target", "livesync_inference_bridge"], check=True)
        paths["livesync_inference_bridge_avx2.dll"] = accelerated_build / "Release/livesync_inference_bridge.dll"
    paths.update({"whisper-ggml-LICENSE": source / "LICENSE", "SILERO-LICENSE": NATIVE / "SILERO-LICENSE"})
    for name, path in paths.items():
        temporary = directory / (name + ".partial")
        shutil.copyfile(path, temporary)
        temporary.replace(directory / name)
    record = {"inputs": inputs, "files": {name: digest(directory / name) for name in paths},
              "cmakeVersion": subprocess.check_output([args.cmake, "--version"], text=True).splitlines()[0],
              "configureArguments": configure[5:],
              "acceleratedConfigureArguments": accelerated_configure[5:] if accelerated_configure else None}
    temporary = directory / "provenance.partial"
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(directory / "provenance.json")
    print(verify(args.target, profile))


if __name__ == "__main__":
    main()
