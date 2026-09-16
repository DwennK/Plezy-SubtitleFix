#!/usr/bin/env python3
"""Create a bounded real-speech development fixture from a pinned LibriSpeech archive.

Keeps official utterance text and derives caption boundaries from exact source
sample counts. This is development speech, not held-out film validation or
precise word-level acoustic annotation. No source data is uploaded.
"""
import argparse
from fractions import Fraction
import json
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from prepare_native import ROOT, digest


def timestamp(samples):
    if not isinstance(samples, int) or samples < 0:
        raise ValueError("Invalid source sample boundary")
    milliseconds = (samples * 1000 + 8000) // 16000
    hours, rest = divmod(milliseconds, 3600000)
    minutes, rest = divmod(rest, 60000)
    seconds, milliseconds = divmod(rest, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{milliseconds:03d}"


def captions(utterances):
    cursor = 0
    cues = []
    boundaries = []
    for index, (identifier, count, text) in enumerate(utterances):
        if not isinstance(count, int) or count < 16 or not text.strip() or "\n" in text or "\r" in text:
            raise ValueError("Invalid utterance metadata")
        cues.append(f"{index + 1}\n{timestamp(cursor)} --> {timestamp(cursor + count)}\n{text}\n")
        boundaries.append({"id": identifier, "startSample": cursor, "endSample": cursor + count})
        cursor += count
    if not cues:
        raise ValueError("Empty speech fixture")
    return "\n".join(cues), boundaries, cursor


def sample_count(path):
    data = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
        "stream=sample_rate,channels,duration_ts,time_base", "-of", "json", str(path),
    ], text=True))
    stream = data["streams"][0]
    if stream["sample_rate"] != "16000" or stream["channels"] != 1 or stream["time_base"] != "1/16000":
        raise ValueError("Unexpected pinned audio format")
    return int(stream["duration_ts"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--case", choices=["aligned", "drift-slower", "drift-faster"], default="aligned")
    args = parser.parse_args()
    source = json.loads((ROOT / "test/fixtures/livesync/librispeech-development.json").read_text())
    if args.archive.stat().st_size != source["bytes"] or digest(args.archive) != source["sha256"]:
        raise ValueError("Speech archive differs from the reviewed source; preserving it")
    slope = {"aligned": Fraction(1), "drift-slower": Fraction(25025, 24000),
             "drift-faster": Fraction(24000, 25025)}[args.case]
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".speech-fixture-", dir=args.output) as temporary:
        work = Path(temporary)
        prefix = source["utterancePrefix"]
        identifiers = [f"{prefix}-{i:04d}" for i in range(source["utteranceCount"])]
        with tarfile.open(args.archive, "r:gz") as archive:
            def read(name, maximum):
                entry = archive.getmember(name)
                if not entry.isfile() or entry.size > maximum:
                    raise ValueError("Unexpected reviewed archive member")
                with archive.extractfile(entry) as content:
                    return content.read()

            transcript = read(f"{source['chapter']}/{prefix}.trans.txt", 65536).decode("utf-8")
            texts = dict(line.split(" ", 1) for line in transcript.splitlines())
            for identifier in identifiers:
                (work / f"{identifier}.flac").write_bytes(read(f"{source['chapter']}/{identifier}.flac", 8 * 1024 * 1024))
            (args.output / "LICENSE.TXT").write_bytes(read("LibriSpeech/LICENSE.TXT", 65536))
        utterances = [(identifier, sample_count(work / f"{identifier}.flac"), texts[identifier]) for identifier in identifiers]
        text, boundaries, samples = captions(utterances)
        if not 120 * 16000 <= samples <= 180 * 16000:
            raise ValueError("Unexpected development chapter duration")
        (args.output / "fixture.srt").write_text(text, encoding="utf-8", newline="")
        (work / "inputs.txt").write_text("".join(f"file '{identifier}.flac'\n" for identifier in identifiers))
        command = ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "1", "-i", str(work / "inputs.txt")]
        if slope != 1:
            command += ["-af", f"atempo={float(1 / slope):.15f}"]
        command += ["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(args.output / "fixture.wav")]
        subprocess.run(command, check=True)
    output_samples = sample_count(args.output / "fixture.wav")
    # atempo uses overlap/add grains, so its exact output duration can differ
    # slightly from ideal affine duration. Record rather than hide that error.
    duration = output_samples / 16000
    duration_error = duration - float(Fraction(samples, 16000) * slope)
    if abs(duration_error) > 0.2:
        raise ValueError("Tempo transform exceeded duration error bound")
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
        f"color=c=0x10151e:s=1280x720:r=24:d={duration}", "-i", str(args.output / "fixture.wav"),
        "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_s16le",
        "-metadata:s:a:0", "language=eng", "-t", str(duration), str(args.output / "fixture.mkv"),
    ], check=True)
    if args.model:
        shutil.copyfile(args.model, args.output / "model.bin")
    record = {
        "source": source, "case": args.case, "role": "development", "sampleRate": 16000,
        "sourceSamples": samples, "outputSamples": output_samples, "durationSeconds": duration,
        "expectedSlope": float(slope), "slopeNumerator": slope.numerator, "slopeDenominator": slope.denominator,
        "expectedOffsetSeconds": 0, "tempoDurationErrorSeconds": duration_error,
        "reference": source["reference"], "utterances": boundaries,
        "files": {name: digest(args.output / name) for name in ["fixture.wav", "fixture.mkv", "fixture.srt"]},
    }
    (args.output / "fixture-provenance.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Prepared {args.case}: {len(boundaries)} utterances, {duration:.3f} seconds; development only")


if __name__ == "__main__":
    main()
