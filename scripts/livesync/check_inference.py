#!/usr/bin/env python3
"""Check real inference against the pinned public-domain JFK smoke fixture.

This reports text edit error on one calibration smoke sample, NOT SRT alignment
accuracy, confidence calibration, or independent validation-corpus results.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re

FIXTURE_SHA256 = "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"
REFERENCE = "and so my fellow americans ask not what your country can do for you ask what you can do for your country"


def edits(reference, actual):
    row = list(range(len(actual) + 1))
    for i, word in enumerate(reference, 1):
        next_row = [i]
        for j, candidate in enumerate(actual, 1):
            next_row.append(min(row[j] + 1, next_row[j - 1] + 1, row[j - 1] + (word != candidate)))
        row = next_row
    return row[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    assert hashlib.sha256(args.fixture.read_bytes()).hexdigest() == FIXTURE_SHA256, "Fixture hash mismatch"
    results = []
    files = list(args.evidence.glob("*cpu.json"))
    assert len(files) == 2, "Expected an inference result for each pinned model"
    for path in sorted(files):
        payload = json.loads(path.read_text())
        transcript = " ".join(segment["text"] for segment in payload["transcription"])
        words = re.findall(r"[a-z]+", transcript.lower())
        error = edits(REFERENCE.split(), words) / len(REFERENCE.split())
        assert error <= 0.25, f"Smoke text recognition failed for {path.name}: WER {error}"
        for segment in payload["transcription"]:
            assert 0 <= segment["offsets"]["from"] <= segment["offsets"]["to"] <= 11000
        results.append({"resultFile": path.name, "wordErrorRate": error,
                        "fixtureSeconds": 11, "timestampAccuracyValidated": False})
    (args.evidence / "inference-check.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results))


if __name__ == "__main__":
    main()
