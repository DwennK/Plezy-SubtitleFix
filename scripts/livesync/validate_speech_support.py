#!/usr/bin/env python3
"""Compare native VAD wrapper output against frozen public development replays.

No URLs accepted. Only bounded windows are retained temporarily. The native
contract program also checks fresh state after speech, silence and reuse.
"""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import wave

MODEL_SHA = '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate(binary, model, fixture, reference):
    if model.stat().st_size != 885098 or digest(model) != MODEL_SHA:
        raise ValueError('Unverified VAD model')
    expected = json.loads(reference.read_text())
    if digest(fixture) != expected['hashes']['fixture']:
        raise ValueError('Fixture differs from the frozen replay')
    observations = []
    for entry in expected['observations']:
        origin = entry['decodedSampleOrigin']
        count = entry['decodedSamples']
        if not math.isfinite(origin) or origin < 0 or not 8 * 16000 <= count <= 15 * 16000:
            raise ValueError('Invalid recorded window')
        start = round(origin * 16000)
        with tempfile.TemporaryDirectory(prefix='livesync-public-speech-support-') as directory:
            wav = Path(directory) / 'window.wav'
            raw = Path(directory) / 'window.f32'
            trim = (f'aformat=sample_rates=16000:channel_layouts=mono,'
                    f'atrim=start_sample={start}:end_sample={start + count},asetpts=PTS-STARTPTS')
            subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-i', str(fixture), '-vn', '-af', trim,
                            '-c:a', 'pcm_s16le', str(wav)], check=True, timeout=30)
            if digest(wav) != entry['windowWavSha256']:
                raise ValueError('PCM differs from the frozen VAD window')
            with wave.open(str(wav)) as stream:
                samples = array.array('h', stream.readframes(count))
            if sys.byteorder != 'little':
                samples.byteswap()
            raw.write_bytes(array.array('f', (value / 32768 for value in samples)).tobytes())
            started = time.monotonic()
            process = subprocess.run([str(binary), str(model), str(raw)], capture_output=True,
                                     text=True, check=True, timeout=30)
            elapsed = time.monotonic() - started
            lines = [line for line in process.stdout.splitlines() if line.startswith('{')]
            if len(lines) != 1:
                raise ValueError('Missing native contract output')
            actual = json.loads(lines[0])
            target = [[a - origin, b - origin] for a, b in entry['speechIntervals']]
            if len(actual['intervals']) != len(target) or any(
                    abs(a - b) > 1e-6 for row, wanted in zip(actual['intervals'], target)
                    for a, b in zip(row, wanted)) or actual['resetAndReusePassed'] is not True:
                raise ValueError(f"Native speech support differs at attempt {entry['attempt']}")
            observations.append({'attempt': entry['attempt'], 'samples': count,
                                 'intervals': actual['intervals'], 'resetAndReusePassed': True,
                                 'elapsedSecondsIncludingRepeatedContracts': elapsed})
    return {'schema': 1, 'scope': 'native wrapper on previously consumed public windows',
            'modelSha256': MODEL_SHA, 'binarySha256': digest(binary), 'referenceSha256': digest(reference),
            'fixtureSha256': digest(fixture), 'observations': observations,
            'pcmPersisted': False, 'transcriptPersisted': False,
            'productionIntegrationValidated': False, 'fullProductAcceptance': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('binary', 'model', 'fixture', 'reference', 'output'):
        parser.add_argument('--' + key, type=Path, required=True)
    args = parser.parse_args()
    result = evaluate(args.binary.resolve(), args.model.resolve(), args.fixture.resolve(), args.reference)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
