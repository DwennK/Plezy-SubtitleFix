#!/usr/bin/env python3
"""Measure CPU/Metal CLI feasibility on the pinned public-domain fixture.

Each trial uses a fresh process/context but potentially warm OS file caches.
This is not a production playback-impact or word-timestamp accuracy benchmark.
"""

import argparse
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
import time

from check_inference import FIXTURE_SHA256, REFERENCE, edits
from prepare_native import MANIFEST, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert platform.system() == "Darwin" and platform.machine() == "arm64"
    assert digest(args.fixture) == FIXTURE_SHA256
    manifest = json.loads(MANIFEST.read_text())
    trials = []
    for model in manifest["models"]:
        model_path = args.models / model["file"]
        assert digest(model_path) == model["sha256"]
        for trial in range(5):
            for backend in ("cpu", "metal"):
                with tempfile.TemporaryDirectory(prefix="livesync-backend-") as scratch:
                    target = Path(scratch) / "result"
                    resource = Path(scratch) / "resources.txt"
                    command = ["/usr/bin/time", "-l", "-o", str(resource), str(args.cli.resolve()),
                               "-t", "4", "-m", str(model_path.resolve()), "-f", str(args.fixture.resolve()),
                               "-ojf", "-of", str(target)]
                    if backend == "cpu":
                        command.append("-ng")
                    start = time.perf_counter()
                    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             text=True, timeout=90)
                    wall = time.perf_counter() - start
                    assert process.returncode == 0, "Backend inference failed"
                    if backend == "metal":
                        assert re.search(r"using MTL\d+ backend", process.stderr), "Metal backend not active"
                    else:
                        assert "use gpu    = 0" in process.stderr, "CPU-only mode not active"
                    data = json.loads(target.with_suffix(".json").read_text())
                    words = re.findall(r"[a-z]+", " ".join(s["text"] for s in data["transcription"]).lower())
                    error = edits(REFERENCE.split(), words) / len(REFERENCE.split())
                    assert error <= 0.25, "Known-fixture recognition degraded"
                    stats = resource.read_text()
                    cpu = re.search(r"([\d.]+) user\s+([\d.]+) sys", stats)
                    memory = re.search(r"(\d+)\s+maximum resident set size", stats)
                    native_time = re.search(r"total time =\s+([\d.]+) ms", process.stderr)
                    assert cpu and memory and native_time, "Missing resource measurements"
                    trials.append({"model": model["file"], "backend": backend, "trial": trial,
                                   "wallSeconds": wall, "whisperTotalSeconds": float(native_time[1]) / 1000,
                                   "cpuSeconds": float(cpu[1]) + float(cpu[2]),
                                   "peakResidentBytes": int(memory[1]), "wordErrorRate": error})
    summaries = []
    for model in manifest["models"]:
        for backend in ("cpu", "metal"):
            selected = [r for r in trials if r["model"] == model["file"] and r["backend"] == backend]
            summaries.append({"model": model["file"], "backend": backend,
                              "medianWallSeconds": statistics.median(r["wallSeconds"] for r in selected),
                              "maxWallSeconds": max(r["wallSeconds"] for r in selected),
                              "medianCpuSeconds": statistics.median(r["cpuSeconds"] for r in selected),
                              "maxResidentBytes": max(r["peakResidentBytes"] for r in selected)})
    report = {"kind": "standalone-macos-cpu-metal-feasibility-comparison",
              "machine": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
              "physicalMemoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
              "os": platform.platform(), "cliSha256": digest(args.cli), "fixtureSha256": FIXTURE_SHA256,
              "whisperRevision": manifest["whisper"]["revision"],
              "models": [{"file": m["file"], "sha256": m["sha256"]} for m in manifest["models"]],
              "scope": "fresh process per trial; OS caches potentially warm; four CPU threads; known short fixture",
              "productionPlaybackImpactValidated": False, "gpuUtilizationMeasured": False,
              "temporalAccuracyValidated": False, "summaries": summaries, "trials": trials}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()
