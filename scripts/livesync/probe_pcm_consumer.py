#!/usr/bin/env python3
"""Send real decoder packets through the native 16 kHz consumer, in memory.

Only synthetic fixture audio is used. Writes summary measurements, not captured
PCM. Null audio output does not validate audible playback or the app worker.
"""

import argparse
import ctypes as C
import json
import math
from pathlib import Path
import time

from probe_pcm import Player, create_fixture


class WindowInfo(C.Structure):
    _fields_ = [("generation", C.c_uint64), ("continuity", C.c_uint64),
                ("media_start", C.c_double), ("media_seconds_per_sample", C.c_double)]


class NativeConsumer:
    def __init__(self, library):
        self.lib = lib = C.CDLL(str(Path(library).resolve()))
        lib.ls_pcm_create.argtypes = []
        lib.ls_pcm_create.restype = C.c_void_p
        lib.ls_pcm_destroy.argtypes = [C.c_void_p]
        lib.ls_pcm_destroy.restype = None
        lib.ls_pcm_reset.argtypes = [C.c_void_p, C.c_uint64]
        lib.ls_pcm_reset.restype = None
        lib.ls_pcm_append.argtypes = [C.c_void_p, C.c_uint64, C.c_int64, C.c_double, C.c_double,
                                     C.c_int, C.c_int, C.c_int, C.c_int, C.c_char_p, C.c_void_p, C.c_size_t]
        lib.ls_pcm_append.restype = C.c_int
        lib.ls_pcm_snapshot.argtypes = [C.c_void_p, C.c_double, C.POINTER(C.c_float), C.c_size_t, C.POINTER(WindowInfo)]
        lib.ls_pcm_snapshot.restype = C.c_size_t
        self.handle = lib.ls_pcm_create()
        assert self.handle, "Consumer allocation failed"

    def reset(self, generation):
        self.lib.ls_pcm_reset(self.handle, generation)

    def append(self, packet, generation):
        assert packet["version"] == 1
        for frame in packet["frames"]:
            data = C.create_string_buffer(frame["pcm"])
            result = self.lib.ls_pcm_append(self.handle, generation, packet["epoch"], frame["pts"],
                                           frame["speed"], frame["rate"], frame["channels"],
                                           frame["samples"], frame["planes"], frame["format"].encode(),
                                           data, len(frame["pcm"]))
            assert result == 0, f"Consumer rejected native packet: {result}"

    def snapshot(self):
        output = (C.c_float * 240000)()
        info = WindowInfo()
        count = self.lib.ls_pcm_snapshot(self.handle, 15, output, len(output), C.byref(info))
        return info, output[:count]

    def close(self):
        if self.handle:
            self.lib.ls_pcm_destroy(self.handle)
            self.handle = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = args.output / "synthetic-317-691hz.wav"
    create_fixture(fixture)
    consumer = NativeConsumer(args.consumer)
    player = Player(args.library)
    report = {"kind": "real-decoder-native-resampler-null-output", "audiblePlaybackValidated": False, "windows": []}
    try:
        player.command("loadfile", fixture.resolve())
        deadline = time.monotonic() + 10
        while True:
            try:
                player.set("livesync-enabled", "yes")
                break
            except RuntimeError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.05)
        for generation, seek in ((1, None), (2, 7), (3, 2)):
            consumer.reset(generation)
            if seek is not None:
                player.command("seek", seek, "absolute+exact")
            deadline = time.monotonic() + 0.7
            frames, conversion_seconds = 0, 0
            while time.monotonic() < deadline:
                packet = player.get("livesync-pcm")
                started = time.perf_counter()
                consumer.append(packet, generation)
                conversion_seconds += time.perf_counter() - started
                frames += len(packet["frames"])
                time.sleep(0.02)
            info, output = consumer.snapshot()
            count = len(output)
            assert frames > 0 and count > 5000
            assert info.generation == generation
            assert abs(info.media_seconds_per_sample - 1 / 16000) < 1e-12
            worst = 0
            for i in range(0, count, 7):
                t = info.media_start + i * info.media_seconds_per_sample
                expected = (12000 * math.sin(2 * math.pi * 317 * t) + 8000 * math.sin(2 * math.pi * 691 * t)) / 65536
                worst = max(worst, abs(output[i] - expected))
            assert worst < 0.001, f"Resampled PCM not aligned to media timestamps: {worst}"
            if seek is not None:
                assert abs(info.media_start - seek) < 0.2, "Old seek audio survived"
            report["windows"].append({"generation": generation, "continuity": info.continuity,
                                      "mediaStart": info.media_start, "samples": count,
                                      "maximumSampleError": worst, "frames": frames,
                                      "conversionSeconds": conversion_seconds})
        player.set("livesync-enabled", "no")
    finally:
        player.close()
        consumer.close()
    (args.output / "consumer-probe.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Real native PCM -> float32 mono 16 kHz consumer passed across forward/backward seeks.")


if __name__ == "__main__":
    main()
