#!/usr/bin/env python3
"""Generate a redistributable local video/SRT for the native renderer harness.

Requires ffmpeg in PATH only to create the fixture. Playback uses the native
stack pinned by Plezy. No media is fetched or sampled from user libraries.
"""

import argparse
from pathlib import Path
import subprocess

from probe_pcm import create_fixture
from probe_subtitles import SRT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    video = args.output / "fixture.mkv"
    if video.exists():
        raise ValueError("Use a fresh output directory; an existing fixture will not be overwritten")
    audio = args.output / "synthetic-317-691hz.wav"
    create_fixture(audio)
    (args.output / "fixture.srt").write_bytes(SRT)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-n", "-f", "lavfi", "-i",
                    "color=c=0x26394b:s=1280x720:r=24:d=12", "-i", str(audio),
                    "-c:v", "ffv1", "-c:a", "pcm_s16le", "-shortest", str(video)], check=True)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
