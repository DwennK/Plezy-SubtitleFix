#!/usr/bin/env python3
"""Regress the invalid ASR tail on the pinned Mac development speech fixture.

Only numeric measurements are persisted. PCM and recognition stay in memory.
This is a controlled development regression, not active-playback evidence.
"""
import argparse
import array
import json
from pathlib import Path
import sys
import time
import wave

from prepare_native import digest
from probe_inference_worker import NativeInference

FIXTURE_SHA = "e8215f367e38a67a84828fc6b547752ca0b19e4d22670ef9cefdd9eeff628e99"
MODEL_SHA = "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["fixture", "model", "library", "output"]:
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    assert digest(args.fixture) == FIXTURE_SHA, "Expected the recorded aligned LibriSpeech development WAV"
    assert digest(args.model) == MODEL_SHA, "Expected pinned base.en-q5_1"
    worker = NativeInference(args.library, args.model)
    reports = []
    try:
        for generation, (start, expected_status) in enumerate([(17.703, 0), (29.671, 5)], 1):
            with wave.open(str(args.fixture)) as source:
                assert (source.getframerate(), source.getsampwidth(), source.getnchannels()) == (16000, 2, 1)
                source.setpos(round(start * 16000))
                samples = array.array("h", source.readframes(240000))
            if sys.byteorder != "little":
                samples.byteswap()
            assert len(samples) == 240000
            pcm = [sample / 32768 for sample in samples]
            worker.submit(pcm, generation, generation, start, 1 / 16000)
            del samples, pcm
            deadline = time.monotonic() + 30
            result = None
            while result is None and time.monotonic() < deadline:
                result = worker.take()
                time.sleep(0.01)
            assert result is not None, "Native inference deadline exceeded"
            assert result.status == expected_status, "Expected full recognition or a marked valid prefix"
            assert result.segment_count > 0
            ends = []
            for segment in result.segments[:result.segment_count]:
                assert start <= segment.media_start <= segment.media_end <= start + 15.02
                ends.append(segment.media_end)
            for token in result.tokens[:result.token_count]:
                if token.has_timestamp:
                    assert start <= token.media_start < token.media_end <= start + 15.02
            reports.append({"windowStart": start, "status": result.status,
                            "segments": result.segment_count, "lastSegmentEnd": max(ends),
                            "elapsedSeconds": result.elapsed_seconds})
    finally:
        worker.close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"passed": True, "scope": "development native ABI regression",
                                      "fixtureSha256": FIXTURE_SHA, "modelSha256": MODEL_SHA,
                                      "librarySha256": digest(args.library), "cases": reports}, indent=2) + "\n")
    print("Full result and valid prefix retain bounded original timestamps")


if __name__ == "__main__":
    main()
