#!/usr/bin/env python3
"""Exercise the real patched libmpv decoder with synthetic local PCM.

This headless test uses mpv's paced null audio output. It proves decoder capture
and media timestamps, not audible playback, native UI, or GPU performance.
"""

import argparse
import ctypes as C
import json
import math
import os
from pathlib import Path
import struct
import time
import wave


class Node(C.Structure):
    pass


class NodeList(C.Structure):
    _fields_ = [("num", C.c_int), ("values", C.POINTER(Node)), ("keys", C.POINTER(C.c_char_p))]


class ByteArray(C.Structure):
    _fields_ = [("data", C.c_void_p), ("size", C.c_size_t)]


class Value(C.Union):
    _fields_ = [("string", C.c_char_p), ("flag", C.c_int), ("int64", C.c_int64),
                ("double", C.c_double), ("list", C.POINTER(NodeList)), ("ba", C.POINTER(ByteArray))]


Node._fields_ = [("u", Value), ("format", C.c_int)]


def decode(n):
    if n.format == 1:
        return n.u.string.decode()
    if n.format == 3:
        return bool(n.u.flag)
    if n.format == 4:
        return n.u.int64
    if n.format == 5:
        return n.u.double
    if n.format in (7, 8):
        data = n.u.list.contents
        values = [decode(data.values[i]) for i in range(data.num)]
        return dict(zip([data.keys[i].decode() for i in range(data.num)], values)) if n.format == 8 else values
    if n.format == 9:
        data = n.u.ba.contents
        return C.string_at(data.data, data.size)
    raise ValueError(f"Unexpected mpv node type {n.format}")


class Player:
    def __init__(self, library):
        library = Path(library).resolve()
        self.dll_directory = os.add_dll_directory(str(library.parent)) if os.name == "nt" else None
        self.lib = C.CDLL(str(library))
        for name, result, arguments in [
            ("mpv_create", C.c_void_p, []),
            ("mpv_initialize", C.c_int, [C.c_void_p]),
            ("mpv_set_option_string", C.c_int, [C.c_void_p, C.c_char_p, C.c_char_p]),
            ("mpv_set_property_string", C.c_int, [C.c_void_p, C.c_char_p, C.c_char_p]),
            ("mpv_get_property", C.c_int, [C.c_void_p, C.c_char_p, C.c_int, C.c_void_p]),
            ("mpv_command", C.c_int, [C.c_void_p, C.POINTER(C.c_char_p)]),
            ("mpv_free_node_contents", None, [C.POINTER(Node)]),
            ("mpv_terminate_destroy", None, [C.c_void_p]),
        ]:
            fn = getattr(self.lib, name)
            fn.restype, fn.argtypes = result, arguments
        self.handle = self.lib.mpv_create()
        if not self.handle:
            raise RuntimeError("mpv_create failed")
        for key, value in {"config": "no", "vo": "null", "ao": "null", "idle": "yes",
                           "terminal": "no", "keep-open": "yes", "audio-display": "no"}.items():
            self.check(self.lib.mpv_set_option_string(self.handle, key.encode(), value.encode()))
        self.check(self.lib.mpv_initialize(self.handle))

    @staticmethod
    def check(result):
        if result < 0:
            raise RuntimeError(f"libmpv operation failed ({result})")

    def set(self, key, value):
        self.check(self.lib.mpv_set_property_string(self.handle, key.encode(), str(value).encode()))

    def get(self, key):
        node = Node()
        self.check(self.lib.mpv_get_property(self.handle, key.encode(), 6, C.byref(node)))
        try:
            return decode(node)
        finally:
            self.lib.mpv_free_node_contents(C.byref(node))

    def command(self, *args):
        strings = [str(a).encode() for a in args] + [None]
        self.check(self.lib.mpv_command(self.handle, (C.c_char_p * len(strings))(*strings)))

    def close(self):
        self.lib.mpv_terminate_destroy(self.handle)
        if self.dll_directory:
            self.dll_directory.close()


def create_fixture(path):
    # Different channels prove plane/interleaving order, not just nonzero data.
    with wave.open(str(path), "wb") as output:
        output.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        for start in range(0, 12 * 48000, 4800):
            data = bytearray()
            for i in range(start, start + 4800):
                data.extend(struct.pack("<hh", int(12000 * math.sin(2 * math.pi * 317 * i / 48000)),
                                        int(8000 * math.sin(2 * math.pi * 691 * i / 48000))))
            output.writeframes(data)


def check_frame(frame):
    assert frame["rate"] == 48000 and frame["channels"] == 2, frame
    assert frame["format"] in ("s16", "s16p"), frame["format"]
    samples = frame["samples"]
    data = struct.unpack("<" + "h" * (samples * 2), frame["pcm"])
    start = round(frame["pts"] * 48000)
    assert abs(start / 48000 - frame["pts"]) < 1e-7, "PTS off sample grid"
    worst = 0
    for i in range(0, samples, 17):
        for channel, frequency, amplitude in ((0, 317, 12000), (1, 691, 8000)):
            index = channel * samples + i if frame["planes"] == 2 else i * 2 + channel
            expected = int(amplitude * math.sin(2 * math.pi * frequency * (start + i) / 48000))
            worst = max(worst, abs(expected - data[index]))
    assert worst <= 1, f"PCM does not match its media PTS: max error {worst}"
    return {"pts": frame["pts"], "samples": samples, "maximumSampleError": worst}


def collect(player, duration=0.6, after_epoch=None):
    # mpv's seek command queues the operation (MPSEEK_FLAG_DELAY). Its return
    # does not mean the decoder has reset yet. Validate and record in-flight
    # packets separately, then require a newer epoch within a bounded wait.
    deadline = time.monotonic() + duration if after_epoch is None else None
    reset_deadline = time.monotonic() + 2
    records, epochs = [], set()
    transition_epochs, transition_frames = set(), 0
    while deadline is None or time.monotonic() < deadline:
        assert deadline is not None or time.monotonic() < reset_deadline, "Seek did not reset PCM within 2 seconds"
        result = player.get("livesync-pcm")
        assert result["version"] == 1
        assert len(result["frames"]) <= 64
        assert sum(len(f["pcm"]) for f in result["frames"]) <= 262144
        checked = [check_frame(frame) for frame in result["frames"]]
        if after_epoch is not None and result["epoch"] <= after_epoch:
            assert deadline is None, "PCM epoch regressed after seek reset"
            transition_epochs.add(result["epoch"])
            transition_frames += len(checked)
        else:
            if deadline is None:
                deadline = time.monotonic() + duration
            epochs.add(result["epoch"])
            records.extend(checked)
        time.sleep(0.03)
    assert records, "No native PCM captured"
    return {"epochs": sorted(epochs), "frames": records,
            "seekTransition": {"epochs": sorted(transition_epochs), "validatedFrames": transition_frames}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = args.output / "synthetic-317-691hz.wav"
    create_fixture(fixture)
    player = Player(args.library)
    report = {"kind": "real-native-decode-null-output", "audiblePlaybackValidated": False}
    try:
        player.command("loadfile", fixture.resolve())
        deadline = time.monotonic() + 10
        while True:
            try:
                player.set("livesync-enabled", "yes")
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
        report["initial"] = collect(player)
        player.command("seek", "7", "absolute+exact")
        report["forwardSeek"] = collect(player, after_epoch=max(report["initial"]["epochs"]))
        player.command("seek", "2", "absolute+exact")
        report["backwardSeek"] = collect(player, after_epoch=max(report["forwardSeek"]["epochs"]))
        assert min(report["forwardSeek"]["epochs"]) > max(report["initial"]["epochs"])
        assert min(report["backwardSeek"]["epochs"]) > max(report["forwardSeek"]["epochs"])
        player.set("speed", "1.5")
        report["speed1_5"] = collect(player)
        player.set("pause", "yes")
        time.sleep(0.2)
        # Drain frames decoded before the pause took effect.
        while player.get("livesync-pcm")["frames"]:
            pass
        time.sleep(0.2)
        assert not player.get("livesync-pcm")["frames"], "Capture continued while paused"
        # Deliberately stop polling while the decoder runs fast. Overflow must
        # invalidate the old window instead of accumulating unbounded audio.
        player.set("speed", "4")
        player.command("seek", "0", "absolute+exact")
        player.set("pause", "no")
        before = player.get("livesync-pcm")
        time.sleep(2.1)
        overflow = player.get("livesync-pcm")
        assert overflow["dropped"] > before["dropped"], "Expected bounded-queue overflow"
        assert overflow["epoch"] > before["epoch"], "Overflow did not invalidate continuity"
        assert len(overflow["frames"]) <= 64
        assert sum(len(f["pcm"]) for f in overflow["frames"]) <= 262144
        for frame in overflow["frames"]:
            check_frame(frame)
        report["overflow"] = {"epoch": overflow["epoch"], "dropped": overflow["dropped"],
                              "returnedFrames": len(overflow["frames"]), "transferBoundBytes": 262144}
        player.set("livesync-enabled", "no")
        assert not player.get("livesync-enabled")
        report["pauseAndDisable"] = "passed"
    finally:
        player.close()
    (args.output / "pcm-probe.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Native PCM sample/PTS probe passed; audible output and UI remain untested.")


if __name__ == "__main__":
    main()
