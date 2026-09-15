#!/usr/bin/env python3
"""Exercise the actual native polling thread and borrowed-player client lifetime.

Uses the pinned decoder and a synthetic fixture; no captured PCM is persisted.
The null output does not prove audible playback or the production app lifecycle.
"""

import argparse
import ctypes as C
import json
import math
from pathlib import Path
import threading
import time

from probe_pcm import Player, create_fixture
from probe_pcm_consumer import WindowInfo


class MpvApi(C.Structure):
    _fields_ = [("version", C.c_uint32)] + [(name, C.c_void_p) for name in
               ("get_property", "set_property_string", "free_node_contents", "wait_event", "destroy")]


class CaptureInfo(C.Structure):
    _fields_ = [("generation", C.c_uint64), ("continuity", C.c_uint64),
                ("samples", C.c_uint64), ("state", C.c_uint32)]


def wait_for(predicate, label, seconds=5):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(label)
        time.sleep(0.025)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--capture", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = args.output / "synthetic-317-691hz.wav"
    create_fixture(fixture)
    player = Player(args.library)
    player.lib.mpv_create_weak_client.argtypes = [C.c_void_p, C.c_char_p]
    player.lib.mpv_create_weak_client.restype = C.c_void_p
    player.lib.mpv_destroy.argtypes = [C.c_void_p]
    player.lib.mpv_destroy.restype = None
    api = MpvApi(1, *[C.cast(getattr(player.lib, "mpv_" + name), C.c_void_p).value
                     for name, _ in MpvApi._fields_[1:]])
    lib = C.CDLL(str(Path(args.capture).resolve()))
    for name in ("api_size", "info_size"):
        getattr(lib, "ls_capture_" + name).restype = C.c_size_t
    assert lib.ls_capture_abi_version() == 1
    assert lib.ls_capture_api_size() == C.sizeof(MpvApi)
    assert lib.ls_capture_info_size() == C.sizeof(CaptureInfo)
    for name, result, arguments in [
        ("create", C.c_void_p, [C.c_void_p, C.POINTER(MpvApi), C.c_uint64]),
        ("destroy", None, [C.c_void_p]),
        ("reset", C.c_int, [C.c_void_p, C.c_uint64]),
        ("get_info", C.c_int, [C.c_void_p, C.POINTER(CaptureInfo), C.c_size_t]),
        ("snapshot", C.c_size_t, [C.c_void_p, C.c_double, C.POINTER(C.c_float), C.c_size_t, C.POINTER(WindowInfo)]),
    ]:
        function = getattr(lib, "ls_capture_" + name)
        function.restype, function.argtypes = result, arguments
    capture = None
    closed = False
    closer = None
    report = {"kind": "native-polling-thread-and-weak-client", "windows": [],
              "audiblePlaybackValidated": False, "productionAppValidated": False,
              "retainedCapturedAudio": False}
    try:
        player.command("loadfile", fixture.resolve())
        weak = player.lib.mpv_create_weak_client(player.handle, b"livesync_capture_test")
        assert weak
        capture = lib.ls_capture_create(weak, C.byref(api), 1)
        if not capture:
            player.lib.mpv_destroy(weak)
            raise AssertionError("Capture creation failed")

        def info():
            result = CaptureInfo()
            assert lib.ls_capture_get_info(capture, C.byref(result), C.sizeof(result)) == 0
            return result

        # Rejection leaves client ownership with the caller, and must not stop
        # the original capture or the underlying player.
        duplicate = player.lib.mpv_create_weak_client(player.handle, b"livesync_duplicate")
        assert duplicate
        assert not lib.ls_capture_create(duplicate, C.byref(api), 1)
        player.lib.mpv_destroy(duplicate)
        report["singleCaptureEnforced"] = True
        previous_continuity = 0
        for generation, seek in ((1, None), (2, 7), (3, 2)):
            if seek is not None:
                assert lib.ls_capture_reset(capture, generation) == 0
                player.command("seek", seek, "absolute+exact")
            wait_for(lambda: info().samples > 6000 and info().continuity > previous_continuity,
                     "Native capture did not acquire fresh PCM")
            metadata = WindowInfo()
            samples = (C.c_float * 240000)()
            count = lib.ls_capture_snapshot(capture, 15, samples, len(samples), C.byref(metadata))
            assert 6000 < count <= 240000
            assert metadata.generation == generation
            worst = 0
            for i in range(0, count, 11):
                t = metadata.media_start + i * metadata.media_seconds_per_sample
                expected = (12000 * math.sin(2 * math.pi * 317 * t) + 8000 * math.sin(2 * math.pi * 691 * t)) / 65536
                worst = max(worst, abs(samples[i] - expected))
            assert worst < 0.001, f"Native polling lost PCM/media correspondence: {worst}"
            if seek is not None:
                assert abs(metadata.media_start - seek) < 0.2, f"Expected {seek}, got {metadata.media_start}, gen={metadata.generation}, continuity={metadata.continuity}"
            previous_continuity = metadata.continuity
            report["windows"].append({"generation": generation, "continuity": metadata.continuity,
                                      "samples": count, "mediaStart": metadata.media_start,
                                      "maximumSampleError": worst})

        player.set("pause", "yes")
        time.sleep(0.25)
        paused = info().samples
        time.sleep(0.2)
        assert info().samples == paused, "Pause generated additional captured PCM"
        report["pauseStable"] = True
        # Parent destruction blocks until weak clients release. The native
        # polling thread must observe SHUTDOWN and release without a Dart call.
        closer = threading.Thread(target=player.close, daemon=True)
        started = time.monotonic()
        closer.start()
        closer.join(5)
        assert not closer.is_alive(), "Parent teardown blocked on the capture's weak client"
        closed = True
        wait_for(lambda: info().state == 4, "Capture did not report shutdown")
        assert info().samples == 0
        assert lib.ls_capture_reset(capture, 4) == -1
        report["parentShutdownSeconds"] = time.monotonic() - started
        report["shutdownClearsPcm"] = True
    finally:
        if capture:
            lib.ls_capture_destroy(capture)
        if closer is not None:
            closer.join(5)
            if closer.is_alive():
                raise RuntimeError("Parent teardown still blocked after capture cleanup")
        elif not closed:
            player.close()
    (args.output / "capture-owner.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Native capture thread, seeks, pause, exclusive ownership and parent shutdown passed.")


if __name__ == "__main__":
    main()
