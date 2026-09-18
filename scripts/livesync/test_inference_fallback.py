#!/usr/bin/env python3
"""Inject recoverable backend faults while the real worker decodes public PCM.

Only the pinned JFK fixture is accepted. PCM travels over stdin and results are
numeric; neither decoded audio nor transcripts are written to disk.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import wave

from check_inference import FIXTURE_SHA256
from prepare_native import MANIFEST, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if digest(args.fixture) != FIXTURE_SHA256:
        raise ValueError('Only the pinned public JFK fixture is permitted')
    model_hash = digest(args.model)
    if model_hash not in {model['sha256'] for model in json.loads(MANIFEST.read_text())['models']}:
        raise ValueError('Expected a checksum-verified pinned English model')
    with wave.open(str(args.fixture), 'rb') as source:
        assert (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getnframes()) == (1, 2, 16000, 176000)
        data = source.readframes(source.getnframes())
    pcm = b''.join(struct.pack('<f', value[0] / 32768.0) for value in struct.iter_unpack('<h', data))
    cases = []
    report = {'kind': 'native-worker-recoverable-backend-fault-contracts',
              'executableSha256': digest(args.executable), 'modelSha256': model_hash,
              'fixtureSha256': FIXTURE_SHA256, 'cases': cases,
              'realGpuFailureReproduced': False, 'cpuDecoderIsReal': True,
              'productionAppValidated': False, 'passed': False}
    try:
        for scenario in ('load-null', 'load-throws', 'decode-fails', 'decode-throws',
                         'cpu-load-fails', 'cpu-decode-fails', 'cancel', 'fallback-cancel', 'invalid-timestamps'):
            result = subprocess.run([str(args.executable.resolve()), str(args.model.resolve()), scenario],
                                    input=pcm, capture_output=True, timeout=180)
            if result.returncode != 0:
                cases.append({'scenario': scenario, 'passed': False, 'exitCode': result.returncode})
                # Do not persist arbitrary native stderr, PCM or dialogue.
                raise RuntimeError(f'Native fallback contract failed: {scenario}, exit {result.returncode}')
            row = json.loads(result.stdout)
            assert row['scenario'] == scenario and row['passed'] is True
            cases.append(row)
        report['passed'] = True
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'cases': len(cases)}))


if __name__ == '__main__':
    main()
