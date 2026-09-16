#!/usr/bin/env python3
"""Prepare only the pinned Sintel calibration partition for the native player.

The six-channel variant places real dialogue in the center channel and silence
in the others. It tests the analysis path, not a genuine surround film mix.
"""
import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

from prepare_corpus import fetch
from prepare_native import ROOT, digest


def shift_srt_timecodes(text, delta_ms):
    """Shift the pinned authored SRT, retaining all cue text and suffixes."""
    pattern = re.compile(r"(?m)^(\d+):([0-5]\d):([0-5]\d),(\d{3}) --> (\d+):([0-5]\d):([0-5]\d),(\d{3})")

    def shift(match):
        values = [int(value) for value in match.groups()]
        stamps = []
        for index in (0, 4):
            hours, minutes, seconds, millis = values[index:index + 4]
            total = ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis + delta_ms
            if total < 0:
                raise ValueError("Subtitle shift would create a negative timestamp")
            hours, remainder = divmod(total, 3600000)
            minutes, remainder = divmod(remainder, 60000)
            seconds, millis = divmod(remainder, 1000)
            stamps.append(f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}")
        return " --> ".join(stamps)

    shifted, count = pattern.subn(shift, text)
    if count == 0 or count != text.count(" --> "):
        raise ValueError("Unexpected pinned subtitle timing format")
    return shifted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--channels", type=int, choices=[2, 6], default=2)
    parser.add_argument("--case", choices=["calibration", "intro-90"], default="calibration")
    args = parser.parse_args()
    intro = 90 if args.case == "intro-90" else 0
    duration = 75 + intro
    manifest = json.loads((ROOT / "test/fixtures/livesync/corpus-sources.json").read_text())
    source = next(entry for entry in manifest["sources"] if entry["id"] == "sintel-stereo-en")
    args.source.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    for entry in source["files"]:
        fetch(entry, args.source)
    command = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=0x10151e:s=1280x720:r=24:d={duration}",
               "-ss", "100", "-t", "75", "-i", str(args.source / "sintel-master-st.flac"),
               "-map", "0:v", "-map", "1:a"]
    filters = []
    if args.channels == 6:
        filters.append("pan=5.1|FL=0*c0|FR=0*c0|FC=0.5*c0+0.5*c1|LFE=0*c0|BL=0*c0|BR=0*c0")
    if intro:
        filters.append(f"adelay={intro * 1000}:all=1")
    if filters:
        command += ["-af", ",".join(filters)]
    command += ["-c:v", "ffv1", "-c:a", "pcm_s16le", "-metadata:s:a:0", "language=eng",
                "-t", str(duration), str(args.output / "fixture.mkv")]
    subprocess.run(command, check=True)
    if intro:
        shifted = shift_srt_timecodes((args.source / "sintel_en.srt").read_text(encoding="utf-8"), -100000)
        (args.output / "fixture.srt").write_text(shifted, encoding="utf-8", newline="")
    else:
        shutil.copyfile(args.source / "sintel_en.srt", args.output / "fixture.srt")
    shutil.copyfile(args.model, args.output / "model.bin")  # Player verifies pinned size and SHA before use.
    record = {"source": source["id"], "attribution": source["attribution"], "license": source["license"],
              "partition": [100, 175], "role": "calibration", "case": args.case,
              "introSilenceSeconds": intro, "subtitleShiftSeconds": -100 if intro else 0,
              "expectedOffsetSeconds": 90 if intro else -100,
              "channels": args.channels, "syntheticChannelRouting": args.channels == 6,
              "files": {name: digest(args.output / name) for name in ["fixture.mkv", "fixture.srt"]}}
    (args.output / "fixture-provenance.json").write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
