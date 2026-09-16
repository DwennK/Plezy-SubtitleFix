#!/usr/bin/env python3
"""Exercise the native C ABI with a pinned fixture or PCM from active playback.

Only the known public-domain JFK fixture is accepted. Audio and recognition
remain in memory. Reports contain measurements, never transcript or PCM data.
"""

import argparse
import ctypes as C
import json
import math
from pathlib import Path
import re
import struct
import time
import wave

from check_inference import FIXTURE_SHA256, REFERENCE, edits
from prepare_native import MANIFEST, digest
from probe_pcm import Player
from probe_pcm_consumer import NativeConsumer


class Token(C.Structure):
    _fields_ = [("media_start", C.c_double), ("media_end", C.c_double),
                ("recognition_score", C.c_float), ("has_timestamp", C.c_uint32), ("speech_support", C.c_uint32),
                ("text_offset", C.c_uint32), ("text_length", C.c_uint32)]


class Segment(C.Structure):
    _fields_ = [("media_start", C.c_double), ("media_end", C.c_double),
                ("text_offset", C.c_uint32), ("text_length", C.c_uint32),
                ("token_offset", C.c_uint32), ("token_count", C.c_uint32)]


class Result(C.Structure):
    _fields_ = [("generation", C.c_uint64), ("continuity", C.c_uint64),
                ("elapsed_seconds", C.c_double), ("status", C.c_uint32),
                ("segment_count", C.c_uint32), ("token_count", C.c_uint32),
                ("text_bytes", C.c_uint32), ("segments", Segment * 64),
                ("tokens", Token * 512), ("text", C.c_char * 8192)]


class NativeInference:
    def __init__(self, library, model):
        self.lib = lib = C.CDLL(str(Path(library).resolve()))
        lib.ls_inference_abi_version.restype = C.c_uint32
        lib.ls_inference_result_size.restype = C.c_size_t
        assert lib.ls_inference_abi_version() == 2
        assert lib.ls_inference_result_size() == C.sizeof(Result), "Unexpected native ABI layout"
        lib.ls_inference_create.argtypes = [C.c_char_p, C.c_int]
        lib.ls_inference_create.restype = C.c_void_p
        lib.ls_inference_destroy.argtypes = [C.c_void_p]
        lib.ls_inference_destroy.restype = None
        lib.ls_inference_reset.argtypes = [C.c_void_p, C.c_uint64, C.c_uint64]
        lib.ls_inference_reset.restype = C.c_int
        lib.ls_inference_submit.argtypes = [C.c_void_p, C.c_uint64, C.c_uint64, C.c_double,
                                           C.c_double, C.POINTER(C.c_float), C.c_size_t]
        lib.ls_inference_submit.restype = C.c_int
        lib.ls_inference_take_result.argtypes = [C.c_void_p, C.POINTER(Result), C.c_size_t]
        lib.ls_inference_take_result.restype = C.c_int
        self.handle = lib.ls_inference_create(str(Path(model).resolve()).encode(), 4)
        assert self.handle, "Native worker creation failed"
        result = Result()
        assert lib.ls_inference_take_result(self.handle, C.byref(result), C.sizeof(result) - 1) == -1
        assert lib.ls_inference_submit(self.handle, 0, 0, 0, 1 / 16000, None, 0) == -1

    def submit(self, samples, generation, continuity, origin, timebase):
        assert self.lib.ls_inference_reset(self.handle, generation, continuity) == 0
        data = (C.c_float * len(samples))(*samples)
        assert self.lib.ls_inference_submit(self.handle, generation, continuity, origin,
                                             timebase, data, len(data)) == 1

    def take(self):
        result = Result()
        code = self.lib.ls_inference_take_result(self.handle, C.byref(result), C.sizeof(result))
        assert code in (0, 1), "Native result transfer failed"
        return result if code else None

    def close(self):
        if self.handle:
            self.lib.ls_inference_destroy(self.handle)
            self.handle = None


def recognize_active(args, worker):
    consumer = NativeConsumer(args.consumer)
    player = Player(args.library)
    result, submitted = None, False
    report = {}
    try:
        consumer.reset(1)
        player.set("pause", "yes")
        player.command("loadfile", args.fixture.resolve())
        deadline = time.monotonic() + 10
        while True:
            try:
                player.set("livesync-enabled", "yes")
                break
            except RuntimeError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.05)
        player.command("seek", "0", "absolute+exact")
        player.set("pause", "no")
        deadline = time.monotonic() + args.active_timeout_seconds
        while time.monotonic() < deadline:
            packet = player.get("livesync-pcm")
            consumer.append(packet, 1)
            if not submitted:
                info, samples = consumer.snapshot()
                if len(samples) >= 9 * 16000:
                    report = {"samples": len(samples), "mediaStart": info.media_start,
                              "generation": info.generation, "continuity": info.continuity,
                              "positionAtSubmission": player.get("time-pos")}
                    worker.submit(samples, info.generation, info.continuity,
                                  info.media_start, info.media_seconds_per_sample)
                    submitted = True
            if submitted and result is None:
                result = worker.take()
                if result is not None:
                    report["positionAtResult"] = player.get("time-pos")
            if result is not None and player.get("eof-reached"):
                break
            time.sleep(0.02)
        assert result is not None, "No result from active-playback PCM"
        assert report["positionAtResult"] > report["positionAtSubmission"], "Playback failed to advance"
        player.set("livesync-enabled", "no")
        return result, report
    finally:
        player.close()
        consumer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--consumer", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-speech-support", action="store_true")
    parser.add_argument("--active-timeout-seconds", type=int, default=35,
                        help="Functional active-playback deadline, not a performance budget")
    args = parser.parse_args()
    if not 15 <= args.active_timeout_seconds <= 120:
        parser.error("Active playback timeout must be between 15 and 120 seconds")
    assert bool(args.library) == bool(args.consumer), "Both native playback libraries are required"
    assert digest(args.fixture) == FIXTURE_SHA256, "Only the pinned public fixture is accepted"
    model_hash = digest(args.model)
    assert any(model["sha256"] == model_hash for model in json.loads(MANIFEST.read_text())["models"])
    worker = NativeInference(args.worker, args.model)
    try:
        if args.library:
            result, capture = recognize_active(args, worker)
        else:
            with wave.open(str(args.fixture), "rb") as source:
                assert source.getparams()[:3] == (1, 2, 16000)
                samples = [value[0] / 32768 for value in struct.iter_unpack("<h", source.readframes(source.getnframes()))]
            worker.submit(samples, 1, 1, 100, 1 / 16000)
            capture = {"samples": len(samples), "mediaStart": 100, "generation": 1, "continuity": 1}
            result = None
            deadline = time.monotonic() + 120
            while result is None and time.monotonic() < deadline:
                result = worker.take()
                time.sleep(0.02)
        assert result is not None and result.status in (0, 5), "CPU inference failed"
        assert worker.take() is None, "Native result was not consumed"
        assert result.generation == capture["generation"] and result.continuity == capture["continuity"]
        assert 0 < result.segment_count <= 64 and 0 < result.token_count <= 512 and result.text_bytes <= 8192
        text = C.string_at(C.addressof(result) + Result.text.offset, result.text_bytes)
        transcript, segments = [], []
        for segment in result.segments[:result.segment_count]:
            assert segment.text_offset + segment.text_length <= len(text)
            assert segment.token_offset + segment.token_count <= result.token_count
            assert capture["mediaStart"] <= segment.media_start <= segment.media_end
            assert segment.media_end <= capture["mediaStart"] + capture["samples"] / 16000 + 0.03
            transcript.append(text[segment.text_offset:segment.text_offset + segment.text_length].decode())
            segments.append({"mediaStart": segment.media_start, "mediaEnd": segment.media_end})
        for token in result.tokens[:result.token_count]:
            assert token.text_offset + token.text_length <= len(text)
            assert math.isfinite(token.recognition_score) and 0 <= token.recognition_score <= 1
            assert token.has_timestamp in (0, 1) and token.speech_support in (0, 1, 2)
            if token.has_timestamp:
                assert capture["mediaStart"] <= token.media_start <= token.media_end
                assert token.media_end <= capture["mediaStart"] + capture["samples"] / 16000 + 0.03
        if args.require_speech_support:
            assert any(t.speech_support == 1 for t in result.tokens[:result.token_count]), "No embedded speech evidence"
        words = re.findall(r"[a-z]+", " ".join(transcript).lower())
        expected = REFERENCE.split()
        if args.library:
            # This 9-second prefix intentionally excludes the end of the fixture.
            assert len(words) >= 10, "Insufficient recognized dialogue"
            error = min(edits(expected[:count], words) / count for count in range(10, len(expected) + 1))
        else:
            error = edits(expected, words) / len(expected)
        assert error <= 0.25, "Known-fixture recognition exceeded the smoke WER threshold"
        report = {"kind": "active-playback-native-worker" if args.library else "fixture-native-worker-abi",
                  "fixtureSha256": FIXTURE_SHA256, "modelSha256": model_hash,
                  "workerSha256": digest(args.worker), "capture": capture,
                  "wordErrorRate": error, "referenceScope": "best reference prefix" if args.library else "full fixture",
                  "inferenceSecondsExcludingModelLoad": result.elapsed_seconds, "segments": segments,
                  "validPrefixOnly": result.status == 5,
                  "speechSupportCounts": {str(value): sum(t.speech_support == value for t in result.tokens[:result.token_count]) for value in (0, 1, 2)},
                  "timestampAccuracyValidated": False, "srtAlignmentValidated": False,
                  "productionAppValidated": False, "audiblePlaybackValidated": False,
                  "retainedCapturedAudio": False, "retainedTranscript": False}
        if args.library:
            report.update(mpvLibrarySha256=digest(args.library), consumerLibrarySha256=digest(args.consumer))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print("Native worker ABI recognition passed; no alignment or audible-playback accuracy claim.")
    finally:
        worker.close()


if __name__ == "__main__":
    main()
