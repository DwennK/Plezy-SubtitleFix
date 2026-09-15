#!/usr/bin/env python3
"""Convert only the pinned public-domain smoke fixture for the native worker test."""

import argparse
from pathlib import Path
import struct
import wave

from check_inference import FIXTURE_SHA256
from prepare_native import digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if digest(args.fixture) != FIXTURE_SHA256:
        raise ValueError("Only the pinned JFK fixture may be exported by this test helper")
    with wave.open(str(args.fixture), "rb") as source:
        assert source.getnchannels() == 1 and source.getsampwidth() == 2 and source.getframerate() == 16000
        assert 8 * 16000 <= source.getnframes() <= 15 * 16000
        data = source.readframes(source.getnframes())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(b"".join(struct.pack("<f", value[0] / 32768.0) for value in struct.iter_unpack("<h", data)))


if __name__ == "__main__":
    main()
