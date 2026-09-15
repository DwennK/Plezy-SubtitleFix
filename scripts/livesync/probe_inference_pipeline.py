#!/usr/bin/env python3
"""Prove active mpv PCM -> native 16 kHz ring -> actual whisper.cpp CPU inference.

Restricted to the pinned public-domain JFK smoke fixture. The audio snapshot
travels to whisper-cli through stdin; no captured PCM or transcript is retained.
This is a headless integration probe, not the production app or SRT matcher.
"""

import argparse
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
import wave

from check_inference import FIXTURE_SHA256, REFERENCE, edits
from prepare_native import MANIFEST, digest
from probe_pcm import Player
from probe_pcm_consumer import NativeConsumer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--whisper-cli", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert digest(args.fixture) == FIXTURE_SHA256, "Only the pinned JFK fixture is accepted"
    manifest = json.loads(MANIFEST.read_text())
    model_hash = digest(args.model)
    assert any(model["sha256"] == model_hash for model in manifest["models"]), "Model hash mismatch"
    consumer = NativeConsumer(args.consumer)
    player = Player(args.library)
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
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            packet = player.get("livesync-pcm")
            consumer.append(packet, 1)
            if not packet["frames"] and player.get("eof-reached"):
                break
            time.sleep(0.02)
        else:
            raise TimeoutError("Pinned fixture playback did not finish")
        info, samples = consumer.snapshot()
        assert 8 * 16000 <= len(samples) <= 12 * 16000, "No usable bounded speech window"
        assert info.generation == 1 and abs(info.media_seconds_per_sample - 1 / 16000) < 1e-12
        player.set("livesync-enabled", "no")
    finally:
        player.close()
        consumer.close()

    wav = io.BytesIO()
    with wave.open(wav, "wb") as stream:
        stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        stream.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, round(value * 32768)))) for value in samples))
    with tempfile.TemporaryDirectory(prefix="livesync-inference-proof-") as temporary:
        target = Path(temporary) / "result"
        started = time.perf_counter()
        process = subprocess.run([str(args.whisper_cli.resolve()), "-ng", "-m", str(args.model.resolve()),
                                  "-f", "-", "-ojf", "-of", str(target)], input=wav.getvalue(),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        inference_seconds = time.perf_counter() - started
        assert process.returncode == 0, f"Local inference failed with code {process.returncode}"
        payload = json.loads(target.with_suffix(".json").read_text())
    transcript = " ".join(segment["text"] for segment in payload["transcription"])
    words = re.findall(r"[a-z]+", transcript.lower())
    error = edits(REFERENCE.split(), words) / len(REFERENCE.split())
    assert error <= 0.25, f"Active-playback smoke recognition failed: WER {error}"
    segments = []
    for segment in payload["transcription"]:
        start, end = segment["offsets"]["from"] / 1000, segment["offsets"]["to"] / 1000
        assert 0 <= start <= end <= len(samples) / 16000 + 0.1
        segments.append({"mediaStart": info.media_start + start, "mediaEnd": info.media_start + end})
    report = {"kind": "active-mpv-pcm-to-native-consumer-to-whisper-cpu", "fixtureSha256": FIXTURE_SHA256,
              "modelSha256": model_hash, "whisperExecutableSha256": digest(args.whisper_cli),
              "mpvLibrarySha256": digest(args.library), "consumerLibrarySha256": digest(args.consumer),
              "samples": len(samples), "mediaStart": info.media_start, "generation": info.generation,
              "wordErrorRate": error, "inferenceSeconds": inference_seconds, "segments": segments,
              "timestampAccuracyValidated": False, "srtAlignmentValidated": False,
              "productionAppValidated": False, "retainedCapturedAudio": False, "retainedTranscript": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("Actual inference from active-playback PCM passed; no SRT alignment accuracy claim.")


if __name__ == "__main__":
    main()
